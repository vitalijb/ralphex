# Align bob-as-claude with Bob Shell 2.0.1-2.0.6

## Overview

`scripts/bob-as-claude/` was written and tested against bob 2.0.0. Bob Shell has since shipped 2.0.1 through 2.0.6 (changelog in `docs/bob-shell-changes.md`). Most entries are TUI-only, but four change behavior the wrapper, its modes, or its documentation depend on:

1. **Shell resolution changed (2.0.6 bundle).** `execute_command` now resolves its shell as `BOB_BASH_PATH` → (`powershell.exe` on win32) → `$SHELL`. The wrapper pins only `SHELL`, so a user-exported `BOB_BASH_PATH` (for example pointing at `fish`) silently defeats the bash pin that commit 19ffb4c added.
2. **Headless runs now read part of `approval.*` (2.0.6, "Finer control over access outside the workspace").** The headless event broadcaster reads `approval.outsideWorkspaceAllowed` and `approval.permissionOptions[<group>].enableOutsideWorkspace`. `CLAUDE.md`, `llms.txt`, the root `README.md`, `scripts/bob-as-claude/README.md`, and `docs/custom-providers.md` all say `bob run` reads no `approval` setting and that the outside-workspace block is unconditional. Both claims are now wrong. One practical consequence the docs never mention: in `--worktree` mode the progress log lives in the main repo's `.ralphex/progress/`, which is outside the worktree's workspace root. Bob blocks the review prompt's read of `{{PROGRESS_FILE}}` unless the user opts in through those two settings.
3. **Background execution (2.0.3).** `execute_command` now takes a `background` boolean, has a 30s default timeout, and caps `timeout_seconds` at 270s. Bob "starts longer-running processes in the background automatically." Background children are spawned `detached` (their own session and process group), and from reading the bundle nothing stops them on a headless exit. That is an inference, not an observation. The shipped modes tell Bob to "run the requested tests and linter", but nothing stops it from committing or emitting `REVIEW_DONE`/`ALL_TASKS_DONE` while a backgrounded test run is still going, or from leaving that process running after `bob run` exits.
4. **Transient-failure retry is broken on 2.0.6.** 2.0.6 rewrites every backend 5xx and every connection failure into one of two fixed messages, `Error: Server Error. Bob's backend service is experiencing issues. Please try again.` and `Unable to connect to Bob's backend service. Check your network connection.` The status code and low-level cause appear only in debug mode. None of the phrases `classify_bob_transient` matches today appears in either message, so on 2.0.6 a transient backend failure is never retried and fails the run. Neither message is translated in `dist/translations/*.json`, so English matching is safe for these two. Only the max-turns/max-cost texts and the `Error:` prefix are localized.

This plan fixes the shell pin, tightens the modes for background execution, measures whether bob leaves background processes behind, repairs the transient classifier for 2.0.6, and corrects the documentation. The minimum supported version stays at bob 2.0.0. Every change also works on 2.0.0-2.0.5: those versions ignore `BOB_BASH_PATH`, and the classifier keeps its existing phrases for them.

## Context

- Files involved:
  - Modify: `scripts/bob-as-claude/bob-as-claude.sh`
  - Modify: `scripts/bob-as-claude/modes/ralphex-task.yaml`, `modes/ralphex-review.yaml`, `modes/ralphex-plan.yaml`
  - Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`, `scripts/bob-as-claude/bob-as-claude_docs_test.sh`
  - Modify: `scripts/bob-as-claude/README.md`, `docs/custom-providers.md`, `README.md` (root), `CLAUDE.md`, `llms.txt`
- Related patterns: the `SHELL` pin and `BOB_SHELL` override (`bob-as-claude.sh`), `classify_bob_transient` and the diagnostic keyword gate in front of it, the `{type:"error"}` branch, and the doc/test coupling enforced by `bob-as-claude_docs_test.sh`
- Dependencies: bob CLI (installed: 2.0.6, bundle at `~/.local/lib/node_modules/bobshell/dist/bob.js`), `jq`

### Verified against the 2.0.6 bundle (static inspection)

Re-verify with `bob --version` and by searching `dist/bob.js`. The code is minified, so search for string literals, not identifiers.

- **Shell:** `function …(){return process.env.BOB_BASH_PATH?process.env.BOB_BASH_PATH:process.platform==="win32"?"powershell.exe":process.env.SHELL}`. The `execute_command` description is now derived from that resolved shell. It emits `powershellGuidelines()` when the basename is `powershell`/`pwsh` and `bashGuidelines()` ("The shell uses bash syntax.") for every other shell, so a `fish` or `sh` resolution is still described to the model as bash. `environment_info.systemInfo.shell` now reports the resolved shell, not the login shell. The existing wrapper comment (`bob-as-claude.sh`, shell-pinning block) still says otherwise and must be corrected.
- **Outside workspace (headless broadcaster `createEventBroadcaster`):** when `isOutsideWorkspace` is set, the call is cancelled unless `approval.outsideWorkspaceAllowed` is true **and** `permissionOptions.find(groupId === <tool permission>).enableOutsideWorkspace === true`. The cancel note reads `Tools are blocked from working outside of the current workspace. Do not attempt to work around this … Enable "Allow outside workspace tool requests" in settings.` Defaults: `outsideWorkspaceAllowed:false`, `permissionOptions:[]`. Per-tool approval (`ApprovalEngine` via `handleToolApproval`) is still interactive-only. The existing "no approval preflight / no settings-writing installer" rule therefore still holds.
- **stream-json renderer is unchanged in shape:** `message` (`isReasoning`), `tool_use`, `tool_result` (`error:{type:"tool_error",message}`), `result` (`status:"success"`, `stats`), and `error` events. `error` is emitted ONLY from `onMaxCostReached` / `onMaxTurnsReached`, always with `severity:"error"`, and the message is now localized. The 2.0.5 note "Session no longer ends on recoverable errors" adds no new headless `error` event, so the wrapper's "every `error` event fails the run" rule stays correct. Shell-output streaming (2.0.3) adds no new stream-json event type.
- **Backend diagnostics:** `handleHttpError` maps every status >= 500 to a ServerError, titled `Server Error` with the description `Bob's backend service is experiencing issues. Please try again.` Connection failures (socket hang up, ECONNRESET, ETIMEDOUT, fetch failed, connection refused) all become `Unable to connect to Bob's backend service. Check your network connection.` The headless formatter prints `Error: {{title}}. {{description}}` on a non-JSON line. The cause is shown only in debug mode, so `ECONNREFUSED` can no longer be told apart from `ECONNRESET`.
- **`execute_command` parameters:** `command`, `cwd`, `timeout_seconds` (default 30, max 270), `background` (local FS only; output redirected to a log file, returns pid + log path immediately). A background command is spawned as `[shell, ["-c", command]]` with `detached:true` and `unref()`, which calls setsid on POSIX. The reported pid is therefore the `bash -c` leader of its own session and process group. Bob's result text tells the model to stop it with `kill -TERM -<pid>` (entire process group), and its process registry also signals the negative pid, but only from the TUI, never on headless exit. The background spawn passes `env:{...process.env}`, so every background process and its descendants inherit bob's environment. Bob's detached self-updater copies `process.env` too (minus `npm_config_*`).
- **`bob run` flag order (2.0.6):** prompt text may now follow valueless flags. The wrapper delivers the prompt on stdin, so nothing changes. Noted only so nobody "fixes" it.
- **`--max-cost 0` / `--max-turns 0`** now mean unlimited (2.0.6). Documentation only.

### Out of scope

- `bob acp` (2.0.2) as an alternative integration path. It is a different protocol and worth a separate plan if ever.
- Surfacing the `result.stats` cost/turn summary in the progress log.
- Office tools, MCP OAuth, hooks, Vim/Emacs keys, and other TUI-only changelog entries.
- Raising the minimum supported version.
- Moving bob into its own process group. The wrapper must stay in ralphex's process group so `killProcessGroup` (`pkg/executor/procgroup_unix.go`) can SIGKILL bob on timeout cancellation, and bob's detached background children would not be in that group anyway.
- Any cleanup of leftover background processes (an environment-marker sweep, process-group or pid tracking). Seven review rounds of a marker-sweep design each found a new defect, and it is unknown whether bob leaks in practice. Task 4 measures that first; cleanup becomes a separate plan only if a realistic run leaks.

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Shell-only change set, no Go code. `make test` / `make lint` must stay green, but the gates that matter are `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh`
- **CRITICAL: `scripts/bob-as-claude/bob-as-claude_test.sh` is ~3900 lines. Edit it with targeted, incremental edits, one area at a time. Never regenerate the whole file in one write: a write that large cannot finish before the streaming cutoff.**
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- Do not reintroduce an approval preflight or a settings-writing installer flag. The outside-workspace settings are a user opt-in that is documented, not automated.

## Implementation Steps

### Task 1: Pin the shell through BOB_BASH_PATH as well as SHELL

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh`
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [ ] Keep the resolution order `BOB_SHELL` → `bash`. A caller-exported `BOB_BASH_PATH` is deliberately ignored as an input: honoring it would recreate the exact defect this task fixes (a `fish` value), and on 2.0.0-2.0.5 copying it into `SHELL` would break setups that work today. `BOB_SHELL` remains the one override. Resolve with `command -v` and fail at startup as today
- [ ] Launch bob with both `BOB_BASH_PATH="$bob_shell"` and `SHELL="$bob_shell"`, scoped to that one invocation like the current `SHELL=` prefix. This overrides any exported `BOB_BASH_PATH` for the bob child. 2.0.6+ reads `BOB_BASH_PATH`, and `SHELL` keeps 2.0.0-2.0.5 working
- [ ] Rewrite the shell-pinning comment to match the verified 2.0.6 behavior. `BOB_BASH_PATH` is the first lookup. The tool description is derived from the resolved shell: PowerShell guidance for `powershell`/`pwsh`, bash guidance for everything else, so `fish`/`sh` are still described as bash. `environment_info` reports the resolved shell. Explain why both variables are set and why an exported `BOB_BASH_PATH` is overridden rather than honored
- [ ] Update the header env-var block to say `BOB_SHELL` also overrides any exported `BOB_BASH_PATH`
- [ ] Tests: add `BOB_BASH_PATH` to the environment reset at the top of `bob-as-claude_test.sh` (the `unset BOB_CHAT_MODE … BOB_SHELL` line). The mock bob records `BOB_BASH_PATH` and `SHELL`. Cover: default (`bash` in both); `BOB_SHELL=sh` (both point at `sh`); an exported `BOB_BASH_PATH=<fish-like stub>` with no `BOB_SHELL` (both still `bash`, so the export is overridden); and an exported `BOB_BASH_PATH` together with `BOB_SHELL=sh` (both `sh`). Keep the existing "wrapper's own subshells keep the caller's SHELL" assertion passing
- [ ] Run `bash -n scripts/bob-as-claude/bob-as-claude.sh` and `bash scripts/bob-as-claude/bob-as-claude_test.sh`; must pass before next task

### Task 2: Repair the transient classifier for bob 2.0.6 backend diagnostics

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh`
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [ ] Add the two 2.0.6 fixed messages to `classify_bob_transient`, matched case-insensitively on their distinctive parts: `bob's backend service is experiencing issues` (every 5xx) and `unable to connect to bob's backend service` (every connection failure). Copy the exact text from the bundle; do not invent variants
- [ ] Record in the function comment that 2.0.6 folds `ECONNREFUSED`/`ENOTFOUND` into the same "Unable to connect" message as `ECONNRESET`/`ETIMEDOUT`, and that the cause is visible only in debug mode. Treating "Unable to connect" as transient therefore also retries a wrong endpoint or a missing network. Accept this: ralphex's retry loop is bounded, and a run that can never connect fails after its retries either way. Write this trade-off into the comment next to the existing exclusions note
- [ ] Keep the existing phrases for 2.0.0-2.0.5. Note in the comment which ones 2.0.6 no longer prints
- [ ] Confirm that both 2.0.6 messages pass the diagnostic keyword gate in front of the classifier (the `*error*|*failed*|…` case in the non-JSON branch). `Error: Server Error.` matches `*error*`. Check that the "Unable to connect" line arrives with the `Error:` prefix and matches too. If it does not, add `*unable to connect*` to the gate, so the line still sets `bob_failure_detail_emitted` and reaches the classifier
- [ ] Do NOT classify the localized max-turns / max-cost `{type:"error"}` messages as transient. They are deterministic caps
- [ ] Tests, using fixtures copied verbatim from the bundle strings: `Error: Server Error. Bob's backend service is experiencing issues. Please try again.` on a non-zero exit emits `BOB_TRANSIENT_ERROR`. `Error: Unable to connect to Bob's backend service. Check your network connection.` on a non-zero exit emits it. Either line on a zero exit emits nothing. A `tool_result` error whose output contains either phrase is never classified. A max-turns `error` event with text from `translations/de.json` is not transient and still fails the run. The existing cases are unchanged
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh`; must pass before next task

### Task 3: Teach the modes about background execution and command timeouts

**Files:**
- Modify: `scripts/bob-as-claude/modes/ralphex-task.yaml`
- Modify: `scripts/bob-as-claude/modes/ralphex-review.yaml`
- Modify: `scripts/bob-as-claude/modes/ralphex-plan.yaml`
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`

- [ ] In `ralphex-task` and `ralphex-review` `customInstructions`, add: run tests, linters, and builds in the foreground with an explicit `timeout_seconds` sized to the command (max 270). If a command must run longer and is backgrounded, poll its log until the process has exited and read its final result before acting on it. Never commit, mark a checkbox, or emit a ralphex signal while a background process you started is still running. Before your final response, stop every background process you started by signaling its whole process group, `kill -TERM -<pid>` with the pid the tool returned, as bob's own tool result instructs
- [ ] In `ralphex-plan`, add that planning must not start background processes
- [ ] Keep all three files plain ASCII, with no duplicate slugs/groups and unchanged `groups` lists
- [ ] Tests: extend the existing mode-content assertions to require the background/timeout wording in task and review and the no-background line in plan. Keep the existing ASCII / YAML-parse / groups checks green
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_test.sh`; must pass before next task

### Task 4: Check whether bob leaves background processes behind (experiment only, no cleanup code)

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh` (a comment only)

Bob 2.0.6 starts background commands detached (their own session and process group) and, from reading its code, never stops them on a headless exit (its process registry is reachable only from the TUI). That is a conclusion from the bundle, not an observation: nobody has run bob with a background command and looked at what survives it. Cleanup code for this would be hard to get right and dangerous when wrong (it signals processes), and seven review rounds of an environment-marker design each found a new defect. So this task measures the problem first. Task 3's mode instructions are the mitigation until the numbers say otherwise.

- [ ] Gated on `AGTERM_ENABLED` (see CLAUDE.md "Debugging claude/codex executor streaming"). **Ask the user before running it: it uses real bob and consumes credits.** In a fresh agterm session in a throwaway git repo, run the wrapper against real bob with `BOB_CHAT_MODE=agent`, and a prompt that starts `sh -c 'sleep 600 & exit 0'` with `background: true`, waits a moment, and finishes. After the wrapper exits, list what survived (`pgrep -a sleep`, or `ps -eo pid,pgid,sid,command | grep 'sleep 600'`) and kill only what the test started, by pid
- [ ] Repeat once with a longer-lived shape that mirrors a real task: a backgrounded `npm run dev`-style server, or `go test ./... &` in a Go repo. Note whether bob itself ever starts a background process unprompted (it "starts longer-running processes in the background automatically") and whether the Task 3 mode instructions (poll to completion, then `kill -TERM -<pid>`) make it clean up after itself when asked. Run the second case once with the shipped `ralphex-task` mode installed and once with `BOB_CHAT_MODE=agent`
- [ ] Capture the `tool_result` for a backgrounded command and for an outside-workspace read, and confirm both match the shapes recorded in Context
- [ ] Record the findings in a comment beside the bob launch line: whether anything survived, what shape survived, whether the Task 3 instructions changed the outcome, and the bob version tested. If agterm is unavailable, the user declines the run, or no one is present to answer (an unattended ralphex run, which is the common case), do not wait and do not run real bob: record "unverified against real bob" instead, tick the checkbox, and move on. Never stall on this task and never spend credits without explicit approval
- [ ] If something does survive in a realistic run, say so to the user and stop: cleanup becomes its own plan, designed from the observed behavior. Constraints that plan must honor, learned the hard way in review: signal only processes this run provably started; never `pkill` by pattern; the wrapper stays in ralphex's process group so `killProcessGroup` can SIGKILL bob on cancellation; any `/proc` scan must never let grep's exit status 1 or 2 abort the wrapper under `set -euo pipefail`; shared per-user daemons (Gradle, Kotlin, gpg-agent, language servers) must be exempt by name plus command line; mock tests must redirect the stdio of anything they detach, or the stream FIFO never closes
- [ ] If nothing survives, say so in the comment and in the docs task, and add no code

### Task 5: Correct the outside-workspace, shell, and approval documentation

**Files:**
- Modify: `scripts/bob-as-claude/README.md`
- Modify: `docs/custom-providers.md`
- Modify: `README.md` (root)
- Modify: `CLAUDE.md`
- Modify: `llms.txt`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [ ] Replace each stale approval / outside-workspace sentence with the accurate version. Per-tool confirmation (`ApprovalEngine`) is still interactive-only. Since 2.0.6, the headless outside-workspace gate reads `approval.outsideWorkspaceAllowed` plus `approval.permissionOptions[].enableOutsideWorkspace` for the tool's group, and both default to blocked. Keep the "do not add a preflight / settings-writing installer" guidance and its reasoning. Known stale sites (re-grep before editing; line numbers drift):
  - `scripts/bob-as-claude/README.md`: "What governs tool access" (`is **not** read by`, "installed unconditionally on the headless path"), "Limitations" ("No per-tool confirmation"), "Security considerations" ("no approval config"), "Troubleshooting" ("`bob run` never reads them")
  - `docs/custom-providers.md`: around lines 445-454 (`**not** consulted by`, "installed unconditionally on the headless path and is not configurable", "no approval prerequisite")
  - `README.md` (root): around line 1128 ("does not read the `approval` section")
  - `llms.txt`: the "Headless `bob run` has no approval prompt, and it does not read the `approval` section" paragraph
  - `CLAUDE.md` bob bullet: "bob's `approval.*` settings in `~/.bob/settings/settings.json` are NOT read by `bob run`" and "bob's unconditional outside-workspace block"
- [ ] Add a `--worktree` caveat to the bob README and custom-providers: the progress log is in the main repo, outside the worktree workspace, so bob review phases cannot read `{{PROGRESS_FILE}}` unless the user opts in through those two settings for the `read` group. Show the exact JSON snippet, and say that this also widens interactive `bob chat`. Also note that project-level `.bob/custom_modes.yaml` is resolved from the worktree root (2.0.1 prefers `.git` over `.bob`), so it must be committed to reach worktree runs
- [ ] Document that the wrapper sets both `BOB_BASH_PATH` and `SHELL`, and that `BOB_SHELL` overrides any exported `BOB_BASH_PATH`. Do this in the bob README "Shell pinning" section, the custom-providers env table and Shell pinning section, the root README `BOB_SHELL` bullet (around line 1170), CLAUDE.md's bob bullet, and llms.txt. Correct the "tool description hardcodes bash" wording to the verified 2.0.6 behavior (resolved-shell-derived; still bash for every non-PowerShell shell)
- [ ] Update the transient-retry docs (bob README "Transient backend failures are retried", custom-providers, CLAUDE.md bob bullet) for the two 2.0.6 messages and the "Unable to connect also covers refused/not-found on 2.0.6" trade-off
- [ ] Add a short "background commands" note to the bob README and custom-providers: the 30s/270s `execute_command` timeouts, the Task 3 mode instructions, and the Task 4 finding (what survived a headless exit, or "unverified"). State plainly that ralphex does not clean up background processes bob starts
- [ ] In CLAUDE.md's bob bullet, record the Task 4 result and the constraints a future cleanup plan must honor (listed in Task 4), so nobody rebuilds a group-kill or an unguarded `/proc` scan. Keep it to a few sentences
- [ ] Note that users with an older installed `ralphex-*` mode must remove it and rerun `install-modes.sh` to get the Task 3 instructions (the installer preserves existing slugs)
- [ ] Update "tested against bob 2.0.0" to 2.0.6 (minimum stays 2.0.0). In "Cost control", mention that `--max-cost=0` / `--max-turns=0` mean unlimited on 2.0.6+
- [ ] Update `bob-as-claude_docs_test.sh` assertions that pin the old wording, including the root-README approval assertion (around lines 621-624). Add assertions for the new `BOB_BASH_PATH`, outside-workspace, worktree, and transient-message statements so they cannot drift
- [ ] Run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh`; must pass before next task

### Task 6: Verify acceptance criteria

- [ ] `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` pass
- [ ] `make test` and `make lint` pass (no Go changes expected; confirm nothing regressed)
- [ ] `bash -n` on every modified shell script; `shellcheck` if available
- [ ] Stale-claim check: each site listed in Task 5's first item now states the 2.0.6 outside-workspace behavior. Then run `grep -rniE "not\*?\*? (read|consulted)|does not read|never reads|no approval (config|prerequisite)|unconditional outside-workspace|installed unconditionally" scripts/bob-as-claude docs/custom-providers.md README.md CLAUDE.md llms.txt` and inspect every hit. A hit is acceptable only if it is about per-tool confirmation (`ApprovalEngine`) or unrelated to approval, such as the bash-pin rationale or the result-event wording
- [ ] Ask the user before any real bob toy-project run (it consumes credits); run only with explicit approval

### Task 7: Final documentation pass

- [ ] Re-read the CLAUDE.md bob bullet end to end for consistency with Tasks 1-5 (it is long and cross-references the README)
- [ ] Do not touch CHANGELOG (release-process only)
- [ ] Move this plan to `docs/plans/completed/`
