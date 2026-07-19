# bob-as-claude

IBM Bob Shell CLI (`bob`) wrapper for ralphex, allowing bob to replace Claude Code in task and review phases.

## Scripts

### bob-as-claude.sh

Wraps the IBM Bob Shell CLI to produce Claude-compatible stream-json output. Acts as a drop-in replacement for `claude` in task and review phases. It translates bob's `--output-format stream-json` JSONL event stream into the `content_block_delta` / `result` events that ralphex's `ClaudeExecutor` parses. Plan creation mode (`ralphex --plan`) has no bob-specific adapter and is untested.

The wrapper runs bob with `--chat-mode <mode> --output-format stream-json --hide-intermediary-output --yolo --trust` and passes the prompt on stdin (not argv) to avoid the 128KB per-arg cap on large review prompts. `--hide-intermediary-output` suppresses token-level assistant deltas, giving a clean event stream where `attempt_completion.parameters.result` carries the complete result text. `--yolo --trust` auto-approve tool calls and write to the real filesystem (without `--trust`, bob's writes go to a sandbox and don't persist).

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

**Environment variables:**

- `BOB_CHAT_MODE` — bob chat mode: `ask` (read-only), `code` (writes/commands), `plan` (planning), `advanced` (complex multi-step). Default: `code`. Invalid values exit 1 with a clear error.
- `BOB_MODEL` — model to use (passed as `-m` when ralphex does not append a `--model` flag)
- `BOB_VERBOSE` — set to `1` to include `tool_result` output and `[tool]` markers in the stream (default: `0`, only `attempt_completion` result text is shown)
- `BOB_EXTRA_ARGS` — extra flags appended verbatim to the bob invocation (word-split on whitespace). The wrapper builds the bob command line itself and ignores unknown flags, so this is the only way to pass through arbitrary bob options. **Limitation:** word-splitting does NOT preserve quotes; arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`. Use a wrapper script instead.

**Model and effort:** ralphex appends `--model <m>` / `--effort <e>` per phase. `--model` is forwarded to bob's `-m` (bob 1.0.6 supports it; verified empirically). `--effort` is accepted but **ignored** — bob has no `--effort` flag and rejects it with exit 1 (`Unknown argument: effort`), so the wrapper must strip it. A one-line note is printed to stderr when a non-empty `--effort` value is passed.

### Chat modes

| Mode | Use case | Notes |
|------|----------|-------|
| `code` (default) | Task execution, review with fixes | Enables `write_to_file`, terminal commands — required for real task work. Recommended for task and review phases. |
| `ask` | Read-only review, Q&A | Bob may still call `attempt_completion` (the terminal tool). If `ask` mode calls unexpected write tools, the review adapter's sequential instructions discourage it, but the wrapper does not enforce read-only behavior. |
| `plan` | Planning | Use `BOB_CHAT_MODE=plan` for `ralphex --plan`. The wrapper has no plan-specific adapter (like pi); documented as untested. |
| `advanced` | Complex multi-step tasks | Bob's most capable mode. |

### Review adapter

bob exposes no parallel sub-agents, so the wrapper prepends a sequential-review adapter when a review prompt is detected. The adapter instructs bob to interpret review "Task tool" instructions as sequential steps, executing each review agent's work one at a time using bob's `read`, `bash`, `edit`, and `write` tools, and applying fixes after completing all review steps.

**Strict trigger:** the adapter is prepended ONLY when `<<<RALPHEX:REVIEW_DONE>>>` appears as a standalone line in the prompt AND that line is not inside a fenced code block (` ``` ` or `~~~`). This avoids prompt-injection false positives where the token appears inside code blocks, strings, or other embedded contexts. A standalone-line check alone is not enough: a fenced code block can contain the token on its own line.

### `--trust` and `--yolo`

The wrapper passes `--yolo --trust` so bob auto-approves all tool calls and writes to the real filesystem. Without `--trust`, bob's writes go to a sandbox and do not persist — task work would be lost. Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would override the real-filesystem behavior.

### `--hide-intermediary-output`

The wrapper uses `--hide-intermediary-output` to get a clean event stream: only `init`, `message`, `tool_use`, `tool_result`, and `result` events arrive, and `attempt_completion.parameters.result` carries the full result text (not token-split). Without this flag, bob emits token-level `message` deltas that would require line-buffering machinery (like the pi wrapper). Do not override this via `BOB_EXTRA_ARGS`.

## Testing

```bash
bash scripts/bob-as-claude/bob-as-claude_test.sh
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
```

The unit test uses a mock bob — no real API calls are made.

## Requirements

- `bob` CLI installed and accessible (v1.0.6+; the wrapper depends on `-m`/`--model`, `--chat-mode`, `--output-format stream-json`, `--hide-intermediary-output`, `--yolo`, `--trust` being available)
- `jq` for JSON translation
- `awk` for the strict review-adapter fence-state tracking

## Limitations

- **`BOB_EXTRA_ARGS` word-splitting does not preserve quotes.** A value like `--flag "a b"` is split into three tokens (`--flag`, `"a`, `b"`), not two (`--flag`, `a b`). Arguments containing spaces or quotes cannot be expressed via `BOB_EXTRA_ARGS`. Use a wrapper script that calls bob directly instead.
- **`--effort` is a no-op.** bob has no `--effort` flag and rejects it with exit 1. The wrapper strips it and emits a stderr note for non-empty values. There is no `BOB_EFFORT` env var (nothing to map it to). Use `BOB_CHAT_MODE` to control behavior instead.
- **Plan creation is untested.** The wrapper has no plan-specific adapter (like pi). `ralphex --plan` with bob is untested.
- **bob version drift.** The wrapper is tested against bob 1.0.6. If bob changes its stream-json schema or removes `-m`/`--model`, the jq pipeline will need updating. The `fromjson?` + `objects` guard prevents hard crashes (malformed lines are skipped), but translation would silently produce no output for unrecognized event types.
- **bob exit code on unknown flags is 0, not non-zero.** A misconfigured `BOB_EXTRA_ARGS` with an invalid flag may silently produce no output. The wrapper's fallback `result` event ensures ralphex still sees a terminal event, but the task would appear to succeed with no work done. Test `BOB_EXTRA_ARGS` manually first (`bob <args> --help`).
- **`--chat-mode ask` may still call tools.** Empirically, `ask` mode with `--hide-intermediary-output` still produced an `attempt_completion` tool call (the expected terminal tool). If `ask` mode calls unexpected write tools, the adapter text discourages it, but the wrapper does not enforce read-only behavior. `code` mode (default) is the safe choice for task/review.

## Security considerations

- **`--yolo --trust` auto-approves all tool calls and writes to the real filesystem.** This is required for unattended task/review execution (ralphex has no TTY to confirm tool calls). Ensure the working directory is a git repository so changes are isolated to a feature branch. Do NOT run the wrapper in a directory with sensitive files you don't want bob to modify.
- **stderr signal neutralization.** The wrapper re-emits bob's stderr as `content_block_delta` events so ralphex's error/limit pattern detection works. Any literal `<<<RALPHEX:` token on stderr is neutralized to `<<< RALPHEX:` (space inserted) so stray diagnostics cannot be mistaken for a real completion signal. Rate-limit and `API Error:` phrases pass through verbatim for error/limit detection.
- **Review-adapter strict trigger.** The adapter is prepended only when `<<<RALPHEX:REVIEW_DONE>>>` appears as a standalone line outside fenced code blocks. This prevents prompt-injection attacks where a malicious prompt embeds the token inside a code block or string to trick the wrapper into prepending review instructions. A standalone-line check alone is insufficient; the fence-state tracking rejects tokens inside ` ``` ` and `~~~` blocks.
- **Prompt delivery via stdin, not argv.** The prompt is written to a temp file and piped to bob via stdin, avoiding the 128KB per-arg cap and preventing the prompt from appearing in `ps`/process listings (argv is visible to other users on the same host).

## Troubleshooting

### No assistant text in the progress log

The wrapper emits only `attempt_completion` result text by default and skips tool execution events as noise. To see tool activity (file reads, shell commands, edits), export `BOB_VERBOSE=1` before running ralphex (ralphex passes `claude_command` to the OS verbatim as the executable, so an inline `env VAR=val` prefix would not work — the child inherits the exported environment instead):

```bash
export BOB_VERBOSE=1
ralphex docs/plans/feature.md
```

### Files not written to disk

Ensure `--trust` is present (it is by default — the wrapper passes `--yolo --trust`). Do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`; it would redirect bob's writes to a sandbox that doesn't persist.

### Model selection not working

bob 1.0.6 supports `-m`/`--model`. If using an older bob, upgrade. `--model` from ralphex config forwards to bob's `-m`. Set `BOB_MODEL` in the environment for a model that applies when ralphex does not append `--model`.

### `--effort` ignored

Expected. bob has no `--effort` flag and rejects it with exit 1. The wrapper strips it and emits a stderr note for non-empty values. Use `BOB_CHAT_MODE` to control behavior instead.

### Plan creation untested

The wrapper has no plan-specific adapter (like pi). `ralphex --plan` with bob is untested. Set `BOB_CHAT_MODE=plan` if you want to try it, but expect untested behavior.

### Cost control

Use `BOB_EXTRA_ARGS="--max-coins 100"` to cap spend. Test the flag manually first (`bob --max-coins 100 --help`) since bob exits 0 (not non-zero) on unknown flags, which can silently produce no output.