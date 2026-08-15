# Code Review: bob-as-claude-v2-run2

**Branch:** `bob-as-claude-v2-run2` → `main`  
**Files changed:** 13 | **Lines:** +1970 / -665  
**Date:** 2025-08-11  
**Reviewer:** Bob (via subagent review)

---

## Summary

The branch hardens the bob-as-claude v2 wrapper with improved approval installation, shell pinning, plan-mode streaming, and test coverage. The overall quality is high — signal handling, cleanup, idempotency, and docs cross-checking are all well-designed. Eight actionable issues were found, five of which are correctness/security bugs that should be fixed before merge.

---

## 🔴 Critical

### 1. Plan mode stream buffer grows unbounded
**File:** `scripts/bob-as-claude/bob-as-claude.sh` line 628  
`plan_stream_buffer+="$event_content"` accumulates without any size limit. On a malformed or extremely verbose stream, memory consumption is unbounded. Task mode guards this correctly (lines 497–510); plan mode has no equivalent.  
**Fix:** Add a size cap (e.g. `(( ${#plan_stream_buffer} > 10_000_000 )) && ...`) or flush/chunk the buffer.

### 2. Incomplete signal token at plan stream EOF goes undetected
**File:** `scripts/bob-as-claude/bob-as-claude.sh`  
If the stream terminates mid-token in plan mode (e.g. `<<<RALPHEX:PLAN_REA` at EOF), the incomplete token is emitted as-is. Task mode catches this correctly with prefix-matching; plan mode has no matching guard.  
**Fix:** Mirror the in-flight signal detection from task mode into the plan mode EOF path.

### 3. AWK fence detection accepts unclosed backtick fences
**File:** `scripts/bob-as-claude/bob-as-claude.sh` line 113  
`candidate_rest !~ /\`/` checks for the presence of a backtick but does not require a matching closing fence. A prompt with an unclosed triple-backtick block will incorrectly trigger `ralphex-plan` mode selection.  
**Fix:** Require fence pairs, not just an opening fence character.

### 4. YAML validator accepts unquoted-open double-quoted strings
**File:** `scripts/bob-as-claude/install-modes.sh` line 75  
`valid_double_quoted` checks that the last character is `"` but never checks that the first character is also `"`. A string like `"foo` (no closing quote) passes validation.  
**Fix:** Add `if (substr(value, 1, 1) != "\"") return 0` immediately after the existing last-char check.

### 5. Contradictory `codex_model` documentation
**Files:** `pkg/config/defaults/config` line 74 vs `llms.txt` line 187  
- `defaults/config`: *"commenting the line out keeps the gpt-5.6-sol default"*  
- `llms.txt`: *"set to an empty value to inherit from `~/.codex/config.toml`"*  

These are contradictory. Users who comment out the line expecting `~/.codex/config.toml` inheritance will get the embedded default instead.  
**Fix:** Align both files. The correct behavior (based on `values_test.go`) is that an empty value (`codex_model =`) enables inheritance; commenting it out uses the embedded default. Update the `defaults/config` comment to match.

---

## ⚠️ Warnings

### 6. Target directory created world-readable
**File:** `scripts/bob-as-claude/install-modes.sh` line 373  
`mkdir -p "$target_dir"` uses the default umask (0755). Custom mode files may contain sensitive agent instructions.  
**Fix:** `mkdir -p -m 700 "$target_dir"`

### 7. Signal neutralization not applied uniformly
**File:** `scripts/bob-as-claude/bob-as-claude.sh` lines 477, 599, 659, 665, 668  
The `<<<RALPHEX:` → `<<< RALPHEX:` neutralization is applied in diagnostic/verbose paths but not uniformly before `BOB_VERBOSE=1` is confirmed. An error message emitted before verbose mode is active could leak a signal token.  
**Fix:** Apply neutralization unconditionally on all output paths.

### 8. `jq` parse failures silently swallowed
**File:** `scripts/bob-as-claude/bob-as-claude.sh` lines 397–407  
`jq -j ... 2>/dev/null` drops parse errors. A malformed JSON event from bob creates an empty `event_type` with no indication of why.  
**Fix:** Log parse failures to the verbose/debug stream rather than discarding them.

### 9. Truncated sentence in CLAUDE.md
**File:** `CLAUDE.md` line ~125  
*"...so `--model`/`--effort`/`BOB_MODEL` are accepted, not..."* — sentence ends mid-thought.  
**Fix:** Complete the sentence.

### 10. `idle_timeout` caveat buried in a subsection
**File:** `scripts/bob-as-claude/README.md`  
The fact that review subagents produce no stream events (making `idle_timeout` critical) is in a nested subsection. Misconfiguring this silently kills review runs.  
**Fix:** Move this caveat to the top-level **Limitations** section.

### 11. No test coverage for malformed/invalid JSON streams
**File:** `scripts/bob-as-claude/bob-as-claude_test.sh`  
The wrapper extensively parses `jq` output but has zero tests for: malformed JSON, missing fields, truncated streams. These paths could crash silently or produce partial output.

### 12. Review mode detection is fragile
**File:** `scripts/bob-as-claude/bob-as-claude_test.sh` line 566  
Mode selection relies on the exact string `"Review Agents IN PARALLEL"`. A one-word change to the instructions breaks the test silently without any assertion failure.

---

## 💡 Suggestions

### 13. `extract_plan_boundary` complexity
**File:** `scripts/bob-as-claude/bob-as-claude.sh` lines 210–372  
400+ line function with 6+ nesting levels. Opening-marker and closing-marker walk loops are near-duplicates. Extract the shared marker-walk logic into a helper for testability and readability.

### 14. State variable sprawl
**File:** `scripts/bob-as-claude/bob-as-claude.sh` lines 411–452  
8 interdependent boolean/counter flags (`bob_signal_emitted`, `plan_boundary_emitted`, `bob_transient_detected`, etc.). Consider grouping them with a block comment describing the state machine, or consolidating into a named state.

### 15. `-p ""` silently falls through to stdin
**File:** `scripts/bob-as-claude/bob-as-claude.sh` lines 41–47  
An explicit `-p ""` is indistinguishable from "no `-p` flag", causing unexpected stdin reads. Use a sentinel value to distinguish the two cases.

### 16. YAML validator recompiled on every test run
**File:** `scripts/bob-as-claude/bob-as-claude_test.sh` lines 60–267  
The embedded Go validator is compiled from inline source on every invocation. Cache the binary under `.bob/tmp/` with a checksum guard to speed up CI runs.

### 17. Hardcoded "exactly 3 shipped modes" assertion
**File:** `scripts/bob-as-claude/bob-as-claude_test.sh` lines 354–358  
Adding a 4th mode legitimately causes a mysterious test failure. Add a comment explaining the contract, or drive the count from the actual `modes/` directory.

### 18. Long `claude_error_patterns` line
**File:** `pkg/config/defaults/config` line 255  
A 386-character single-line value. Reformat with grouped comments or line continuations to make it readable and easier to extend.

---

## ✅ Looks Good

| Item | Location | Notes |
|------|----------|-------|
| Signal in-flight detection (task mode) | `bob-as-claude.sh` lines 497–510 | Well-designed prefix-matching handles mid-token streaming correctly |
| Cleanup and signal handling | `bob-as-claude.sh` lines 158–177 | Proper `trap EXIT`, `mktemp -d`, TERM forwarding |
| Bob exit code preservation | `bob-as-claude.sh` lines 706–715 | Correctly merges intentional vs error-driven exits |
| YAML validator scope | `install-modes.sh` lines 53–322 | Conservative rejection of unsupported features; tabs, unsafe keys, slug uniqueness all validated before merge |
| Mode install idempotency | `install-modes.sh` lines 359–371 | Detects already-installed modes and exits cleanly |
| Signal neutralization tests | `bob-as-claude_test.sh` lines 1079–1093 | Verifies error messages cannot forge ralphex completion signals |
| Docs cross-check suite | `bob-as-claude_docs_test.sh` lines 209–427 | Scans README/CLAUDE.md/llms.txt for env vars and v1 artifacts — prevents docs drift |
| `ralphex-review.yaml` | `modes/ralphex-review.yaml` | Explicit `/tmp` scoping, clear signal logic, sequential fallback |
| Config precedence documentation | `defaults/config` lines 5–6 | Single clear line documents the full override chain |

---

## Recommended Fix Order

| # | File | Change |
|---|------|--------|
| 1 | `install-modes.sh:75` | Fix `valid_double_quoted` first-char check |
| 2 | `defaults/config` + `llms.txt` | Resolve `codex_model` documentation contradiction |
| 3 | `bob-as-claude.sh:628` | Add unbounded buffer guard in plan mode |
| 4 | `bob-as-claude.sh` | Mirror in-flight signal guard from task mode into plan mode EOF path |
| 5 | `bob-as-claude.sh:113` | Fix AWK fence detection to require closing fence pair |
| 6 | `install-modes.sh:373` | `mkdir -p -m 700` for target directory |
| 7 | `CLAUDE.md:125` | Complete truncated sentence |
| 8 | `README.md` | Move `idle_timeout` caveat to Limitations section |
