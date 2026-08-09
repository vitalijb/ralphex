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

### Approval model (the hard constraint)

Headless `bob run` registers no interactive approval handler. Its only input is `approval` from `~/.bob/settings/settings.json`. Defaults are `allowed_permissions: ["read"]` and a 15-entry read-only `approvedCommands` list, so `edit` and real commands (`go test`, `git commit`, `make lint`) are not auto-approved. Untrusted workspaces force `autoApprovalEnabled=false`, so `--trust` is still required.

Command matching is longest-prefix (`findLongestMatchingCommandPattern`; allow and deny compared by word count). There is no wildcard — approvals must enumerate command prefixes.

The global bob dir is `os.homedir()/.bob` with no env override (`XDG_CONFIG_HOME` is only consumed by bob's bundled git library), so ralphex cannot scope approval per run. Following the existing precedent that ralphex never writes to a foreign tool's home unprompted (the `~/.codex/` rule), the grant belongs in the explicit, user-run installer, with a wrapper-side preflight that warns instead of hanging.

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
- [x] Add an approval preflight that reads `~/.bob/settings/settings.json` (honoring an override variable for tests) and prints one actionable stderr warning naming `install-modes.sh` when `approval.allowed_permissions` lacks `edit` or `execute`, or when `approval.autoApprovalEnabled` is false, or when `approval.forbiddenApprovalGroups` contains a needed permission; warn only, never abort
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

### Task 3: Extend install-modes.sh to grant the approval settings bob v2 requires

**Files:**
- Modify: `scripts/bob-as-claude/install-modes.sh`

- [x] Add approval merging targeting `~/.bob/settings/settings.json`, overridable through an env var for tests, alongside the existing `custom_modes.yaml` merge
- [x] Make the approval step opt-in via an explicit flag so the default installer run keeps its current modes-only behavior
- [x] Union `approval.allowed_permissions` with `read`, `edit`, `execute`, `subagent`, and `todo` without removing existing entries, and set `approval.autoApprovalEnabled` to true only when the key is absent
- [x] Union `approvedCommands` for the `execute_command` entry of `approval.allowedExecutors` with a minimal documented prefix list (`git`, `go`, `make`, `npm`, `npx`, `gofmt`, `golangci-lint`, `python3`), creating the executor entry when missing and never touching `deniedCommands`
- [x] Detect and warn when `approval.forbiddenApprovalGroups` contains any permission being granted, since that silently overrides the grant
- [x] Reuse the existing safety pattern: back up the original file, validate JSON before and after, write atomically, preserve all unrelated keys and sections, and stay idempotent across repeated runs
- [x] Print a summary of exactly what was changed, including an explicit warning that broadening `approvedCommands` affects all bob usage on the machine, not just ralphex
- [x] Verify with `bash -n scripts/bob-as-claude/install-modes.sh` and by running the installer twice against a temporary settings file, confirming the second run is a no-op

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

- [ ] Add a test that a `<<<RALPHEX:...>>>` signal split across several streaming `message` deltas is re-assembled and emitted intact in a single `content_block_delta`
- [ ] Update plan-mode tests: boundaries are recognized from assistant deltas only, the `attempt_completion` protocol-adapter assertions are removed, malformed and missing boundaries still fail closed, and QUESTION payload validation is unchanged
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm the signal-reassembly and plan-mode tests pass

### Task 7: Add tests for the model note, approval preflight, and guard-shim removal

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [ ] Add a test asserting no guard-shim directory is prepended to `PATH` for `ralphex-review`
- [ ] Add a test for the model note: both `--model` and `BOB_MODEL` are ignored, with a one-time stderr note and no model argument forwarded to bob
- [ ] Add tests for the approval preflight warning: it fires on a minimal settings file and stays silent on a compliant one, using a temporary HOME so no real `~/.bob/` is read or written
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and confirm these tests pass

### Task 8: Extend YAML group validation and add installer approval-merge tests

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [ ] Extend the vendored YAML validation section to assert every group name in `scripts/bob-as-claude/modes/*.yaml` is one of `read`, `edit`, `execute`, `mcp`, `skill`, `todo`, `subagent`, `mode`, and that `ralphex-review.yaml` includes `subagent`
- [ ] Add installer tests for the approval merge against a temporary settings file: fresh creation, union with pre-existing values, unrelated keys preserved, and idempotence
- [ ] Verify the full suite passes with `bash scripts/bob-as-claude/bob-as-claude_test.sh` — this is the green gate for Tasks 4-8
- [ ] Confirm no test writes outside its temporary directories, and that no test touches a real `~/.bob/`, `~/.claude/`, or `~/.config/ralphex/`

### Task 9: Update all bob documentation for v2

**Files:**
- Modify: `docs/custom-providers.md`
- Modify: `scripts/bob-as-claude/README.md`
- Modify: `CLAUDE.md`, `llms.txt`, `README.md`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [ ] Rewrite the bob wrapper section of `docs/custom-providers.md`: the `bob run -f stream-json --mode= --trust` invocation, the v2 event table (`message` with `isReasoning`, `tool_use`, `tool_result` with `error.message`, `result` with `stats`, `error`), the valid tool-group list, and the removal of `attempt_completion`, `--yolo`, and model selection
- [ ] Document the approval prerequisite in `docs/custom-providers.md`: why headless bob cannot prompt, what `~/.bob/settings/settings.json` must contain, how to grant it with the installer flag, and that broadening `approvedCommands` affects all bob usage
- [ ] Document that review runs use native `spawn_subagent` in parallel, that subagent activity produces no stream events, and that a generous or disabled `idle_timeout` is therefore recommended for bob review phases
- [ ] Add a short caveat that bob v2 auto-loads skills from `~/.claude/skills`, so a conflicting skill can compete with the ralphex prompt
- [ ] Update `scripts/bob-as-claude/README.md` with the v2 invocation, the two-step setup (install modes, then grant approvals), the `BOB_*` variables, and the removal of model selection
- [ ] Update the bob wrapper description in `CLAUDE.md`, `llms.txt`, and `README.md` so no mention of `--chat-mode`, `--yolo`, `--output-format=stream-json`, `--hide-intermediary-output`, `attempt_completion`, or `-m`/`BOB_MODEL` model forwarding remains
- [ ] State the minimum supported version as bob 2.0.0 in `llms.txt` requirements and in `docs/custom-providers.md`, noting that bob 1.0.x is not supported by this wrapper
- [ ] Update `scripts/bob-as-claude/bob-as-claude_docs_test.sh` assertions to match the new documentation, replacing v1 term assertions with v2 ones and adding `assert_not_contains` checks for the removed v1 flags
- [ ] Verify with `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh`

### Task 10: Verify acceptance criteria

- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh` — all tests pass
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` — all tests pass
- [ ] Run `make test` and `make lint` — still green, since no Go code changed
- [ ] Grep the wrapper, modes, tests, and docs for `attempt_completion`, `--yolo`, `--chat-mode`, `--hide-intermediary-output`, `--output-format`, and `<thinking>` — no remaining occurrences
- [ ] Confirm no version-detection branch and no v1 compatibility layer exists in the wrapper

## Success Criteria

- `bob-as-claude.sh` invokes only `bob run -f stream-json --mode=<slug> --trust` plus `BOB_EXTRA_ARGS`, and passes no removed v1 flag
- Every v2 event type is translated: assistant `message` text (with `isReasoning` filtered), `tool_use`, `tool_result` errors via `error.message`, the always-success `result`, and `{type:"error"}` as a real failure with a non-zero exit
- Signals spanning multiple streaming deltas arrive intact in one `content_block_delta` for all three phases
- Plan mode detects QUESTION, PLAN_DRAFT, PLAN_READY, and TASK_FAILED boundaries from assistant messages alone, validates QUESTION JSON, terminates bob on the first valid boundary, and fails closed otherwise
- No `attempt_completion` handling, no `<thinking>` heuristic, no guard shims, and no v1 flags remain anywhere in the wrapper, modes, tests, or docs
- All three mode files declare only valid v2 group names, and `ralphex-review.yaml` grants `subagent` and instructs native parallel `spawn_subagent` use
- `install-modes.sh` can grant the required approval settings opt-in, safely, idempotently, and non-destructively, and reports exactly what it changed
- `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` both pass, with no test touching a real user config directory
- No version-detection branch and no v1 compatibility layer exists in the wrapper
- `make test` and `make lint` still pass, since no Go code changes
