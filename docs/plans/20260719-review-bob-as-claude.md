# Review and finalize bob-as-claude.sh wrapper

## Overview

Review the existing `bob-as-claude.sh` wrapper against ralphex project guidelines, compare it with the reference `pi-as-claude.sh` implementation, verify it correctly leverages IBM Bob Shell CLI's capabilities, and ensure comprehensive test coverage and documentation.

## Context

- Files involved:
  - `scripts/bob-as-claude/bob-as-claude.sh` - the wrapper script
  - `scripts/bob-as-claude/bob-as-claude_test.sh` - unit tests
  - `scripts/bob-as-claude/bob-as-claude_docs_test.sh` - documentation integration tests
  - `scripts/bob-as-claude/README.md` - wrapper documentation
  - `scripts/pi-as-claude/pi-as-claude.sh` - reference implementation
  - `scripts/pi-as-claude/pi-as-claude_test.sh` - reference tests
  - `docs/custom-providers.md` - custom providers documentation
  - `CLAUDE.md` - project guidelines
  - `README.md` - top-level README
  - `llms.txt` - LLM documentation
- Related patterns: wrapper scripts must accept prompt via stdin, ignore unknown flags gracefully (`*) shift ;;`), produce Claude-compatible stream-json output, handle review adapter injection, re-emit stderr with signal neutralization, forward SIGTERM, and preserve exit codes.
- Dependencies: `bob` CLI (v1.0.6+), `jq`, `awk` (for fence-state tracking in review adapter)

## Review Findings

### What's already correct

1. **Prompt delivery via stdin** - matches ralphex guideline (avoids 128KB per-arg cap). Also accepts `-p` for backward compat.
2. **Unknown flags ignored** - uses `*) shift ;;` catch-all, matching ralphex guideline.
3. **--model forwarding** - correctly forwards to bob's `-m` (bob 1.0.6+ supports it). `--model` flag wins over `BOB_MODEL` env var.
4. **--effort stripping** - bob has no `--effort` flag and rejects it with exit 1. Wrapper strips it and emits a stderr note for non-empty values. Empty `--effort` correctly produces no note.
5. **BOB_CHAT_MODE validation** - validates against `ask|code|plan|advanced` with clear error message.
6. **BOB_VERBOSE validation** - validates 0/1 with warning and fallback to 0.
7. **BOB_EXTRA_ARGS** - word-split with empty-arg filtering. Uses quoted array expansion to prevent glob/command-substitution expansion. Documented limitation about quote preservation.
8. **Review adapter** - sophisticated fence-state tracking via `awk` that correctly:
   - Detects `Use the Task tool to launch` (per-agent expansion)
   - Detects `Launch.*Review Agents IN PARALLEL` (review headers)
   - Does NOT trigger on `<<<RALPHEX:REVIEW_DONE>>>` (completion signal, not start marker)
   - Rejects markers inside ``` and ~~~ fenced code blocks
   - Comprehensive adapter text covering sequential review, finding verification, fix-and-commit workflow
9. **Event translation** - correct jq pipeline handling:
   - `attempt_completion.parameters.result` split into line-level `content_block_delta` events
   - `result` event translated to Claude `result`
   - `tool_result(status=error)` always emitted as `[tool_error]`
   - Suppressed events emit empty keepalive deltas (prevents idle_timeout false positives)
   - Non-JSON lines tolerated (fromjson? + objects guard)
   - Trailing newline edge cases handled correctly
   - `__eof__` sentinel flushes any buffered text
10. **Stderr handling** - captured, re-emitted as `content_block_delta` for error/limit pattern detection. `<<<RALPHEX:` token neutralized to `<<< RALPHEX:`. Rate-limit phrases preserved verbatim.
11. **SIGTERM forwarding** - jq runs in background with interruptible `wait`, TERM trap forwards to bob child, exit 143.
12. **Fallback result** - always emitted, covering bob exiting without a `result` event.
13. **Exit code preservation** - bob's exit code propagated correctly.
14. **Temp file cleanup** - single `mktemp -d` with EXIT trap for `rm -rf`.
15. **Test coverage** - comprehensive: 40+ test cases covering invocation flags, model/env resolution, effort handling, extra args, chat mode validation, verbose mode, event translation, result events, tool error/success, keepalive deltas, invalid JSON tolerance, review adapter triggers (all 3 markers), fence-state false positive avoidance, signal passthrough, multi-line splitting, stderr emission/neutralization, exit codes, failure paths, large prompts, SIGTERM forwarding, missing dependencies, edge cases.

### What could be improved

1. **BOB_EXTRA_ARGS empty-arg guard** - The wrapper uses a for loop with `[[ -n "$arg" ]]` checks. This is correct but slightly different from pi's approach (`[[ ${#pi_extra_args[@]} -gt 0 ]]`). Both work; bob's approach is actually more robust (filters empty elements). No change needed.
2. **Review adapter trigger uses awk** - This adds an `awk` dependency that pi's wrapper doesn't have. The README documents this. This is a deliberate design choice for more precise fence-state tracking. No change needed.
3. **Documentation references** - All documentation files (`docs/custom-providers.md`, `CLAUDE.md`, `README.md`, `llms.txt`) already reference bob-as-claude. The docs test verifies these references. No gaps found.
4. **Plan creation untested** - Both pi and bob wrappers document plan creation as untested. This is consistent.

### No issues found

The wrapper is well-implemented, follows all ralphex guidelines, has comprehensive test coverage, and correctly translates bob's event stream. No bugs, no missing features, no guideline violations.

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Verify existing tests pass

**Files:**
- Run: `scripts/bob-as-claude/bob-as-claude_test.sh`
- Run: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [x] run `bash scripts/bob-as-claude/bob-as-claude_test.sh` - all tests must pass
- [x] run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` - all tests must pass
- [x] run `bash scripts/pi-as-claude/pi-as-claude_test.sh` - verify reference tests still pass
- [x] run `bash scripts/pi-as-claude/pi-as-claude_docs_test.sh` - verify reference docs tests still pass

### Task 2: Add missing test coverage (if any gaps found)

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [x] review test coverage for any edge cases not covered
- [x] add tests for any identified gaps
- [x] run full test suite - must pass

### Task 3: Verify documentation consistency

**Files:**
- Modify: `scripts/bob-as-claude/README.md` (if needed)
- Modify: `docs/custom-providers.md` (if needed)
- Modify: `CLAUDE.md` (if needed)
- Modify: `README.md` (if needed)
- Modify: `llms.txt` (if needed)

- [x] verify all documentation references to bob-as-claude are accurate
- [x] verify the docs test assertions match actual documentation content
- [x] run docs test suite - must pass

### Task 4: Verify acceptance criteria

- [x] run full test suite for bob wrapper
- [x] run full test suite for pi wrapper (reference)
- [x] verify all tests pass
- [x] verify documentation tests pass
