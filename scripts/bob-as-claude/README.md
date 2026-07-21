# bob-as-claude

IBM Bob Shell CLI (`bob`) wrapper for ralphex, allowing bob to replace Claude Code in task, review, finalize, and plan-creation phases.

## Scripts

### bob-as-claude.sh

Wraps the IBM Bob Shell CLI to produce Claude-compatible stream-json output. It translates bob's `--output-format=stream-json` JSONL event stream into the `content_block_delta` / `result` events that ralphex's `ClaudeExecutor` parses.

The wrapper runs bob with an automatically selected `--chat-mode=<slug>`, `--output-format=stream-json`, `--yolo`, and `--trust`, then passes the prompt on stdin (not argv) to avoid the 128KB per-arg cap on large prompts. Task and review runs add `--hide-intermediary-output` and translate `attempt_completion.parameters.result`. Plan runs keep assistant deltas visible, prepend a Bob-specific terminal-tool protocol, and stop at the first complete validated `QUESTION`, `PLAN_DRAFT`, `PLAN_READY`, or `TASK_FAILED` boundary. This prevents Bob's forced tool-use continuation from replacing a valid interactive boundary with a malformed prose summary.

Automatic selection uses the shipped `ralphex-task`, `ralphex-review`, and `ralphex-plan` custom modes. Install them before using automatic selection; the wrapper does not silently fall back to a built-in mode when a shipped mode is absent.

Suppressed events (init header, user-message echo, non-terminal tool calls) are emitted as empty keepalive deltas so a configured `idle_timeout` does not kill a healthy session during a long silent tool run. bob's stderr is re-emitted after the main stream for ralphex error/limit pattern detection; any literal `<<<RALPHEX:` token on stderr is neutralized to `<<< RALPHEX:` (a space is inserted) so stray diagnostics cannot be mistaken for a real completion signal.

**Configuration** (`~/.config/ralphex/config` or `.ralphex/config`):

```ini
claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh
claude_args =
```

For a one-off run without editing config:

```bash
ralphex --claude-command=/path/to/scripts/bob-as-claude/bob-as-claude.sh docs/plans/feature.md
```

### Installing custom modes

Install the shipped modes into Bob's global custom-mode document before the first automatic run:

```bash
bash scripts/bob-as-claude/install-modes.sh
```

The installer creates Bob's active global `~/.bob/settings/custom_modes.yaml` when needed. If only the legacy `~/.bob/custom_modes.yaml` exists, it merges that file so Bob can migrate the complete document on its next start. It preserves unrelated modes, appends only missing ralphex slugs, treats an existing ralphex slug as a user-owned override, and is idempotent. Conservative syntax checks run before and after the merge, followed by an atomic replacement; malformed or unsupported input fails without changing the target. Set `BOB_CUSTOM_MODES_FILE=/path/to/custom_modes.yaml` to use another target.

Bob gives a project-level `.bob/custom_modes.yaml` precedence over global modes. A project entry with the same slug shadows the installed ralphex mode; set `BOB_CUSTOM_MODES_FILE=.bob/custom_modes.yaml` to install intentionally at project scope. Existing ralphex slugs are never overwritten, so remove an old entry before rerunning the installer when you want the latest shipped definition.

The shipped modes have these exact tool groups:

| Mode | Tool groups | Purpose |
|---|---|---|
| `ralphex-task` | `read`, `edit`, `command`, `browser` | One task section at a time, including task and finalize prompts. |
| `ralphex-review` | `read`, `edit`, `command`, `browser` | Sequential review-agent work in the current Bob session, verified fixes, tests, commits, and ralphex signals. |
| `ralphex-plan` | `read`, `edit`, `command`, `browser` | Interactive plan creation without source edits; writes the accepted plan under `docs/plans`. |

**Environment variables:**

- `BOB_CHAT_MODE` — explicit chat-mode slug override. Any non-empty built-in slug (`ask`, `code`, `plan`, or `advanced`) or custom-mode slug is passed through unchanged and overrides automatic phase detection. Empty: select a shipped ralphex mode from the prompt markers.
- `BOB_MODEL` — model to use (passed as `-m` when ralphex does not supply `--model`)
- `BOB_VERBOSE` — set to `1` to include task/review `tool_result` output and `[tool]` markers (default: `0`; plan mode emits only the validated boundary)
- `BOB_EXTRA_ARGS` — extra flags appended verbatim to the bob invocation (word-split on whitespace). The wrapper builds the bob command line itself and ignores unknown flags, so this is the only way to pass through arbitrary bob options. Example: `BOB_EXTRA_ARGS="--max-coins=100"`. **Limitation:** word-splitting does NOT preserve quotes; arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`. Use a wrapper script instead.

**Model and effort:** ralphex supplies `--model` and `--effort` with each value in the following argv entry. The wrapper also accepts `--model=<m>` and `--effort=<e>` for direct invocations. Model values are forwarded to bob's `-m` option (bob 1.0.6 supports it; verified empirically). Effort is accepted but **ignored** — bob has no `--effort` flag and rejects it with exit 1 (`Unknown argument: effort`), so the wrapper strips it and prints a one-line stderr note for non-empty values.

### Automatic phase selection

With an empty `BOB_CHAT_MODE`, the wrapper scans prompt text outside fenced ` ``` ` and `~~~` blocks. A fence closes only with the matching delimiter character and at least the opening delimiter's length. The first matching rule wins:

- exact review headers (`## Step 2: Launch [ALL 5 ]Review Agents IN PARALLEL`) or generated agent lines (`Use the Task tool [with model=...] to launch a <type> agent with this prompt:`) select `ralphex-review`;
- the complete plan signal set `<<<RALPHEX:QUESTION>>>`, `<<<RALPHEX:PLAN_DRAFT>>>`, and `<<<RALPHEX:PLAN_READY>>>` selects `ralphex-plan`;
- all other prompts, including task and finalize prompts, select `ralphex-task`.

Review markers take precedence over the complete plan signal set. Review instructions live in `ralphex-review.customInstructions`; the wrapper passes review prompts unchanged. Because Bob has no native sub-agent orchestration, review mode requires assignments to run sequentially in the current session. The wrapper resolves its top-level Bob executable first, then places review-only `bob`, `claude`, and `codex` guard shims on the child `PATH`; attempts to emulate sub-agents with nested or background CLI processes fail immediately instead of consuming provider capacity or outliving the parent tool call. Plan prompts receive the strict Bob terminal-tool protocol described below. `<<<RALPHEX:REVIEW_DONE>>>` is an output signal and is not a phase-selection marker.

### `--trust` and `--yolo`

The wrapper passes `--yolo --trust` so bob auto-approves all tool calls and writes to the real filesystem. Without `--trust`, bob's writes go to a sandbox and do not persist — task work would be lost. Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would override the real-filesystem behavior.

### `--hide-intermediary-output`

Task and review runs use `--hide-intermediary-output` so `attempt_completion.parameters.result` carries the full result text. Plan runs intentionally omit the flag and buffer token-level assistant `message` deltas. Complete `<thinking>...</thinking>` sections are excluded from boundary detection; the first valid plan boundary is emitted as one Claude text delta, Bob is terminated, and trailing autonomous output is discarded. A correctly formatted `attempt_completion.result` remains the preferred fast path. If Bob exits without any complete valid boundary, the wrapper reports an error and exits non-zero instead of silently starting another plan iteration.

The prepended plan protocol also tells Bob to place the exact boundary in `attempt_completion.result` and never write questions, drafts, or status messages into the ralphex progress log. The shipped `ralphex-plan` mode repeats these rules. Because the installer preserves existing user-owned slugs, remove an older installed `ralphex-plan` entry before rerunning `install-modes.sh` if you want the updated mode instructions; the wrapper-level protocol applies immediately regardless.

## Testing

```bash
bash scripts/bob-as-claude/bob-as-claude_test.sh
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
```

The unit test uses a mock bob — no real API calls are made.

## Requirements

- `bob` CLI installed and accessible (v1.0.6+; the wrapper depends on `-m`/`--model`, `--chat-mode=<slug>`, `--output-format=stream-json`, `--hide-intermediary-output`, `--yolo`, `--trust` being available)
- `jq` for JSON translation
- `awk` for fence-aware phase-marker detection outside ```/~~~ blocks

## Limitations

- **`BOB_EXTRA_ARGS` word-splitting does not preserve quotes.** A value like `--flag="a b"` is split into multiple tokens, and arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`. Use a wrapper script that calls bob directly instead.
- **`--effort` is a no-op.** bob has no `--effort` flag and rejects it with exit 1. The wrapper strips it and emits a stderr note for non-empty values. There is no `BOB_EFFORT` env var (nothing to map it to). Use `BOB_CHAT_MODE` to control behavior instead.
- **Custom modes must be installed for automatic selection.** Run `bash scripts/bob-as-claude/install-modes.sh` first, or set `BOB_CHAT_MODE` to a mode that is already installed. The wrapper does not silently fall back to built-in modes.
- **bob version drift.** The wrapper is tested against bob 1.0.6. If bob changes its stream-json schema or removes `-m`/`--model`, the jq pipeline will need updating. The `fromjson?` + `objects` guard prevents hard crashes (malformed lines are skipped), but translation would silently produce no output for unrecognized event types.
- **bob exit code on unknown flags is 0, not non-zero.** A misconfigured `BOB_EXTRA_ARGS` with an invalid flag may silently produce no output. The wrapper's fallback `result` event ensures ralphex still sees a terminal event, but the task would appear to succeed with no work done. Test `BOB_EXTRA_ARGS` manually first (`bob --help`).
- **`--chat-mode ask` may still call tools.** Empirically, `ask` mode with `--hide-intermediary-output` still produced an `attempt_completion` tool call (the expected terminal tool). Bob's built-in modes are not replacements for the tool restrictions in the shipped ralphex modes.

## Security considerations

- **`--yolo --trust` auto-approves all tool calls and writes to the real filesystem.** This is required for unattended task/review execution (ralphex has no TTY to confirm tool calls). Ensure the working directory is a git repository so changes are isolated to a feature branch. Do NOT run the wrapper in a directory with sensitive files you don't want bob to modify.
- **stderr signal neutralization.** The wrapper re-emits bob's stderr as `content_block_delta` events so ralphex's error/limit pattern detection works. Any literal `<<<RALPHEX:` token on stderr is neutralized to `<<< RALPHEX:` (space inserted) so stray diagnostics cannot be mistaken for a real completion signal. Rate-limit and `API Error:` phrases pass through verbatim for error/limit detection.
- **Fence-aware phase selection.** Review and plan markers inside ` ``` ` or `~~~` blocks are ignored. This prevents quoted documentation or examples from changing the selected mode. `<<<RALPHEX:REVIEW_DONE>>>` is intentionally not a trigger because it is an output signal.
- **Prompt delivery via stdin, not argv.** The prompt is written to a temp file and piped to bob via stdin, avoiding the 128KB per-arg cap and preventing the prompt from appearing in `ps`/process listings (argv is visible to other users on the same host).

## Troubleshooting

### No assistant text in the progress log

For task and review runs, the wrapper emits only `attempt_completion` result text by default and skips tool execution events as noise. Plan mode intentionally emits only a validated interactive boundary. To see task/review tool activity, export `BOB_VERBOSE=1` before running ralphex (ralphex passes `claude_command` to the OS verbatim as the executable, so an inline `env VAR=val` prefix would not work — the child inherits the exported environment instead):

```bash
export BOB_VERBOSE=1
ralphex docs/plans/feature.md
```

### Files not written to disk

Ensure `--trust` is present (it is by default — the wrapper passes `--yolo --trust`). Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would redirect bob's writes to a sandbox that doesn't persist.

### Model selection not working

bob 1.0.6 supports `-m`/`--model`. If using an older bob, upgrade. Ralphex supplies `--model` and its value as separate argv entries; direct wrapper calls may also use `--model=<m>`. Both forms forward to bob's `-m`. Set `BOB_MODEL` in the environment for a model that applies when ralphex does not supply `--model`.

### `--effort` ignored

Expected. bob has no `--effort` flag and rejects it with exit 1. The wrapper strips it and emits a stderr note for non-empty values. Use `BOB_CHAT_MODE` to control behavior instead.

### Automatic mode selection not working

Install the shipped modes before automatic selection:

```bash
bash scripts/bob-as-claude/install-modes.sh
```

Check the prompt for the exact review or plan markers documented above. To force a known built-in or custom slug for one run, set `BOB_CHAT_MODE=<slug>`; explicit overrides take precedence over all prompt markers.

### Cost control

Use `BOB_EXTRA_ARGS="--max-coins=100"` to cap spend. Test the flag manually first (`bob --max-coins=100 --help`) since bob exits 0 (not non-zero) on unknown flags, which can silently produce no output.
