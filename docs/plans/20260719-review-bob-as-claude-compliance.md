# Fix bob-as-claude.sh compliance with bob docs and ralphex guidelines

## Overview

A careful review of `scripts/bob-as-claude/bob-as-claude.sh` against the three referenced bob documentation pages (slash-commands, custom-modes, tools) and the ralphex guidelines in `CLAUDE.md`/`CONTRIBUTING.md` found three issues, all scoped to the bob wrapper and its docs (CLAUDE.md, README.md, docs/custom-providers.md). pi-as-claude.sh is NOT touched. The fixes: (1) correct a wrong review-adapter trigger description in CLAUDE.md that contradicts the actual code and the other docs; (2) relax `BOB_CHAT_MODE` validation so bob's documented user-defined custom mode slugs work through the wrapper; (3) correct the review-adapter text to reference bob's actual tool names instead of pi/claude-style names.

## Context

- Files involved:
  - `scripts/bob-as-claude/bob-as-claude.sh` (wrapper: chat-mode validation block, review-adapter `adapter_text`)
  - `scripts/bob-as-claude/bob-as-claude_test.sh` (unit tests with mock bob)
  - `scripts/bob-as-claude/bob-as-claude_docs_test.sh` (docs/repo integration assertions)
  - `scripts/bob-as-claude/README.md` (wrapper README: chat-modes table, review-adapter section, line 48 tool wording)
  - `docs/custom-providers.md` (bob section: chat-modes table line ~452, review-adapter line 496 tool wording)
  - `CLAUDE.md` (line 121 bob-wrapper bullet: wrong trigger description)
- Related patterns: other wrappers (codex/gemini/opencode/agy/pi) use the looser `<<<RALPHEX:REVIEW_DONE>>>` substring trigger; bob is the ONLY wrapper using the stricter fence-aware START-marker trigger — this is bob being MORE correct, and per the agreed scope pi is NOT aligned to it. The existing `_test.sh` + mock-bob pattern (no real API calls) is the project convention for wrapper tests.
- Dependencies: bob CLI docs confirm custom mode slugs (`bob --chat-mode=<slug>`) and list actual tool names (`read_file`, `write_to_file`, `apply_diff`, `execute_command`, etc.). `attempt_completion` is not in the bob tools doc but is already documented in the wrapper README as empirically verified against bob 1.0.6 — no action needed for that.

Confirmed findings:

1. CLAUDE.md line 121 says the review adapter "is prepended only when `<<<RALPHEX:REVIEW_DONE>>>` appears as a standalone line outside fenced code blocks." This is wrong: the actual code (and README line ~50, and custom-providers.md line 496) triggers on START markers (`Use the Task tool to launch` and `Launch.*Review Agents IN PARALLEL`) with a fence-state guard, and explicitly does NOT trigger on REVIEW_DONE. Only CLAUDE.md is wrong.
2. The wrapper hard-rejects any `BOB_CHAT_MODE` not in `ask|code|plan|advanced`, but the bob custom-modes doc documents user-defined mode slugs (`bob --chat-mode=shell-debug` via `~/.bob/custom_modes.yaml`). Users with custom modes cannot use them through the wrapper.
3. The review-adapter text instructs bob to use "bob's read, bash, edit, and write tools." Bob's actual tools (per the tools doc) are `read_file`, `search_files`, `write_to_file`, `apply_diff`, `insert_content`, `execute_command` — "bash" and "write" are not even valid bob tool-group names (groups are read/edit/browser/command/mcp). The model interprets loosely, but the wording is inaccurate vs the bob docs. README line 48 and custom-providers.md line 496 repeat the same inaccurate wording.

## Development Approach

- Testing approach: Regular (code first, then tests). The project has no Go changes here, so `make test`/`make lint` are sanity-only; the real verification is the two bash test scripts run directly. Every code/docs change task includes new or updated assertions in `bob-as-claude_test.sh` and/or `bob-as-claude_docs_test.sh` (the existing mock-bob convention, no real API calls).
- Complete each task fully before moving to the next; run both bob test scripts after each task and require all pass before starting the next.
- CRITICAL: every task includes new/updated tests; all tests must pass before the next task.
- CRITICAL: do NOT modify `scripts/pi-as-claude/pi-as-claude.sh` or the pi section of `docs/custom-providers.md` (line ~416) — scope is strictly the bob wrapper + CLAUDE.md/README/custom-providers.md bob sections.

## Implementation Steps

### Task 1: Fix CLAUDE.md review-adapter trigger description and add regression docs assertion

**Files:**
- Modify: `CLAUDE.md`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [x] Rewrite the `bob wrapper:` bullet at CLAUDE.md line 121 so it describes the actual strict trigger: the adapter is prepended only when a review START marker (`Use the Task tool to launch`, or a line matching `Launch.*Review Agents IN PARALLEL`) appears in the prompt OUTSIDE fenced code blocks (` ``` `/`~~~`), and that the completion signal `<<<RALPHEX:REVIEW_DONE>>>` is NOT a trigger (it is an end-of-review output signal). Match the wording already correct in README and custom-providers.md line 496.
- [x] Add a docs-test assertion in `bob-as-claude_docs_test.sh` that CLAUDE.md no longer claims REVIEW_DONE is the trigger and does describe the START-marker + fence-guard trigger (e.g. assert CLAUDE.md contains `Use the Task tool to launch` near the bob wrapper bullet, and assert it does NOT contain the phrase `REVIEW_DONE>>>` appears as a standalone line`).
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — must pass before Task 2.

### Task 2: Relax BOB_CHAT_MODE validation to accept custom mode slugs

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh`
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`
- Modify: `scripts/bob-as-claude/README.md`
- Modify: `docs/custom-providers.md`

- [x] In `bob-as-claude.sh`, replace the hard-reject `case "$BOB_CHAT_MODE" in ask|code|plan|advanced) ;; *) exit 1` block with: reject empty/whitespace-only `BOB_CHAT_MODE` with a clear error (exit 1); accept any non-empty value and pass it through to bob (bob validates the slug); emit a stderr warning when the value is outside the known built-in set `{ask,code,plan,advanced}` so typos are still visible (e.g. `warning: BOB_CHAT_MODE='shell-debug' is not a built-in mode (ask|code|plan|advanced); passing through to bob — ensure it is defined in ~/.bob/custom_modes.yaml`). Keep it simple: no allowlist file parsing, no mode-discovery — just pass-through with a warning.
- [x] Update the header comment block that documents `BOB_CHAT_MODE` to mention custom mode slugs are accepted (forwarded to bob's `--chat-mode`).
- [x] Update `bob-as-claude_test.sh`: replace the existing "invalid BOB_CHAT_MODE exits non-zero" test with three cases: (a) empty `BOB_CHAT_MODE=""` exits non-zero with the missing/empty error; (b) a custom slug like `BOB_CHAT_MODE=shell-debug` is forwarded to bob as `--chat-mode shell-debug` and the wrapper exits 0 (using the mock bob); (c) a non-builtin slug emits the warning line on stderr but still proceeds. Keep the existing built-in-mode forwarding tests.
- [x] Update `README.md` Environment variables / Chat modes sections: document that custom mode slugs defined in `~/.bob/custom_modes.yaml` are accepted and forwarded, with the typo-warning behavior and an example (`BOB_CHAT_MODE=shell-debug`). Note the built-in set is still the recommended/safe choice.
- [x] Update `docs/custom-providers.md` bob Chat modes table/section to mention custom mode slug support and the warning behavior, consistent with README.
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — both must pass before Task 3.

### Task 3: Correct review-adapter tool names to bob's documented tools

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh` (adapter_text only)
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`
- Modify: `scripts/bob-as-claude/README.md` (line ~48)
- Modify: `docs/custom-providers.md` (line ~496, bob section only — do NOT touch the pi section at line ~416)

- [x] In the `adapter_text` heredoc of `bob-as-claude.sh`, replace `using bob's read, bash, edit, and write tools` with bob's actual tool names per the tools doc, e.g. `using bob's read_file, execute_command, write_to_file, and apply_diff tools`. Keep the rest of the adapter instruction (sequential per-agent review, git commands, criteria, fix/commit) unchanged.
- [x] Update README.md line ~48 to use the same corrected tool-name wording.
- [x] Update `docs/custom-providers.md` line ~496 (bob review-adapter paragraph) to use the same corrected tool-name wording. Do NOT modify the pi paragraph at line ~416.
- [x] Add a unit-test assertion in `bob-as-claude_test.sh` (in the existing review-adapter injection test block) that the prepended adapter text contains bob's actual tool name `read_file` (and `execute_command`), and does NOT contain the old inaccurate phrase `read, bash, edit, and write tools`.
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — both must pass before Task 4.

### Task 4: Verify acceptance criteria

- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` — all tests pass. (88 passed, 0 failed)
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — all tests pass. (26 passed, 0 failed)
- [x] Confirm `scripts/pi-as-claude/pi-as-claude.sh` and the pi section of `docs/custom-providers.md` (line ~416) are unchanged (grep the pi file's review-adapter line to confirm it still uses the REVIEW_DONE substring trigger — pi is intentionally left as-is per scope). (pi-as-claude.sh line 90 still uses REVIEW_DONE substring trigger; custom-providers.md line 416 pi section unchanged)
- [x] Run `make test` and `make lint` as a sanity check that no Go-side expectations broke (these wrapper changes are bash/docs only; expected no-op, but confirms nothing else regressed). (make test: only pre-existing TestAutoPlanModeDetection failure at commit 35b0cf7 — confirmed unrelated to bash/docs changes; no Go files modified. make lint: golangci-lint not installed in environment — environment issue, not caused by changes)
- [x] Verify CLAUDE.md, README.md, and docs/custom-providers.md bob sections now consistently describe the strict START-marker trigger and bob's actual tool names (no remaining `read, bash, edit, and write` wording in bob sections; no remaining claim that REVIEW_DONE is the trigger). (verified: all three docs use read_file/execute_command/write_to_file/apply_diff and START-marker trigger; no leftover inaccurate wording in bob sections)

### Task 5: Update documentation inventory

- [x] Confirm `llms.txt` and the top-level `README.md` wrapper inventory entries reference only the wrapper path (not behavior), so no update is needed beyond what Tasks 2-3 already made; if any inventory line mentions the chat-mode set or trigger, align it — otherwise leave unchanged. (llms.txt references only the wrapper path — no alignment needed. Top-level README.md line 1158 mentioned the chat-mode set without custom slug support — aligned to mention custom slugs from `~/.bob/custom_modes.yaml` and the stderr warning, consistent with the bob wrapper README and docs/custom-providers.md. No trigger wording found in either inventory file.)
- [x] No new files created; no CLAUDE.md internal-patterns changes beyond the Task 1 trigger-description fix. (git diff HEAD~4..HEAD shows only modified files — no new files. CLAUDE.md diff is exactly the one-line trigger-description fix from Task 1; no other CLAUDE.md changes.)
