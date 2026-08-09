# bob-as-claude

IBM Bob Shell CLI (`bob`) wrapper for ralphex, allowing bob to replace Claude Code in task, review, finalize, and plan-creation phases.

Requires **bob 2.0.0 or newer**. bob 1.0.x is not supported — see [Requirements](#requirements).

## Scripts

### bob-as-claude.sh

Wraps the IBM Bob Shell CLI to produce Claude-compatible stream-json output. It translates bob v2's `bob run -f stream-json` JSONL event stream into the `content_block_delta` / `result` events that ralphex's `ClaudeExecutor` parses.

The wrapper runs `bob run -f stream-json --mode=<slug> --trust` with an automatically selected mode slug, then passes the prompt on stdin (not argv) to avoid the 128KB per-arg cap on large prompts. Task and review runs forward assistant `message` text line by line, so a `<<<RALPHEX:...>>>` signal split across streaming deltas is re-assembled and emitted in one delta. Plan runs buffer the same assistant text and stop at the first complete validated `QUESTION`, `PLAN_DRAFT`, `PLAN_READY`, or `TASK_FAILED` boundary; Bob is terminated at that point so its autonomous continuation cannot replace a valid interactive boundary with a prose summary.

Automatic selection uses the shipped `ralphex-task`, `ralphex-review`, and `ralphex-plan` custom modes. Install them before using automatic selection; the wrapper does not silently fall back to a built-in mode when a shipped mode is absent.

Suppressed events (user-message echo, reasoning messages, non-terminal tool calls) are emitted as empty keepalive deltas so a configured `idle_timeout` does not kill a healthy session during a long silent tool run. bob's stdout and stderr are merged into a single stream so ordering is preserved; non-JSON diagnostic lines are forwarded as text deltas for ralphex error/limit pattern detection, and any literal `<<<RALPHEX:` token in them is neutralized to `<<< RALPHEX:` (a space is inserted) so stray diagnostics cannot be mistaken for a real completion signal.

**Configuration** (`~/.config/ralphex/config` or `.ralphex/config`):

```ini
claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh
claude_args =
```

For a one-off run without editing config:

```bash
ralphex --claude-command=/path/to/scripts/bob-as-claude/bob-as-claude.sh docs/plans/feature.md
```

## Setup

Setup is two steps: install the custom modes, then grant bob the approvals a headless run needs.

```bash
bash scripts/bob-as-claude/install-modes.sh                    # step 1: modes only
bash scripts/bob-as-claude/install-modes.sh --grant-approvals  # step 2: modes + approvals
```

### Step 1: installing custom modes

The installer creates Bob's active global `~/.bob/settings/custom_modes.yaml` when needed. If only the legacy `~/.bob/custom_modes.yaml` exists, it merges that file so Bob can migrate the complete document on its next start. It preserves unrelated modes, appends only missing ralphex slugs, treats an existing ralphex slug as a user-owned override, and is idempotent. Conservative syntax checks run before and after the merge, followed by an atomic replacement; malformed or unsupported input fails without changing the target. Set `BOB_CUSTOM_MODES_FILE=/path/to/custom_modes.yaml` to use another target.

Bob gives a project-level `.bob/custom_modes.yaml` precedence over global modes. A project entry with the same slug shadows the installed ralphex mode; set `BOB_CUSTOM_MODES_FILE=.bob/custom_modes.yaml` to install intentionally at project scope. Existing ralphex slugs are never overwritten, so remove an old entry before rerunning the installer when you want the latest shipped definition.

bob v2 accepts only these tool-group names: `read`, `edit`, `execute`, `mcp`, `skill`, `todo`, `subagent`, `mode`. An invalid name silently grants nothing (v1's `command` and `browser` are gone — shell access is `execute`), and omitting `groups` grants nothing at all. The shipped modes have these exact tool groups:

| Mode | Tool groups | Purpose |
|---|---|---|
| `ralphex-task` | `read`, `edit`, `execute` | One task section at a time, including task and finalize prompts. |
| `ralphex-review` | `read`, `edit`, `execute`, `subagent` | Parallel native `spawn_subagent` review work, consolidated and verified fixes, tests, commits, and ralphex signals. |
| `ralphex-plan` | `read`, `edit`, `execute` | Interactive plan creation without source edits; writes the accepted plan under `docs/plans`. |

### Step 2: granting approvals

Headless `bob run` registers no interactive approval handler — there is no TTY to prompt and no per-run auto-approve flag (`--yolo` was removed in v2, and `--auto-approve` exists only on `bob chat`, which `bob run` rejects). Bob's only input is the `approval` section of `~/.bob/settings/settings.json`, whose defaults are `allowed_permissions: ["read"]` and a read-only `approvedCommands` list. Without a grant, `edit` and real commands (`go test`, `git commit`, `make lint`) are not approved and a task run does no work.

`install-modes.sh --grant-approvals` merges the needed settings:

- unions `approval.allowed_permissions` with `read`, `edit`, `execute`, `subagent`, `todo`
- unions `approvedCommands` on the `approval.allowedExecutors` record whose `toolId` is `execute_command` with `git`, `go`, `make`, `npm`, `npx`, `gofmt`, `golangci-lint`, `python3`, `cat`, `grep`, `head`, `tail`, `ls`, `sort`, `wc`, `which`, `du`, `df` (command matching is longest-prefix with no wildcard, so prefixes must be enumerated). `allowedExecutors` is an **array** of `{toolId, approvedCommands, deniedCommands}` records that bob looks up with `Array.prototype.find` — an object-shaped value makes every approval throw a `TypeError`
- sets `approval.autoApprovalEnabled` to true only when the key is absent
- never touches `deniedCommands`, warns when `forbiddenApprovalGroups` already blocks a granted permission, backs the file up, validates JSON before and after, writes atomically, and is idempotent

The read-only tail of that prefix list (`cat` through `df`) is not extra privilege. Bob's settings merge does not recurse into arrays, so a written `approvedCommands` array **replaces** bob's read-only defaults wholesale; those prefixes restate the defaults the project prefixes do not already subsume. `todo` is granted for the same forward-compatibility reason — no shipped mode declares the `todo` group today.

Set `BOB_SETTINGS_FILE=/path/to/settings.json` to target another file. **The grant is machine-wide:** bob's global directory is `~/.bob` with no environment override, so broadening `approvedCommands` affects all bob usage on the machine, not just ralphex-invoked runs. That is why the flag is opt-in and left to an explicit, user-run command.

The wrapper itself never writes to `~/.bob/`. It only runs a preflight check and prints one actionable stderr warning naming the installer when the settings path cannot be resolved (file missing, or `HOME` unset with no `BOB_SETTINGS_FILE`), `allowed_permissions` lacks `edit`/`execute`, `autoApprovalEnabled` is false, or `forbiddenApprovalGroups` blocks a needed permission. A review prompt additionally requires `subagent`, since `ralphex-review` drives native subagents. It warns and continues, never aborts.

**Environment variables:**

- `BOB_CHAT_MODE` — explicit mode slug override, passed to bob's `--mode`. Any non-empty built-in slug (`agent`, `plan`, or `ask` — bob v2's only built-ins) or custom-mode slug is passed through unchanged and overrides automatic phase detection. Empty: select a shipped ralphex mode from the prompt markers.
- `BOB_MODEL` — accepted for compatibility and **ignored**; bob v2 stable has no model selection. A non-empty value produces one stderr note.
- `BOB_VERBOSE` — set to `1` to include task/review `tool_result` output, `[tool]` markers, and reasoning message text (default: `0`; plan mode emits only the validated boundary)
- `BOB_EXTRA_ARGS` — extra flags appended verbatim to the bob invocation (word-split on whitespace). The wrapper builds the bob command line itself and ignores unknown flags, so this is the only way to pass through arbitrary bob options. Example: `BOB_EXTRA_ARGS="--max-cost=5"`. **Limitation:** word-splitting does NOT preserve quotes; arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`.
- `BOB_SETTINGS_FILE` — override the approval-settings path (default `~/.bob/settings/settings.json`) used by the wrapper's preflight and by `install-modes.sh --grant-approvals`.

**Model and effort:** neither is forwarded to bob. ralphex supplies `--model` and `--effort` with each value in the following argv entry; the wrapper also accepts `--model=<m>` and `--effort=<e>` for direct invocations, plus `BOB_MODEL`. All are accepted and **ignored** — bob v2 stable removed `-m`/`--model` (it is gated behind an internal dev gateway key) and has never had an `--effort` flag — with one stderr note per non-empty value so ralphex's per-phase model flags cannot fail a bob run.

### Automatic phase selection

With an empty `BOB_CHAT_MODE`, the wrapper scans prompt text outside fenced ` ``` ` and `~~~` blocks. A fence closes only with the matching delimiter character and at least the opening delimiter's length. The first matching rule wins:

- exact review headers (`## Step 2: Launch [ALL 5 ]Review Agents IN PARALLEL`) or generated agent lines (`Use the Task tool [with model=...] to launch a <type> agent with this prompt:`) select `ralphex-review`;
- the complete plan signal set `<<<RALPHEX:QUESTION>>>`, `<<<RALPHEX:PLAN_DRAFT>>>`, and `<<<RALPHEX:PLAN_READY>>>` selects `ralphex-plan`;
- all other prompts, including task and finalize prompts, select `ralphex-task`.

Review markers take precedence over the complete plan signal set. Review instructions live in `ralphex-review.customInstructions`; the wrapper passes review prompts unchanged. `<<<RALPHEX:REVIEW_DONE>>>` is an output signal and is not a phase-selection marker.

### Review subagents and `idle_timeout`

bob v2 has native subagents, so `ralphex-review` instructs Bob to launch every review-agent assignment as a `spawn_subagent` call, issuing all assignments in a single turn so they run in parallel, then consolidate the findings into its final response. Nested bob is blocked natively by bob itself through a `BOB_SESSION` environment check, so the wrapper installs no guard shims on the child `PATH` and the mode carries no "never delegate" instruction.

Subagent lifecycle callbacks are debug-log only in v2, so subagent work produces **no stream events**. A parallel review can stay silent for a long stretch. Use a generous `idle_timeout` for bob review phases, or leave it disabled; a value tuned for Claude's chattier stream will kill healthy bob review sessions.

### `--trust`

The wrapper always passes `--trust` so bob writes to the real filesystem. Without it, bob's writes go to a sandbox and do not persist — task work would be lost. Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would override the real-filesystem behavior. `--trust` also keeps `autoApprovalEnabled` in effect, since an untrusted workspace forces it off.

### Plan-mode boundaries

Plan runs buffer token-level assistant `message` deltas and detect boundaries from that text alone; reasoning messages (`isReasoning: true`) are excluded. `QUESTION` payloads must be a valid JSON object with a non-empty `question` string and a non-empty array of non-empty `options`, and `PLAN_DRAFT` must be non-empty; the earliest valid boundary wins. The boundary is emitted as one Claude text delta, Bob is terminated, and trailing autonomous output is discarded. If Bob exits without any complete valid boundary, the wrapper reports an error and exits non-zero instead of silently starting another plan iteration.

The shipped `ralphex-plan` mode requires boundaries to be returned as ordinary assistant text (never a tool call) and forbids writing questions, drafts, or status messages into the ralphex progress log. Because the installer preserves existing user-owned slugs, remove an older installed `ralphex-plan` entry before rerunning `install-modes.sh` if you want the updated mode instructions.

## Testing

```bash
bash scripts/bob-as-claude/bob-as-claude_test.sh
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
```

The unit test uses a mock bob — no real API calls are made.

## Requirements

- `bob` CLI installed and accessible, **version 2.0.0 or newer** (the wrapper depends on the `run` subcommand, `-f stream-json`, `--mode=<slug>`, `--trust`, and the v2 event schema). bob 1.0.x is not supported: it has no `run` subcommand, and the wrapper contains no version-detection branch or v1 compatibility layer. Verify with `bob --version`.
- `jq` for JSON translation
- `awk` for fence-aware phase-marker detection outside ```/~~~ blocks
- approvals granted in `~/.bob/settings/settings.json` (see [Step 2: granting approvals](#step-2-granting-approvals))

## Limitations

- **`BOB_EXTRA_ARGS` word-splitting does not preserve quotes.** A value like `--flag="a b"` is split into multiple tokens, and arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`. Use a wrapper script that calls bob directly instead.
- **No model or effort selection.** bob v2 stable removed `-m`/`--model`, and bob has never had an `--effort` flag. `--model`, `--effort`, and `BOB_MODEL` are accepted and ignored with a stderr note; there is no `BOB_EFFORT` env var. Use `BOB_CHAT_MODE` to control behavior instead.
- **Approvals are a machine-wide prerequisite.** Headless bob cannot prompt, so `edit`/`execute` work depends on `~/.bob/settings/settings.json`. Bob offers no per-run or per-directory override, so granting approvals affects every bob invocation on the machine.
- **Custom modes must be installed for automatic selection.** Run `bash scripts/bob-as-claude/install-modes.sh` first, or set `BOB_CHAT_MODE` to a mode that is already installed. The wrapper does not silently fall back to built-in modes.
- **Subagent activity is invisible.** bob v2 emits no stream events for subagent lifecycle, so a parallel review phase can look idle for a long time. Tune or disable `idle_timeout` accordingly.
- **bob v2 auto-loads skills from `~/.claude/skills`.** Its default global skill directories include Claude Code's, so a skill installed there is loaded into bob sessions and its instructions can compete with the ralphex prompt — the same skill-conflict class documented for codex. If a run behaves as though following different instructions, check what is installed there.
- **bob version drift.** The wrapper is tested against bob 2.0.0. If bob changes its stream-json schema, the jq field extraction will need updating. A line that does not parse as an event is forwarded as a diagnostic rather than crashing the run, but an unrecognized event type translates to a keepalive, so new schema shapes would go unreported.
- **A built-in mode may still call tools you did not intend.** Bob's built-in modes are not replacements for the tool restrictions in the shipped ralphex modes; prefer the shipped slugs over `BOB_CHAT_MODE=agent`.

## Security considerations

- **The granted approvals auto-approve tool calls, and `--trust` writes to the real filesystem.** This is required for unattended task/review execution (ralphex has no TTY to confirm tool calls). Ensure the working directory is a git repository so changes are isolated to a feature branch. Do NOT run the wrapper in a directory with sensitive files you don't want bob to modify.
- **Approval grants are broad and machine-wide.** `--grant-approvals` widens `allowed_permissions` and `approvedCommands` for every bob run on the machine. Review the printed summary. Narrowing the prefix list is possible by editing the settings file afterwards, but note that bob's merge does not recurse into arrays: any hand-written `approvedCommands` array replaces bob's read-only defaults, so drop the read-only prefixes only if you also accept losing those defaults.
- **The wrapper never writes to `~/.bob/`.** Approval changes only happen through the explicit, user-run installer flag; the wrapper warns and continues.
- **stderr signal neutralization.** The wrapper re-emits bob's non-JSON diagnostic output as `content_block_delta` events so ralphex's error/limit pattern detection works. Any literal `<<<RALPHEX:` token there is neutralized to `<<< RALPHEX:` (space inserted) so stray diagnostics cannot be mistaken for a real completion signal. Rate-limit and `API Error:` phrases pass through verbatim for error/limit detection.
- **Fence-aware phase selection.** Review and plan markers inside ` ``` ` or `~~~` blocks are ignored. This prevents quoted documentation or examples from changing the selected mode. `<<<RALPHEX:REVIEW_DONE>>>` is intentionally not a trigger because it is an output signal.
- **Prompt delivery via stdin, not argv.** The prompt is written to a temp file and piped to bob via stdin, avoiding the 128KB per-arg cap and preventing the prompt from appearing in `ps`/process listings (argv is visible to other users on the same host).

## Troubleshooting

### bob does nothing, or reports it cannot edit files / run commands

Approvals are missing. Headless `bob run` cannot prompt for them and there is no auto-approve flag in v2. Run:

```bash
bash scripts/bob-as-claude/install-modes.sh --grant-approvals
```

The wrapper prints a stderr warning naming this command when its preflight detects missing or blocked approvals.

### No assistant text in the progress log

For task and review runs, the wrapper forwards assistant message text and skips tool execution events as noise; reasoning messages are suppressed by default. Plan mode intentionally emits only a validated interactive boundary. To see task/review tool activity and reasoning, export `BOB_VERBOSE=1` before running ralphex (ralphex passes `claude_command` to the OS verbatim as the executable, so an inline `env VAR=val` prefix would not work — the child inherits the exported environment instead):

```bash
export BOB_VERBOSE=1
ralphex docs/plans/feature.md
```

A review phase that goes quiet for a long stretch is expected: subagents emit no stream events.

### Files not written to disk

Ensure `--trust` is present (it is by default). Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would redirect bob's writes to a sandbox that doesn't persist. If files are still unwritten, check that `edit` is in `approval.allowed_permissions`.

### Model selection not working

Expected. bob v2 stable has no model selection — `-m`/`--model` is gated behind an internal dev gateway key. The wrapper accepts `--model`, `--model=<m>`, and `BOB_MODEL`, prints a one-line stderr note, and forwards nothing. Downgrading to bob 1.0.x to regain `-m` is not supported by this wrapper.

### `--effort` ignored

Expected. bob has no `--effort` flag. The wrapper strips it and emits a stderr note for non-empty values. Use `BOB_CHAT_MODE` to control behavior instead.

### Automatic mode selection not working

Install the shipped modes before automatic selection:

```bash
bash scripts/bob-as-claude/install-modes.sh
```

Check the prompt for the exact review or plan markers documented above. To force a known built-in or custom slug for one run, set `BOB_CHAT_MODE=<slug>`; explicit overrides take precedence over all prompt markers. If a mode installs but grants no tools, check its `groups` for a v1 name (`command`, `browser`) — invalid group names silently grant nothing.

### Cost control

Use `BOB_EXTRA_ARGS="--max-cost=5"` or `--max-turns=<n>` to cap a run. Note that hitting either cap surfaces as a `{"type":"error"}` event, which the wrapper translates to an error line and a non-zero exit.
