# Update bob-as-claude for Bob Shell v2

## Overview

IBM released Bob Shell 2.0.0, which changes the headless subcommand, flags, event schema, terminal-tool contract, and permission model all at once. The current `scripts/bob-as-claude/bob-as-claude.sh` wrapper targets bob 1.0.6 and is completely non-functional against 2.0.0: it invokes `bob chat --output-format=stream-json --yolo --chat-mode=<slug>`, none of which exist anymore.

This plan rewrites the wrapper, its custom modes, its installer, its tests, and its documentation for bob v2 only. All v1 code paths are dropped and no version-detection branch is added — v1 users stay on the previous wrapper revision. v2 also adds native subagents, so the review mode adopts them and the nested-CLI guard shims and "never delegate" instructions are removed.

## Context

- Files involved:
  - Modify: `scripts/bob-as-claude/bob-as-claude.sh`
  - Modify: `scripts/bob-as-claude/modes/ralphex-task.yaml`, `modes/ralphex-review.yaml`, `modes/ralphex-plan.yaml`
  - Modify: `scripts/bob-as-claude/install-modes.sh`
  - Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`, `scripts/bob-as-claude/bob-as-claude_docs_test.sh`
  - Modify: `scripts/bob-as-claude/README.md`, `docs/custom-providers.md`, `CLAUDE.md`, `llms.txt`, `README.md`
- Related patterns: existing wrapper conventions in `scripts/codex-as-claude/`, `scripts/pi-as-claude/`; the "ralphex never writes to a foreign tool's home unprompted" rule already applied to `~/.codex/`
- Dependencies: bob CLI >= 2.0.0, `jq`

### Verified v1 to v2 breaking changes

Confirmed by static inspection of the installed bundle at `/home/fg-arch/.local/lib/node_modules/bobshell/dist/bob.js` (bob 2.0.0). Re-verify with `bob --version`, `bob run --help`, and by searching that bundle.

CLI surface:

| v1 | v2 |
|----|----|
| `bob chat --output-format=stream-json` | `bob run -f stream-json` |
| `--chat-mode=<slug>` | `--mode=<slug>` |
| `--yolo` | removed; `--auto-approve` exists on `chat` only, and `bob run` rejects both |
| `--hide-intermediary-output` | removed entirely |
| `-m` / `--model` | removed from stable builds (gated behind `BOB_USE_MODEL_ENV` + a dev gateway key) |
| `--trust` | unchanged, still required |
| — | new: `--max-turns`, `--max-cost`, `--disable-subagents`, `--disable-tool-groups`, `--disable-mcp`, `-w/--workspace`, `--log-level` |

Prompt delivery is unchanged: `bob run` reads all of stdin when stdin is not a TTY and joins it with any positional prompt, and the schema requires a non-empty result. The wrapper's stdin delivery still works.

Event schema (from the v2 stream-json renderer):

- `{type:"message", role:"assistant"|"user", content, isReasoning}` — `isReasoning` replaces the v1 `<thinking>` text heuristic. Assistant text arrives only through streaming `message` events; when a turn carries tool calls, the emitter produces `tool_use` instead.
- `{type:"tool_use", tool_name, tool_id, parameters}`
- `{type:"tool_result", tool_id, status:"success"|"error", output, error:{type,message}}` — on error, `output` is undefined and the text moved to `error.message`.
- `{type:"result", status:"success", stats:{...}}` — `status` is **always** `"success"` in v2.
- `{type:"error", severity:"error", message}` — this is now the only failure channel (for example max-cost or max-turns). The current wrapper swallows it into a keepalive, so a failed run would look like a clean, silent success.

`attempt_completion` is no longer a registered tool — only legacy text-stripping regexes remain. Every wrapper branch and every mode instruction that depends on it is dead.

`onSubagentStart` / `onSubagentEnd` are debug-log only, so subagent work produces no stream events. A parallel review can go silent for a long stretch, which interacts with ralphex `idle_timeout`.

Nested bob is now blocked natively by bob itself via a `BOB_SESSION` env var check.

### Approval model (revised during implementation — there is no constraint)

**This section originally claimed that headless `bob run` reads `approval` from `~/.bob/settings/settings.json`, and Task 3 plus parts of Tasks 1, 7, 8, and 9 were designed on that premise. Reading bob 2.0.0's own source disproved it, so that work was deliberately not implemented. The record below is the corrected finding; the affected task items are struck through in place.**

`bob run` does not read the `approval` section at all. `ApprovalEngine` is reachable only through `ToolApprovalHandler.handleToolApproval`, whose single caller is the interactive TUI's pending-tool reducer, and the handler is constructed only in the interactive session controller's `initialize()`. The headless broadcaster registers just the outside-workspace blocker and the renderer. This is also why `--auto-approve` exists on `bob chat` but not on `bob run`.

Headless tool access is therefore governed only by the active mode's `groups` list (`getToolsForMode()` → `getToolsForGroups(groups)`) plus the always-passed `--trust` and bob's unconditional outside-workspace block. A stock bob install (`allowed_permissions: ["read"]`, `autoApprovalEnabled: false`) runs ralphex task and review phases fine.

Consequences for this plan:
- No wrapper-side approval preflight. It would warn on every stock install for no headless benefit.
- No settings-writing installer flag. Granting `autoApprovalEnabled: true` machine-wide would silently disable the user's interactive `bob chat` confirmations — a real regression bought for nothing.
- Installing the shipped modes is the whole setup step. To narrow what a phase may do, drop a group from the corresponding `modes/*.yaml`.

This reversal is recorded in `CLAUDE.md` as "Do not reintroduce an approval preflight or a settings-writing installer flag", and the tests actively enforce it (`bob-as-claude_test.sh`: no preflight runs, `--grant-approvals` is rejected as an unknown argument).

### Custom mode groups

Per bob's own bundled mode-schema documentation, the only valid group names are `read`, `edit`, `execute`, `mcp`, `skill`, `todo`, `subagent`, `mode`. All three shipped modes currently declare `groups: [read, edit, command, browser]` — `command` and `browser` are not valid names, and invalid names "silently grant nothing" with "no error anywhere". Shell access must be `execute`. Also: omitting `groups` grants none, a duplicate slug or duplicate group or invalid `fileRegex` drops the whole file, and plain ASCII is required.

### Out of scope

`DEFAULT_GLOBAL_SKILL_DIRS` includes `~/.claude/skills`, so bob v2 auto-loads Claude skills and can hit the same skill-conflict class already documented for codex. Mention it in the docs as a caveat; do not build a mitigation.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the wrapper and installer; the test suite rewrite is split across Tasks 4-8 because the fixtures change shape wholesale
- Complete each task fully before moving to the next
- Shell-only change set — no Go code is touched, so `make test` / `make lint` should remain green throughout
- **CRITICAL: `scripts/bob-as-claude/bob-as-claude_test.sh` is ~2000 lines. Modify it with targeted, incremental edits, one area at a time — never regenerate the whole file in a single write. A write that large cannot finish before the streaming cutoff and the iteration dies with `API Error: Response stalled mid-stream`.**
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task — with one explicit exception: the test suite is expected to be partially red between Tasks 4 and 7, because each of those tasks converts one area of `bob-as-claude_test.sh` to the v2 fixtures. Each task must leave its own area green; Task 8 is the whole-suite green gate.**

## Implementation Steps

### Task 1: Rewrite bob-as-claude.sh for the v2 CLI and event schema

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh`

- [x] Replace the bob argument construction with `run -f stream-json --mode=<slug> --trust`, keeping the prompt on stdin and keeping `BOB_EXTRA_ARGS` word-split passthrough appended last
- [x] Remove `--output-format`, `--chat-mode=`, `--yolo`, `--hide-intermediary-output`, and the `-m "$model"` argument entirely; never pass `--disable-subagents`
- [x] Keep accepting `--model`, `--model=`, `--effort`, `--effort=`, and `BOB_MODEL`, but treat model like effort is treated today: emit a single stderr note that bob v2 stable has no model selection and ignore the value
- [x] Update `parse_bob_event` to extract the v2 fields: add `.isReasoning`, add `.severity`, read tool errors from `.error.message`, and drop `.parameters.result`
- [x] Replace `strip_thinking_blocks` with an `isReasoning` filter: drop assistant `message` events whose `isReasoning` is true (show them only under `BOB_VERBOSE=1`), and delete the `<thinking>` helper
- [x] Add line-buffered forwarding of assistant `message` text for task and review phases, replacing the `attempt_completion` branch, so a `<<<RALPHEX:...>>>` token split across streaming deltas is re-assembled and emitted in one `content_block_delta`; flush any partial trailing line at stream end
- [x] Translate `tool_result` with `status == "error"` using `.error.message` instead of `.output`, keeping the `[tool_error] ` prefix and the failure-detail flag
- [x] Handle `{type:"error"}` events: emit `error: bob: <message>` with signal-token neutralization, set the failure-detail flag, and force a non-zero exit code
- [x] Simplify the `result` branch: `status` is always `"success"` in v2, so drop the result-failure detection and keep emitting the terminating `{"type":"result","result":""}` after flushing the line buffer
- [x] Delete the plan-mode `attempt_completion` protocol adapter text and the `tool_use`/`attempt_completion` boundary branch; extract plan boundaries from the assistant delta buffer only, keeping the existing QUESTION JSON validation, empty-PLAN_DRAFT rejection, earliest-marker selection, terminate-on-boundary, and fail-closed behavior
- [x] Delete the `ralphex-review` PATH guard-shim block (the `bob claude codex` `exit 64` stub loop and its `export PATH`), and update the surrounding comment to record that bob v2 blocks nested bob natively via `BOB_SESSION`
- [x] ~~Add an approval preflight that reads `~/.bob/settings/settings.json` ... and prints one actionable stderr warning naming `install-modes.sh`~~ — **not implemented, superseded.** `bob run` never reads `approval.*` (see the revised Approval model section), so the preflight would warn on every stock install for no headless benefit. Implemented instead as a comment at the corresponding point in the wrapper recording why there is nothing to preflight
- [x] Update the script header comment block to document the v2 invocation and the current `BOB_*` variables
- [x] Preserve unchanged: the fence-aware awk mode classifier and its markers, `BOB_CHAT_MODE` override, `BOB_VERBOSE` validation, `emit_keepalive`, `neutralize_signal_text`, non-JSON diagnostic passthrough, `mktemp -d` plus FIFO stream merge, SIGTERM forwarding, exit-code preservation, and the no-diagnostic fallback message
- [x] Verify with `bash -n scripts/bob-as-claude/bob-as-claude.sh` and `shellcheck scripts/bob-as-claude/bob-as-claude.sh` if available (shellcheck not installed in this environment; `bash -n` passed)

### Task 2: Rewrite the three custom modes for v2 groups and native subagents

**Files:**
- Modify: `scripts/bob-as-claude/modes/ralphex-task.yaml`
- Modify: `scripts/bob-as-claude/modes/ralphex-plan.yaml`
- Modify: `scripts/bob-as-claude/modes/ralphex-review.yaml`

- [x] In `ralphex-task.yaml` and `ralphex-plan.yaml`, replace `groups: [read, edit, command, browser]` with `read`, `edit`, `execute`
- [x] In `ralphex-review.yaml`, set groups to `read`, `edit`, `execute`, `subagent`
- [x] Remove every `attempt_completion` reference from all three `customInstructions` blocks, including the plan mode's terminal-tool contract, and replace them with instructions to emit the required output as ordinary assistant text
- [x] In `ralphex-review.yaml`, delete the sequential-execution instruction, the "Never launch bob, claude, codex" instruction, the "Perform all review assignments yourself" instruction, and the "never invoke Task, spawn_agent, or wait_agent" instruction
- [x] In `ralphex-review.yaml`, add instructions to launch each review-agent assignment as a native `spawn_subagent` call, issuing them in a single turn so they run in parallel, and to consolidate the subagent findings into the final response
- [x] Do not add an `allowedSubagents` key to any mode
- [x] Verify each file is plain ASCII with no duplicate group entries and no duplicate slugs, and that all three parse as valid YAML

### Task 3: ~~Extend install-modes.sh to grant the approval settings bob v2 requires~~ — DROPPED

**Superseded by the revised Approval model section: `bob run` never reads `approval.*`, so there is nothing to grant.** Every bullet below was designed on the disproved premise and is deliberately not implemented. Writing `autoApprovalEnabled: true` into `~/.bob/settings/settings.json` would only disable the user's interactive `bob chat` confirmations machine-wide, buying no headless benefit.

**Files:** none — `scripts/bob-as-claude/install-modes.sh` keeps its modes-only behavior and rejects any argument.

- [x] Verify the installer writes nothing to `~/.bob/settings/settings.json`, takes no arguments, and retains no `--grant-approvals` handling (asserted by `bob-as-claude_test.sh`, section "installer leaves approval settings alone")

### Task 4: Rewrite the test mock harness and task-phase fixtures for v2

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

Scope note: this task owns the shared mock helper and the task-phase tests only. Review-phase, plan-mode, and installer tests keep their v1 fixtures until Tasks 5-8 and are expected to fail in the meantime — do not fix them here.

- [x] Update `create_mock_bob` to assert the v2 invocation: `run` subcommand present, `-f stream-json`, `--mode=<slug>`, `--trust`
- [x] Add assertions that `--yolo`, `--auto-approve`, `--output-format`, `--chat-mode`, `--hide-intermediary-output`, `-m`, and `--disable-subagents` are never passed
- [x] Replace the task-phase `attempt_completion` fixtures with v2 assistant `message` fixtures and verify the task phase forwards that text
- [x] Add a test that an assistant `message` with `isReasoning: true` is suppressed by default and shown under `BOB_VERBOSE=1`
- [x] Keep the existing provider-agnostic tests passing against the new mock helper: stderr emission and signal neutralization, rate-limit phrase preserved verbatim, exit-code preservation, large prompt over 128KB, missing prompt error, unknown flags ignored, bob not found, jq not found, SIGTERM forwarding, `BOB_EXTRA_ARGS` literal passthrough, invalid `BOB_VERBOSE`, arbitrary `BOB_CHAT_MODE` override
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm the invocation, task-phase, and provider-agnostic tests pass; record which remaining failures are owned by Tasks 5-8

### Task 5: Convert review-phase and event-schema tests to the v2 fixtures

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

Scope note: reuse the v2 mock helper from Task 4; do not reshape it again.

- [x] Replace the review-phase `attempt_completion` fixtures with v2 assistant `message` fixtures and verify the review phase forwards that text
- [x] Add a test that a `{type:"error", severity:"error", message}` event produces an error line and a non-zero exit code
- [x] Update the `tool_result` error test to supply `error.message` with `output` absent, and confirm the message still reaches the translated stream
- [x] Update the `result` fixture to the v2 shape including `stats`, and confirm the wrapper still emits exactly one terminating result event
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm the review-phase and event-schema tests pass (remaining 16 failures are owned by Tasks 6-8: 9 plan-mode, 4 model note, 3 YAML group validation)

### Task 6: Rewrite signal-reassembly and plan-mode boundary tests

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [x] Add a test that a `<<<RALPHEX:...>>>` signal split across several streaming `message` deltas is re-assembled and emitted intact in a single `content_block_delta`
- [x] Update plan-mode tests: boundaries are recognized from assistant deltas only, the `attempt_completion` protocol-adapter assertions are removed, malformed and missing boundaries still fail closed, and QUESTION payload validation is unchanged
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm the signal-reassembly and plan-mode tests pass (remaining 7 failures are owned by Tasks 7-8: 4 model note, 3 YAML group validation)

### Task 7: Add tests for the model note, absent approval preflight, and guard-shim removal

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [x] Add a test asserting no guard-shim directory is prepended to `PATH` for `ralphex-review`
- [x] Add a test for the model note: both `--model` and `BOB_MODEL` are ignored, with a one-time stderr note and no model argument forwarded to bob
- [x] ~~Add tests for the approval preflight warning~~ — **replaced by the inverse assertions** (Task 3 dropped): under a temporary HOME with a minimal read-only settings file, task and review prompts run successfully, emit no approval warning, and never point at `install-modes.sh --grant-approvals`
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm these tests pass (remaining 3 failures are the YAML group validation tests owned by Task 8)

### Task 8: Extend YAML group validation and add installer approval-inaction tests

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [x] Extend the vendored YAML validation section to assert every group name in `scripts/bob-as-claude/modes/*.yaml` is one of `read`, `edit`, `execute`, `mcp`, `skill`, `todo`, `subagent`, `mode`, and that `ralphex-review.yaml` includes `subagent`
- [x] ~~Add installer tests for the approval merge against a temporary settings file~~ — **replaced by the inverse assertions** (Task 3 dropped): `--grant-approvals` is rejected as an unknown argument and installs no modes, a default run installs the modes while leaving a pre-existing `settings.json` byte-identical and writing no settings backup, and the installer source retains no approval handling
- [x] Verify the full suite passes with `bash scripts/bob-as-claude/bob-as-claude_test.sh` — this is the green gate for Tasks 4-8 (309 passed, 0 failed)
- [x] Confirm no test writes outside its temporary directories, and that no test touches a real `~/.bob/`, `~/.claude/`, or `~/.config/ralphex/` (verified by running the suite under a sentinel HOME: only the Go toolchain's own telemetry counters appear there, and real `~/.bob/`, `~/.claude/`, `~/.config/ralphex/` checksums are unchanged)

### Task 9: Update all bob documentation for v2

**Files:**
- Modify: `docs/custom-providers.md`
- Modify: `scripts/bob-as-claude/README.md`
- Modify: `CLAUDE.md`, `llms.txt`, `README.md`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [x] Rewrite the bob wrapper section of `docs/custom-providers.md`: the `bob run -f stream-json --mode= --trust` invocation, the v2 event table (`message` with `isReasoning`, `tool_use`, `tool_result` with `error.message`, `result` with `stats`, `error`), the valid tool-group list, and the removal of `attempt_completion`, `--yolo`, and model selection
- [x] Document in `docs/custom-providers.md` why there is **no** approval prerequisite (Task 3 dropped): headless `bob run` cannot prompt and does not read `approval.*` because the approval engine is only reachable from the interactive TUI's tool handler, so tool access comes from the mode's `groups` plus `--trust`, installing the modes is the whole setup step, and narrowing a phase means editing its mode file
- [x] Document that review runs use native `spawn_subagent` in parallel, that subagent activity produces no stream events, and that a generous or disabled `idle_timeout` is therefore recommended for bob review phases
- [x] Add a short caveat that bob v2 auto-loads skills from `~/.claude/skills`, so a conflicting skill can compete with the ralphex prompt
- [x] Update `scripts/bob-as-claude/README.md` with the v2 invocation, the one-step setup (install the modes — no approval grant is needed; Task 3 dropped), the `BOB_*` variables, and the removal of model selection
- [x] Update the bob wrapper description in `CLAUDE.md`, `llms.txt`, and `README.md` so no mention of `--chat-mode`, `--yolo`, `--output-format=stream-json`, `--hide-intermediary-output`, `attempt_completion`, or `-m`/`BOB_MODEL` model forwarding remains
- [x] State the minimum supported version as bob 2.0.0 in `llms.txt` requirements and in `docs/custom-providers.md`, noting that bob 1.0.x is not supported by this wrapper
- [x] Update `scripts/bob-as-claude/bob-as-claude_docs_test.sh` assertions to match the new documentation, replacing v1 term assertions with v2 ones and adding `assert_not_contains` checks for the removed v1 flags
- [x] Verify with `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh`

### Task 10: Verify acceptance criteria

- [x] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` — all tests pass (309 passed, 0 failed)
- [x] Run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — all tests pass (145 passed, 0 failed)
- [x] Run `make test` and `make lint` — `make test` green (exit 0, 88.0% coverage). `make lint` could not run: `golangci-lint` is not installed in this environment (exit 127 on the missing binary, not a code failure). Verified the underlying premise instead: `git diff --name-only master...HEAD` shows no `.go`, `go.mod`, `go.sum`, or `vendor/` changes, and `go vet ./...` plus `gofmt -l ./cmd ./pkg` are clean
- [x] Grep the wrapper, modes, tests, and docs for `attempt_completion`, `--yolo`, `--chat-mode`, `--hide-intermediary-output`, `--output-format`, and `<thinking>` — zero occurrences in `bob-as-claude.sh`, `modes/`, and `install-modes.sh`. Remaining hits are all intentional: prose documenting the v1 removals, `assert_not_contains` needle lists and forbidden-string loops in the two test suites, and non-bob contexts (Copilot's `--yolo`/`--output-format`, the Cursor CLI example, the `claude_args` default, and CLAUDE.md's claude-streaming debug note)
- [x] Confirm no version-detection branch and no v1 compatibility layer exists in the wrapper — `bob_args=(run -f stream-json "--mode=$selected_chat_mode" --trust)` is built unconditionally, nothing invokes `bob --version`, and the only `version`/`v1`/`compat` mentions are header comments stating v1 is unsupported plus notes about accepting-and-ignoring ralphex's `--model`/`--effort` flags

## Success Criteria

- `bob-as-claude.sh` invokes only `bob run -f stream-json --mode=<slug> --trust` plus `BOB_EXTRA_ARGS`, and passes no removed v1 flag
- Every v2 event type is translated: assistant `message` text (with `isReasoning` filtered), `tool_use`, `tool_result` errors via `error.message`, the always-success `result`, and `{type:"error"}` as a real failure with a non-zero exit
- Signals spanning multiple streaming deltas arrive intact in one `content_block_delta` for all three phases
- Plan mode detects QUESTION, PLAN_DRAFT, PLAN_READY, and TASK_FAILED boundaries from assistant messages alone, validates QUESTION JSON, terminates bob on the first valid boundary, and fails closed otherwise
- No `attempt_completion` handling, no `<thinking>` heuristic, no guard shims, and no v1 flags remain anywhere in the wrapper, modes, tests, or docs
- All three mode files declare only valid v2 group names, and `ralphex-review.yaml` grants `subagent` and instructs native parallel `spawn_subagent` use
- `install-modes.sh` stays modes-only: it writes nothing to `~/.bob/settings/settings.json`, takes no arguments, and installing the modes is the complete setup step (revised — see the Approval model section)
- `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` both pass, with no test touching a real user config directory
- No version-detection branch and no v1 compatibility layer exists in the wrapper
- `make test` and `make lint` still pass, since no Go code changes
