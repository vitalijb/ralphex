# bob-as-claude Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add IBM Bob Shell CLI (`bob`) support to ralphex as a custom Claude-compatible wrapper (`scripts/bob-as-claude/`), mirroring the existing `scripts/pi-as-claude/` wrapper, so users can set `claude_command = /path/to/bob-as-claude.sh` and run ralphex task/review phases through bob.

**Architecture:** A single bash wrapper `bob-as-claude.sh` translates bob's native `--output-format stream-json` event stream into the Claude-compatible `content_block_delta` / `result` events that ralphex's `ClaudeExecutor` parses. The wrapper reads the prompt from stdin (primary path) or `-p` (fallback), accepts and ignores ralphex's `--model`/`--effort` flags, maps ralphex phases to bob `--chat-mode` values, prepends a sequential-review adapter for review prompts (bob has no parallel sub-agents), forwards SIGTERM to the bob child, re-emits stderr for error/limit detection, and always emits a fallback `result` event. Two test scripts (`bob-as-claude_test.sh` with a mock bob, `bob-as-claude_docs_test.sh` for README/repo integration) plus README.md round out the deliverable. Repo-level docs (README.md, llms.txt, docs/custom-providers.md, CLAUDE.md) are updated to list the new wrapper.

**Tech Stack:** bash (set -euo pipefail), `jq` (JSON translation), `mktemp`/`mkfifo`, `trap` for cleanup and SIGTERM. No Go changes.

---

## Critical context the implementer MUST read first

### bob v1.0.6 actual flags (verified on the target machine)

The task brief says "bob has no `--model` or `--effort` flag". **This is partially stale.** Verified against `bob --help` on the integration host (bob 1.0.6, `/usr/bin/bob`):

| Flag | Present in bob 1.0.6 | Notes |
|---|---|---|
| Flag | Present in bob 1.0.6 | Notes |
|---|---|---|
| `-m`, `--model` | **YES** | `[string]` — model name. The brief's claim "no --model" is wrong for 1.0.6. |
| `--effort` | **NO** | `bob --effort high` → `Unknown argument: effort`, exit 1. The wrapper MUST strip `--effort` and never forward it. |
| `--chat-mode` | YES | choices: `plan`, `code`, `advanced`, `ask`. Required for phase mapping. |
| `-p`, `--prompt` | YES (deprecated) | Positional prompt is preferred. `-p` still works. |
| positional `query` | YES | One-shot prompt. |
| stdin | YES | `echo "q" \| bob` works; combined with `-p` it is appended to stdin content. |
| `@file` | YES | `bob @prompt.md` reads the file. Verified working in non-interactive mode. |
| `-o`, `--output-format` | YES | choices: `text`, `json`, `stream-json`. |
| `--hide-intermediary-output` | YES | Suppresses everything except `attempt_completion` final output. |
| `--trust` | YES (boolean) | Required for real filesystem writes. |
| `-y`, `--yolo` | YES (boolean) | Auto-approve all tool calls. |
| `--approval-mode` | YES | choices: `default`, `auto_edit`, `yolo`. Alternative to `--yolo`. |
| `-s`, `--sandbox` | YES (boolean) | Isolate execution (files do NOT persist on real FS). Omit for real FS. |
| `--max-coins` | YES (number) | Budget cap; bob exits 1 if exceeded. |
| `--allowed-tools`, `--allowed-mcp-server-names` | YES (array) | Tool allow-lists. |
| `--instance-id`, `--team-id` | YES (string) | Multi-tenant selection. |

**Implication for the wrapper:** `--model` SHOULD be forwarded to bob's `-m`/`--model` (not ignored). Only `--effort` must be silently ignored (with optional stderr note). This matches the pi wrapper's `--model` forwarding pattern and is a strict improvement over the brief. Document this deviation explicitly in README.md and in a code comment so reviewers see the brief was corrected against the real CLI.

### bob stream-json output shapes (verified empirically)

**With `--hide-intermediary-output` (RECOMMENDED for the wrapper):** bob emits a compact stream of lifecycle events and suppresses token-level assistant deltas. Verified stream for `echo "say hello" | bob --chat-mode ask -o stream-json --hide-intermediary-output`:

```jsonl
{"type":"init","timestamp":"...","session_id":"...","model":"premium"}
{"type":"message","timestamp":"...","role":"user","content":"say hello\n\n\n"}
{"type":"tool_use","timestamp":"...","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"\nHello\n"}}
{"type":"tool_result","timestamp":"...","tool_id":"tool-1","status":"success","output":"\nHello\n"}

Hello
{"type":"result","timestamp":"...","status":"success","stats":{"total_tokens":...,"duration_ms":...,"session_costs":...,"tool_calls":1}}
```

Note the **bare plaintext line** (`Hello`) between `tool_result` and `result` — it is NOT JSON. The wrapper's jq pipeline must tolerate non-JSON lines (use `fromjson?` + `objects` like the pi wrapper does).

**Without `--hide-intermediary-output`:** bob also emits token-level assistant deltas:

```jsonl
{"type":"message","timestamp":"...","role":"assistant","content":"<thinking>\n","delta":true}
{"type":"message","timestamp":"...","role":"assistant","content":"The ","delta":true}
{"type":"message","timestamp":"...","role":"assistant","content":"user ","delta":true}
...
```

**Decision: use `--hide-intermediary-output`.** Rationale: (a) the final `attempt_completion` `tool_use` already carries the complete result text in `parameters.result`; (b) token-level deltas are noisy and would force the same line-buffering machinery as the pi wrapper; (c) `--hide-intermediary-output` gives a clean, deterministic event sequence. The wrapper extracts `attempt_completion.parameters.result` as the primary text source. If `BOB_VERBOSE=1` is set, additionally stream `tool_result.output` lines and (optionally) `message` deltas as keepalives/verbose markers — see event mapping table below.

### ralphex invocation contract (verified in `pkg/executor/executor.go:260-294`)

ralphex calls the wrapper as:

```
<wrapper> <claude_args...> [--model <m>] [--effort <e>] --print
```

- Default `claude_args` (when user has not set it): `--dangerously-skip-permissions --output-format stream-json --verbose`. The wrapper MUST ignore these via `*) shift ;;`.
- `--model`/`--effort` are injected only when the phase's `plan_model`/`task_model`/`review_model` config provides them. Either, both, or neither may be present.
- `--print` is ALWAYS appended last.
- Prompt is delivered via **stdin** (primary path). `-p` is accepted only for backward compat with direct invocations.
- `ClaudeExecutor` reads stdout line-by-line as JSON events; it also has a non-JSON fallback that prints lines as-is (so bare plaintext from bob would be tolerated, but we strip it in the wrapper for cleanliness).

### Signal detection (verified in `pkg/status/status.go` and `pkg/executor/executor.go:495`)

ralphex detects these signals via `strings.Contains` on a single `content_block_delta` text block:
- `<<<RALPHEX:ALL_TASKS_DONE>>>`
- `<<<RALPHEX:TASK_FAILED>>>`
- `<<<RALPHEX:REVIEW_DONE>>>`
- `<<<RALPHEX:CODEX_REVIEW_DONE>>>`
- `<<<RALPHEX:QUESTION>>>`
- `<<<RALPHEX:PLAN_READY>>>`
- `<<<RALPHEX:PLAN_DRAFT>>>`

Because bob's `attempt_completion.parameters.result` is a complete string (not token-split), signals land intact in a single block — no line-buffering needed for signal integrity. **However**, if `BOB_VERBOSE=1` streams token-level `message` deltas, the same line-buffering as the pi wrapper is required to avoid splitting signals. Keep the implementation simple: default path emits the whole `parameters.result` as one or more line blocks; verbose path is optional and can reuse the pi buffering pattern.

Error/limit pattern detection (`pkg/executor/executor.go`): ralphex scans for phrases like `"hit your limit"`, `"API Error:"`, retry patterns. These can appear on bob's stderr. The wrapper re-emits stderr as `content_block_delta` events AFTER the main stream, with `<<<RALPHEX:` tokens neutralized to `<<< RALPHEX:` (space inserted) so stray diagnostics cannot be mistaken for real signals — same pattern as pi-as-claude.

### Existing wrapper patterns to mirror

- **pi-as-claude.sh** (230 lines): the gold-standard reference. Copy its structure: `set -euo pipefail`, jq/bob availability guards, `-p`/`--model`/`--effort` arg parsing with `*) shift ;;` catch-all, stdin fallback via `[[ ! -t 0 ]]`, review-adapter injection on `<<<RALPHEX:REVIEW_DONE>>>` detection, temp-dir + mkfifo + prompt-file, SIGTERM trap forwarding to child PID, background jq with interruptible `wait`, stderr re-emission with signal neutralization, fallback `result`, exit-code preservation.
- **codex-as-claude.sh** (105 lines): simpler — no FIFO, no SIGTERM trap, no stderr re-emission. Shows the minimal viable pattern (`printf '%s' "$prompt" | codex ... | while read ... jq ...`). Use this as the conceptual baseline, but adopt pi's robustness features.
- **agy-as-claude.sh** (128 lines): plain-text wrapper. Shows the `unset ${!ANTIGRAVITY_@}` env-isolation pattern — bob has no analogous `BOB_*` recursion risk, so DO NOT add env isolation.
- **pi-as-claude_test.sh** (1060 lines): the test template. Mock-script pattern with `MOCK_STDOUT_FILE`/`MOCK_STDERR_FILE`/`MOCK_EXIT_CODE` env vars, `TMPDIR_TEST` exported so the mock inherits it, `pass()`/`fail()` helpers, comprehensive coverage of arg parsing, event translation, signals, stderr, exit codes, SIGTERM forwarding.
- **pi-as-claude_docs_test.sh** (158 lines): README/repo-integration assertions. Mirror this exactly for bob, swapping `pi` → `bob` and `PI_*` → `BOB_*`.

---

## File structure

```
scripts/bob-as-claude/
├── bob-as-claude.sh          # the wrapper (executable, chmod +x)
├── bob-as-claude_test.sh     # unit tests with mock bob (executable, chmod +x)
├── bob-as-claude_docs_test.sh # README + repo integration tests (executable, chmod +x)
└── README.md                 # setup, env vars, troubleshooting
```

Plus edits to existing repo files (see Task 6):
- `README.md` — add bob to requirements list, alternative-providers list, and env-var list.
- `llms.txt` — add bob to the wrapper inventory sentence and requirements list.
- `docs/custom-providers.md` — add a "## IBM Bob Shell CLI wrapper (included example)" section.
- `CLAUDE.md` — add `scripts/bob-as-claude/` to the project-structure inventory and alternative-provider docs.
- `.github/CODEOWNERS` — no change needed (default `* @umputun` already covers everything).

---

## Flag handling table (wrapper → bob)

| ralphex passes (argv) | Wrapper action | bob flag forwarded |
|---|---|---|
| `-p <prompt>` | capture as `prompt` (fallback path) | — (prompt goes to bob via stdin/file) |
| `--model <m>` | capture as `model_flag`; forward to bob | `-m <m>` (or `--model <m>`) |
| `--effort <e>` | capture as `effort_flag`; **ignore** (bob has no `--effort`); emit one-line stderr note `note: bob has no --effort flag; ignoring '<e>'` (only when value is non-empty, to avoid noise) | — |
| `--print` | ignore (catch-all) | — |
| `--dangerously-skip-permissions` | ignore (catch-all) | — (bob uses `--yolo`/`--trust` instead) |
| `--output-format stream-json` | ignore (catch-all); wrapper itself sets `--output-format stream-json` on the bob invocation | — |
| `--verbose` | ignore (catch-all) | — |
| any other flag | ignore (catch-all `*) shift ;;`) | — |

**bob invocation built by the wrapper:**

```bash
bob_args=(--chat-mode "$BOB_CHAT_MODE" --output-format stream-json --hide-intermediary-output --yolo --trust)
[[ -n "$model" ]] && bob_args+=(-m "$model")
# BOB_EXTRA_ARGS word-split and append (guard for set -u on empty array, like pi)
[[ -n "$BOB_EXTRA_ARGS" ]] && read -ra bob_extra <<< "$BOB_EXTRA_ARGS" && [[ ${#bob_extra[@]} -gt 0 ]] && bob_args+=("${bob_extra[@]}")
```

Prompt is delivered via stdin from a temp file (NOT argv), mirroring pi/codex — avoids the 128KB per-arg cap on large review prompts with full diffs.

---

## Event mapping table (bob stream-json → Claude stream-json)

| bob event | Condition | Wrapper output | Notes |
|---|---|---|---|
| `{"type":"init",...}` | always | **empty keepalive** `{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}` | session header is noise; keepalive prevents idle_timeout kill |
| `{"type":"message","role":"user",...}` | always | **empty keepalive** | echo of our own prompt; noise |
| `{"type":"message","role":"assistant","delta":true}` | only with `BOB_VERBOSE=1` and `BOB_VERBOSE_STREAM=1` | buffered line → `content_block_delta` (text_delta) | only relevant if user disables `--hide-intermediary-output` via `BOB_EXTRA_ARGS`; default path never sees these |
| `{"type":"tool_use","tool_name":"attempt_completion"}` | always | `content_block_delta` with `text: (.parameters.result + "\n")` | **primary text source**; the complete result string. Split on `\n` into multiple line-blocks so each line is its own delta (matches pi behavior) |
| `{"type":"tool_use","tool_name":<other>}` | `BOB_VERBOSE=1` | `content_block_delta` with `text: "[tool] " + .tool_name + "\n"` | verbose marker; default: empty keepalive |
| `{"type":"tool_result","status":"success"}` | `BOB_VERBOSE=1` | `content_block_delta` with `text: (.output + "\n")` | verbose; default: empty keepalive |
| `{"type":"tool_result","status":"error"}` | always | `content_block_delta` with `text: ("[tool_error] " + .output + "\n")` | surface tool failures even in non-verbose mode |
| `{"type":"result","status":"success"}` | always | `{"type":"result","result":""}` | terminal event |
| `{"type":"result","status":"error"}` (or any non-success) | always | `{"type":"result","result":""}` + preserve non-zero exit | treat as terminal; ralphex detects failure via signals/exit code |
| bare non-JSON line (e.g. plaintext echo) | always | skip (tolerate via `fromjson?` + `objects`) | the `Hello` line between tool_result and result |
| malformed JSON / scalar / array | always | skip (tolerate) | `fromjson?` then `objects` guard, exactly like pi |
| EOF (wrapper sentinel) | always | flush any buffered text, then emit fallback `{"type":"result","result":""}` | covers bob exiting without a `result` event |

**Key jq structure** (adapt pi's `foreach` + `inputs` + `fromjson?` + `objects` + `__eof__` sentinel pattern):

```jq
def emit($t): {type: "content_block_delta", delta: {type: "text_delta", text: $t}};
foreach ((inputs | fromjson? | objects), {type: "__eof__"}) as $e (
    {buf: "", out: []};
    if $e.type == "tool_use" and $e.tool_name == "attempt_completion" then
        # split parameters.result on newlines; emit each complete line as its own block
        (($e.parameters.result // "") | tostring | split("\n")) as $parts
        | {buf: "", out: ($parts[0:-1] | map(emit(. + "\n")))}
    elif $e.type == "result" then
        {buf: "", out: [{type: "result", result: ""}]}
    elif $e.type == "__eof__" then
        {buf: "", out: (if .buf != "" then [emit(.buf + "\n")] else [] end)}
    elif $verbose == 1 and $e.type == "tool_result" and ($e.status // "") == "success" then
        {buf: .buf, out: [emit(("[tool_result] " + ($e.output // "") + "\n"))]}
    elif $e.type == "tool_result" and ($e.status // "") == "error" then
        {buf: .buf, out: [emit(("[tool_error] " + ($e.output // "") + "\n"))]}
    else
        {buf: .buf, out: [emit("")]}  # keepalive for init/user message/suppressed events
    end;
    .out[]
)
```

The default (non-verbose) path emits ONE `content_block_delta` per line of `attempt_completion.parameters.result`, then a `result`. Suppressed events emit empty keepalive deltas (same rationale as pi: ralphex's `idle_timeout` resets on every stdout line).

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `BOB_CHAT_MODE` | `code` | bob chat mode for task/review phases: `code` (writes/commands), `ask` (read-only), `plan` (planning), `advanced` (complex multi-step). ralphex does not tell the wrapper which phase it is in, so this is a single global setting; the review adapter text handles review-specific behavior. |
| `BOB_MODEL` | (bob default) | Model used when ralphex does not append a `--model` flag. Forwarded to bob's `-m`. |
| `BOB_VERBOSE` | `0` | `1` to include `tool_result` output and `[tool]` markers in the stream. Default `0` emits only `attempt_completion` result text. |
| `BOB_EXTRA_ARGS` | (none) | Extra flags appended verbatim to the bob invocation (word-split on whitespace). E.g. `--max-coins 100` or `--sandbox`. Guard against `set -u` on empty array (bash 3.2 macOS). |

**Resolution precedence for model:** `--model` flag (from ralphex) > `BOB_MODEL` env > bob default. Same pattern as pi's `--model`/`PI_MODEL`.

**Resolution for effort:** `--effort` flag is accepted but ALWAYS ignored (bob has no `--effort`). Emit a stderr note only when the value is non-empty, so default empty effort doesn't spam. No `BOB_EFFORT` env var (there is nothing to map it to).

---

## Chat-mode phase mapping

ralphex does not pass a phase identifier to the wrapper — it just sends the prompt via stdin. The wrapper uses a single `BOB_CHAT_MODE` env var (default `code`) for all phases. The review-phase adapter text (prepended when `<<<RALPHEX:REVIEW_DONE>>>` is detected in the prompt) handles review-specific sequential-execution instructions.

| ralphex phase | Recommended `BOB_CHAT_MODE` | Rationale |
|---|---|---|
| Task execution | `code` (default) | bob `code` mode enables `write_to_file`, terminal commands — required for real task work. |
| Internal review (first/second) | `code` (default) or `ask` | Review needs to read files and potentially apply fixes. `code` allows fixes; `ask` is read-only but bob may still call tools. **Recommend `code`** so review can apply fixes directly. The adapter text instructs sequential execution. |
| External review (custom script) | N/A | External review uses a separate `custom_review_script`, not the `claude_command` wrapper. |
| Plan creation (`ralphex --plan`) | `plan` (user sets `BOB_CHAT_MODE=plan`) | bob `plan` mode is for planning. The wrapper has no plan-specific adapter (like pi, which is also untested for plan mode). Document as untested. |
| Finalize | `code` (default) | Finalize may write commit messages / files. |

**Review adapter text** (prepended when prompt contains `<<<RALPHEX:REVIEW_DONE>>>`), mirroring pi's adapter:

```
Ralphex review adapter for bob:
- Interpret review "Task tool" instructions as sequential steps: perform each review agent's work one at a time.
- bob does not support parallel sub-agents, so execute each review task sequentially using bob's read, bash, edit, and write tools.
- Apply fixes after completing all review steps.
- Keep original review workflow and all <<<RALPHEX:...>>> signals unchanged.
```

This is a near-verbatim copy of pi's adapter with `pi` → `bob` substitution. The adapter is prepended to the prompt BEFORE the prompt is written to the temp file and piped to bob.

---

## Tasks

### Task 1: Create directory and wrapper skeleton

**Objective:** Create `scripts/bob-as-claude/` with an executable `bob-as-claude.sh` skeleton that passes arg parsing and availability guards but does not yet invoke bob.

**Files:**
- Create: `scripts/bob-as-claude/bob-as-claude.sh` (chmod +x)

**Step 1: Write the skeleton**

```bash
#!/usr/bin/env bash
# bob-as-claude.sh - wraps IBM Bob Shell CLI to produce Claude-compatible stream-json output.
#
# this script translates bob's `--output-format stream-json` event stream into the Claude
# stream-json format that ralphex's ClaudeExecutor can parse, allowing bob to be used as a
# drop-in replacement for claude in task and review phases.
#
# config example (~/.config/ralphex/config or .ralphex/config):
#   claude_command = /path/to/bob-as-claude.sh
#   claude_args =
#
# environment variables:
#   BOB_CHAT_MODE  - bob chat mode: ask | code | plan | advanced (default: code)
#   BOB_MODEL      - model to use (passed as -m when --model flag absent)
#   BOB_VERBOSE    - set to 1 to include tool_result output and [tool] markers (default: 0)
#   BOB_EXTRA_ARGS - extra args appended verbatim to the bob invocation, word-split on
#                    whitespace (e.g. "--max-coins 100" to cap spend)
#
# NOTE on --model: bob v1.0.6 DOES support -m/--model (contrary to some older docs).
# This wrapper forwards ralphex's --model to bob's -m. --effort is accepted but ignored
# (bob has no --effort flag; a one-line note is printed to stderr when a non-empty value
# is passed).

set -euo pipefail

# verify jq is available (required for JSON translation)
command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not found" >&2; exit 1; }

# verify bob is available
command -v bob >/dev/null 2>&1 || { echo "error: bob is required but not found" >&2; exit 1; }

# ralphex passes prompt via stdin (primary path, avoids Windows 8191-char cmd limit).
# also accept -p flag for backward compatibility with direct invocations.
# --model is forwarded to bob's -m (bob 1.0.6 supports it).
# --effort is accepted but ignored (bob has no --effort flag).
# all other flags are ignored gracefully (--dangerously-skip-permissions, --print, etc.)
prompt=""
model_flag=""
effort_flag=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)       prompt="${2:-}"; shift; shift 2>/dev/null || true ;;
        --model)  model_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        --effort) effort_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        *)        shift ;; # ignore unknown flags
    esac
done

if [[ -z "$prompt" ]]; then
    if [[ ! -t 0 ]]; then
        prompt=$(cat)
    fi
fi

if [[ -z "$prompt" ]]; then
    echo "error: no prompt provided (expected -p flag or stdin)" >&2
    exit 1
fi

# configurable via environment
BOB_CHAT_MODE="${BOB_CHAT_MODE:-code}"
BOB_MODEL="${BOB_MODEL:-}"
BOB_VERBOSE="${BOB_VERBOSE:-0}"
if [[ "$BOB_VERBOSE" != "0" && "$BOB_VERBOSE" != "1" ]]; then
    echo "warning: BOB_VERBOSE must be 0 or 1, got '$BOB_VERBOSE', defaulting to 0" >&2
    BOB_VERBOSE=0
fi
BOB_EXTRA_ARGS="${BOB_EXTRA_ARGS:-}"

# resolve model: explicit --model flag wins over BOB_MODEL env
model="$model_flag"
[[ -z "$model" ]] && model="$BOB_MODEL"

# --effort is accepted but ignored; emit a note only for a non-empty value
if [[ -n "$effort_flag" ]]; then
    echo "note: bob has no --effort flag; ignoring '$effort_flag'" >&2
fi

# detect review prompts and prepend a bob-appropriate adapter.
# bob exposes no parallel sub-agents, so instruct sequential per-agent review.
if [[ "$prompt" == *"<<RALPHEX:REVIEW_DONE>>>"* ]]; then
    adapter_text=$'Ralphex review adapter for bob:\n- Interpret review "Task tool" instructions as sequential steps: perform each review agent\'s work one at a time.\n- bob does not support parallel sub-agents, so execute each review task sequentially using bob\'s read, bash, edit, and write tools.\n- Apply fixes after completing all review steps.\n- Keep original review workflow and all <<<RALPHEX:...>>> signals unchanged.'
    prompt="$adapter_text"$'\n\n'"$prompt"
fi

# STUB: bob invocation and jq translation go here (Task 2)
echo '{"type":"content_block_delta","delta":{"type":"text_delta","text":"stub\n"}}'
echo '{"type":"result","result":""}'
exit 0
```

**Step 2: Make executable and verify it runs**

```bash
chmod +x scripts/bob-as-claude/bob-as-claude.sh
echo "test prompt" | bash scripts/bob-as-claude/bob-as-claude.sh
# expected: two JSON lines (stub delta + result), exit 0
```

**Step 3: Commit**

```bash
git add scripts/bob-as-claude/bob-as-claude.sh
git commit -m "feat(bob-as-claude): add wrapper skeleton with arg parsing and guards"
```

---

### Task 2: Implement bob invocation and jq event translation

**Objective:** Replace the STUB with the real bob invocation (temp file + stdin pipe), background jq translation, SIGTERM forwarding, stderr re-emission, and fallback result.

**Files:**
- Modify: `scripts/bob-as-claude/bob-as-claude.sh` (replace the STUB block)

**Step 1: Write the full implementation**

Replace the STUB block with (adapted from pi-as-claude.sh lines 95-230):

```bash
# build bob arguments: JSON event stream, non-interactive, hide intermediary output.
# the prompt is NOT placed on argv — bob reads it from stdin when no positional is given.
# a large review prompt (full diff) can exceed Linux's 128 KB per-arg cap, so we deliver
# it via stdin (see prompt_file below), mirroring pi-as-claude.sh and copilot-as-claude.sh.
bob_args=(--chat-mode "$BOB_CHAT_MODE" --output-format stream-json --hide-intermediary-output --yolo --trust)
[[ -n "$model" ]] && bob_args+=(-m "$model")
# append caller-supplied extra args (word-split). guard on element count, not the raw
# string, so a whitespace-only value does not trip `set -u` on bash 3.2 (macOS system bash).
if [[ -n "$BOB_EXTRA_ARGS" ]]; then
    read -ra bob_extra_args <<< "$BOB_EXTRA_ARGS"
    [[ ${#bob_extra_args[@]} -gt 0 ]] && bob_args+=("${bob_extra_args[@]}")
fi

# all temp files live in one private directory: a single rm -rf cleans up, and the private
# dir avoids a TOCTOU race on the FIFO. the EXIT trap is registered immediately after
# mktemp so a failure in any later setup step cannot leak the directory.
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

stderr_file="$tmp_dir/stderr"
stdout_pipe="$tmp_dir/stdout.fifo"
mkfifo "$stdout_pipe"

# deliver the (possibly adapter-prepended) prompt to bob via stdin, not argv: avoids the
# per-arg length cap on large review prompts containing a full diff.
prompt_file="$tmp_dir/prompt"
printf '%s' "$prompt" > "$prompt_file"

# trap SIGTERM and forward to bob child process for graceful shutdown. the exit fires the
# EXIT trap, which handles cleanup. for this trap to run promptly the translation jq below
# must NOT be a foreground command (bash defers traps until the current foreground external
# command finishes, and jq only exits when bob closes the FIFO), so jq runs in the
# background and the script waits on it with the interruptible `wait` builtin.
bob_pid=""
forward_signal() {
    if [[ -n "$bob_pid" ]]; then
        kill -TERM "$bob_pid" 2>/dev/null || true
    fi
    exit 143
}
trap forward_signal TERM

# run bob in background, capturing stderr and piping stdout through named pipe.
bob "${bob_args[@]}" < "$prompt_file" 2>"$stderr_file" > "$stdout_pipe" &
bob_pid=$!

# translate bob's JSONL event stream into claude stream-json.
# only attempt_completion result text is emitted by default — tool_result output, the
# init/session header, and the user-message echo are noise (include tool lines with
# BOB_VERBOSE=1). suppressed events still emit an EMPTY text delta as a keepalive:
# ralphex's idle_timeout resets on every line of wrapper stdout, so a long silent tool
# execution would otherwise kill a healthy session (the executor skips empty text, so
# keepalives never pollute output or signal detection).
#
# bob's attempt_completion.parameters.result is a complete string (not token-split when
# --hide-intermediary-output is set), so signals land intact in a single block. we still
# split on newlines so each line of the result is its own content_block_delta, matching
# pi's line-at-a-time emission.
#
# event mapping:
#   init, message(role=user)                -> keepalive (empty delta)
#   tool_use(attempt_completion)            -> split parameters.result on \n -> content_block_delta per line
#   tool_use(other)                         -> keepalive (or "[tool] ..." with BOB_VERBOSE=1)
#   tool_result(status=success)             -> keepalive (or "[tool_result] ..." with BOB_VERBOSE=1)
#   tool_result(status=error)               -> "[tool_error] ..." content_block_delta (always)
#   result(status=success or other)         -> {type:"result", result:""}
#   non-JSON / scalar / array / malformed    -> skipped (fromjson? + objects guard)
#   __eof__ sentinel                        -> flush any buffered text
#
# jq runs in the background with an interruptible `wait` so the TERM trap can fire while
# bob is alive (a foreground jq would defer the trap until bob exits).
jq -Rcn --unbuffered --argjson verbose "$BOB_VERBOSE" '
    def emit($t): {type: "content_block_delta", delta: {type: "text_delta", text: $t}};
    foreach ((inputs | fromjson? | objects), {type: "__eof__"}) as $e (
        {buf: "", out: []};
        if $e.type == "tool_use" and ($e.tool_name // "") == "attempt_completion" then
            (($e.parameters.result // "") | tostring | split("\n")) as $parts
            | {buf: "", out: ($parts[0:-1] | map(emit(. + "\n")))}
        elif $e.type == "result" then
            {buf: "", out: [{type: "result", result: ""}]}
        elif $e.type == "__eof__" then
            {buf: "", out: (if .buf != "" then [emit(.buf + "\n")] else [] end)}
        elif $verbose == 1 and $e.type == "tool_result" and ($e.status // "") == "success" then
            {buf: .buf, out: [emit(("[tool_result] " + (($e.output // "") | tostring) + "\n"))]}
        elif $e.type == "tool_result" and ($e.status // "") == "error" then
            {buf: .buf, out: [emit(("[tool_error] " + (($e.output // "") | tostring) + "\n"))]}
        elif $verbose == 1 and $e.type == "tool_use" then
            {buf: .buf, out: [emit(("[tool] " + (($e.tool_name // "") | tostring) + "\n"))]}
        else
            {buf: .buf, out: [emit("")]}
        end;
        .out[]
    )
' < "$stdout_pipe" 2>/dev/null &
jq_pid=$!
wait "$jq_pid" || true

# wait for bob to finish and capture its exit code
bob_exit=0
wait "$bob_pid" || bob_exit=$?
bob_pid=""

# emit stderr as content_block_delta events so ralphex error/limit pattern detection
# still works (bob may report rate limits / failures on stderr). stderr is emitted only
# for error/limit detection, so neutralize any literal `<<<RALPHEX:` signal token first:
# re-emitted stderr runs through ralphex's signal detection, and a stray token on stderr
# must not be mistaken for a real completion signal. inserting a space breaks the prefix
# detectSignal keys while leaving rate-limit / `API Error:` phrases intact.
if [[ -s "$stderr_file" ]]; then
    while IFS= read -r err_line || [[ -n "$err_line" ]]; do
        [[ -z "$err_line" ]] && continue
        err_line="${err_line//<<<RALPHEX:/<<< RALPHEX:}"
        printf '%s\n' "$err_line" | jq -Rc '{type: "content_block_delta", delta: {type: "text_delta", text: (. + "\n")}}'
    done < "$stderr_file"
fi

# emit fallback result event (covers bob exiting without a result event)
echo '{"type":"result","result":""}'

# preserve bob's exit code
exit "$bob_exit"
```

**Step 2: Verify against real bob (smoke test, requires bob installed)**

```bash
echo "reply with exactly: wrapper works" | bash scripts/bob-as-claude/bob-as-claude.sh 2>/dev/null
# expected: a content_block_delta with text "wrapper works\n", then a result event
```

**Step 3: Commit**

```bash
git add scripts/bob-as-claude/bob-as-claude.sh
git commit -m "feat(bob-as-claude): implement bob invocation and jq event translation"
```

---

### Task 3: Write the unit test script (mock bob, no real API calls)

**Objective:** Create `bob-as-claude_test.sh` with a mock bob that emits canned JSONL, covering arg parsing, event translation, signals, stderr, exit codes, and SIGTERM forwarding. Mirror `pi-as-claude_test.sh` structure.

**Files:**
- Create: `scripts/bob-as-claude/bob-as-claude_test.sh` (chmod +x)

**Step 1: Write the test script**

Use the pi test script as the template. The mock bob records args to `$TMPDIR_TEST/bob_args`, captures stdin to `$TMPDIR_TEST/bob_prompt`, and emits `MOCK_STDOUT_FILE` / `MOCK_STDERR_FILE` with `MOCK_EXIT_CODE`. Key differences from pi:

- Mock is named `bob`, not `pi`.
- Arg assertions check for `--chat-mode code` (default), `--output-format stream-json`, `--hide-intermediary-output`, `--yolo`, `--trust`.
- `--model` forwarding test: `--model foo` → bob args contain `-m foo`.
- `BOB_MODEL` env test: when no `--model` flag, `BOB_MODEL=bar` → bob args contain `-m bar`.
- `--effort` test: `--effort high` → bob args do NOT contain `--effort`; stderr contains `note: bob has no --effort flag`.
- `BOB_EXTRA_ARGS` test: `BOB_EXTRA_ARGS="--max-coins 100"` → bob args contain `--max-coins 100`; whitespace-only does not crash.
- Event translation fixtures use bob's event shapes (not pi's):

```jsonl
# minimal_events.txt
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"test\n"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"hello world\n"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"hello world\n"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
```

**Test cases to include (minimum, mirroring pi's coverage):**

1. **bob invocation flags** — `--chat-mode code`, `--output-format stream-json`, `--hide-intermediary-output`, `--yolo`, `--trust` present in bob args.
2. **prompt delivered via stdin** — `bob_prompt` file contains the prompt; prompt NOT on argv.
3. **`--model` forwarding** — `--model anthropic/claude-x` → bob args contain `-m anthropic/claude-x`.
4. **`BOB_MODEL` env** — used as `-m` when `--model` flag absent; `--model` flag overrides `BOB_MODEL`; no `-m` when neither set.
5. **`--effort` ignored** — `--effort high` → bob args do NOT contain `--effort`; stderr contains the note. Empty `--effort ""` → no note printed.
6. **`BOB_EXTRA_ARGS` passthrough** — `--max-coins 100` appended; no positional prompt after extra args; whitespace-only does not crash under `set -u`.
7. **`BOB_CHAT_MODE` env** — `BOB_CHAT_MODE=ask` → bob args contain `--chat-mode ask`.
8. **`BOB_VERBOSE` validation** — invalid value warns and defaults to 0.
9. **`attempt_completion` translation** — `parameters.result` text emitted as `content_block_delta` with trailing newline.
10. **`init`/`message(user)` skipped** — session header and user echo do not leak into output (emitted as empty keepalives).
11. **`result` event translation** — bob `result` → Claude `result`; count assertion (2 total with fallback, like pi).
12. **`tool_result(status=error)` always emitted** — even with `BOB_VERBOSE=0`, a tool error surfaces as `[tool_error] ...`.
13. **`tool_result(status=success)` verbose** — only with `BOB_VERBOSE=1` does success output appear as `[tool_result] ...`.
14. **tool events skipped by default** — `BOB_VERBOSE=0` → no `[tool]` markers; suppressed events emit empty keepalive deltas (count assertion).
15. **invalid JSON tolerated** — scalar/array/malformed lines do not abort translation (fromjson? + objects guard).
16. **fallback result event** — bob exits without `result` → wrapper still emits a terminal `result`.
17. **review-prompt adapter injection** — prompt with `<<<RALPHEX:REVIEW_DONE>>>` → `bob_prompt` contains "Ralphex review adapter for bob"; original signal preserved; non-review prompts NOT adapted.
18. **signal passthrough** — `<<<RALPHEX:ALL_TASKS_DONE>>>` in `attempt_completion.parameters.result` appears verbatim in output.
19. **multi-line result split** — `parameters.result` with embedded `\n` → each line is its own `content_block_delta`.
20. **stderr emission** — stderr text emitted as `content_block_delta` after stdout.
21. **stderr signal neutralization** — `<<<RALPHEX:ALL_TASKS_DONE>>>` on stderr → neutralized to `<<< RALPHEX:` in output; line still emitted.
22. **stderr rate-limit phrase preserved** — `"You've hit your usage limit"` on stderr → emitted verbatim.
23. **exit code preservation** — success (exit 0) and failure (exit 7) both preserved.
24. **empty stdout + stderr limit + non-zero exit** — realistic failure path: stderr limit phrase emitted, fallback result emitted, exit code preserved.
25. **SIGTERM forwarded to bob child** — hang-bob mock that records its PID; kill wrapper with TERM; wrapper exits 143 promptly; bob child dies.
26. **missing prompt** — exits non-zero with "no prompt provided" error.
27. **unknown flags ignored** — `--dangerously-skip-permissions --output-format stream-json --verbose --print` all ignored, output produced.
28. **bob not found** — exits non-zero with "bob is required" error.
29. **jq not found** — exits non-zero with "jq is required" error (jq guard precedes bob guard, like pi).

**Step 2: Run the tests and verify all pass**

```bash
bash scripts/bob-as-claude/bob-as-claude_test.sh
# expected: "results: N passed, 0 failed, N total", exit 0
```

**Step 3: Commit**

```bash
git add scripts/bob-as-claude/bob-as-claude_test.sh
git commit -m "test(bob-as-claude): add unit tests with mock bob"
```

---

### Task 4: Write the README

**Objective:** Create `scripts/bob-as-claude/README.md` mirroring `pi-as-claude/README.md` structure, with bob-specific setup, env vars, event translation, and troubleshooting.

**Files:**
- Create: `scripts/bob-as-claude/README.md`

**Step 1: Write the README**

Structure (mirror pi README):
1. Title: `# bob-as-claude`
2. Intro paragraph: bob CLI wrapper for ralphex, allowing IBM Bob Shell to replace Claude Code in task and review phases.
3. `## Scripts` → `### bob-as-claude.sh` — describes what it wraps, the `--output-format stream-json --hide-intermediary-output` invocation, event translation, keepalive deltas, stderr re-emission with signal neutralization.
4. **Configuration** block with `claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh` and `claude_args =`.
5. One-off run example: `ralphex --claude-command=/path/to/scripts/bob-as-claude/bob-as-claude.sh docs/plans/feature.md`.
6. **Environment variables** list: `BOB_CHAT_MODE`, `BOB_MODEL`, `BOB_VERBOSE`, `BOB_EXTRA_ARGS` (table or bullet list, matching pi's style).
7. **Model and effort** subsection: explain that `--model` is forwarded to bob's `-m` (bob 1.0.6 supports it); `--effort` is accepted but ignored with a stderr note (bob has no `--effort`).
8. **Chat modes** subsection: table of `ask`/`code`/`plan`/`advanced` with use cases; recommend `code` (default) for task/review, `plan` for plan creation (untested).
9. **Review adapter** subsection: explain the sequential-review adapter for `<<<RALPHEX:REVIEW_DONE>>>` prompts (bob has no parallel sub-agents).
10. **`--trust` and `--yolo`** note: explain the wrapper passes `--yolo --trust` so bob auto-approves tools and writes to the real filesystem. Without `--trust`, bob's writes go to a sandbox and don't persist.
11. **`--hide-intermediary-output`** note: explain why the wrapper uses this flag (clean event stream; `attempt_completion.parameters.result` carries the full result).
12. `## Testing` — `bash scripts/bob-as-claude/bob-as-claude_test.sh` and `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh`.
13. `## Requirements` — `bob` CLI (v1.0.6+), `jq`.
14. `## Troubleshooting`:
    - **No assistant text in the progress log** → `export BOB_VERBOSE=1`.
    - **Files not written to disk** → ensure `--trust` is present (it is by default); do NOT pass `--sandbox` via `BOB_EXTRA_ARGS`.
    - **Model selection not working** → bob 1.0.6 supports `-m`; if using an older bob, upgrade. `--model` from ralphex config forwards to `-m`.
    - **`--effort` ignored** → expected; bob has no `--effort`. Use `BOB_CHAT_MODE` to control behavior instead.
    - **Plan creation untested** → the wrapper has no plan-specific adapter; `ralphex --plan` with bob is untested (like pi).
    - **Cost control** → use `BOB_EXTRA_ARGS="--max-coins 100"` to cap spend.

**Step 2: Commit**

```bash
git add scripts/bob-as-claude/README.md
git commit -m "docs(bob-as-claude): add wrapper README"
```

---

### Task 5: Write the docs test script

**Objective:** Create `bob-as-claude_docs_test.sh` mirroring `pi-as-claude_docs_test.sh`, asserting the README and repo-integration points are present and accurate.

**Files:**
- Create: `scripts/bob-as-claude/bob-as-claude_docs_test.sh` (chmod +x)

**Step 1: Write the docs test**

Copy `pi-as-claude_docs_test.sh` and substitute `pi` → `bob`, `PI_` → `BOB_`. Assertions:

1. `assert_executable` for `bob-as-claude.sh` and `bob-as-claude_test.sh`.
2. README contains `claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh`.
3. README documents `BOB_VERBOSE`, `BOB_CHAT_MODE`, `BOB_MODEL`, `BOB_EXTRA_ARGS`.
4. README includes the test command `bash scripts/bob-as-claude/bob-as-claude_test.sh`.
5. `docs/custom-providers.md` contains `## IBM Bob Shell CLI wrapper (included example)`.
6. `docs/custom-providers.md` references `scripts/bob-as-claude/bob-as-claude.sh`.
7. `docs/custom-providers.md` documents bob event translation (assert `attempt_completion` or `tool_use`).
8. `docs/custom-providers.md` documents chat-mode mapping (assert `### Chat modes` or `--chat-mode`).
9. Top-level `README.md` mentions `scripts/bob-as-claude/bob-as-claude.sh`.
10. Top-level `README.md` documents `BOB_CHAT_MODE` (or `BOB_VERBOSE`) env var.
11. Top-level `README.md` requirements list mentions `scripts/bob-as-claude/`.
12. `llms.txt` wrapper inventory mentions `scripts/bob-as-claude/bob-as-claude.sh`.
13. `llms.txt` requirements list mentions `scripts/bob-as-claude/`.
14. `CLAUDE.md` inventory includes `scripts/bob-as-claude/` directory.
15. `CLAUDE.md` alternative-provider docs mention `scripts/bob-as-claude/bob-as-claude.sh`.

**Step 2: Run the docs test (will FAIL until Task 6 completes the repo edits)**

```bash
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
# expected: failures on assertions 5-15 (repo docs not yet updated)
```

**Step 3: Commit**

```bash
git add scripts/bob-as-claude/bob-as-claude_docs_test.sh
git commit -m "test(bob-as-claude): add docs/repo integration test"
```

---

### Task 6: Update repo-level documentation

**Objective:** Add bob to the wrapper inventory in `README.md`, `llms.txt`, `docs/custom-providers.md`, and `CLAUDE.md` so the docs test passes.

**Files:**
- Modify: `README.md` (3 edits: requirements list, alternative-providers list, env-var list)
- Modify: `llms.txt` (2 edits: wrapper inventory sentence, requirements list)
- Modify: `docs/custom-providers.md` (1 new section after the pi section)
- Modify: `CLAUDE.md` (2 edits: project-structure inventory, alternative-provider docs)

**Step 1: README.md — requirements list (after line 903)**

Add after the `pi` line:

```
- `bob` - IBM Bob Shell CLI, alternative provider for Claude phases (optional, via `scripts/bob-as-claude/`)
```

**Step 2: README.md — alternative-providers list (after line 1118)**

Add after the pi bullet:

```
- [`scripts/bob-as-claude/bob-as-claude.sh`](https://github.com/umputun/ralphex/blob/master/scripts/bob-as-claude/bob-as-claude.sh) wraps the IBM Bob Shell CLI, translating its `--output-format stream-json` events into Claude-compatible events
```

**Step 3: README.md — env-var list (after line 1155)**

Add after the `PI_EXTRA_ARGS` bullet:

```
- `BOB_CHAT_MODE`, `BOB_MODEL` - bob chat mode (ask/code/plan/advanced) and model selection
- `BOB_VERBOSE` - set to `1` to include tool_result output and `[tool]` markers in the stream (default: `0`, only attempt_completion result text is shown)
- `BOB_EXTRA_ARGS` - extra flags appended verbatim to the bob invocation (word-split on whitespace); e.g. `--max-coins 100` to cap spend
```

Also update line 1146 (`The included Codex, Copilot, and pi wrappers require jq...`) to include bob:

```
The included Codex, Copilot, pi, and bob wrappers require `jq` on `PATH` for JSON translation.
```

And update line 1174 (the "wrappers under `scripts/...` ship in the source tree" sentence) to add `scripts/bob-as-claude/`:

```
The wrappers under `scripts/codex-as-claude/`, `scripts/copilot-as-claude/`, `scripts/gemini-as-claude/`, `scripts/agy-as-claude/`, `scripts/opencode/`, `scripts/pi-as-claude/`, and `scripts/bob-as-claude/` ship in the source tree but are not bundled with the binary. Vendor the one you need into your project (`.ralphex/scripts/`) or reference it from a checkout.
```

**Step 4: llms.txt — wrapper inventory (line 160)**

Update the inventory sentence to add `scripts/bob-as-claude/bob-as-claude.sh`:

```
**Alternative providers for Claude phases:** `claude_command` and `claude_args` config options allow replacing Claude Code with any CLI that produces compatible stream-json output. Included wrappers: `scripts/codex-as-claude/codex-as-claude.sh`, `scripts/copilot-as-claude/copilot-as-claude.sh`, `scripts/gemini-as-claude/gemini-as-claude.sh`, `scripts/agy-as-claude/agy-as-claude.sh`, `scripts/opencode/opencode-as-claude.sh`, `scripts/pi-as-claude/pi-as-claude.sh`, `scripts/bob-as-claude/bob-as-claude.sh`. Set `claude_command = /path/to/wrapper` in config, or use `--claude-command=/path/to/wrapper` for one run. Wrappers should ignore unknown flags gracefully. Use `--claude-args=` only when a wrapper cannot tolerate configured/default Claude flags and they must be cleared for a single run. See `docs/custom-providers.md` for details on writing wrappers for other tools (Gemini CLI, local LLMs, etc.).
```

**Step 5: llms.txt — requirements list (after line 122)**

Add after the `pi` line:

```
- `bob` - IBM Bob Shell CLI, alternative provider for Claude phases (optional, via `scripts/bob-as-claude/`)
```

**Step 6: docs/custom-providers.md — new section (after the pi section, before "## Writing your own wrapper")**

Add a new section `## IBM Bob Shell CLI wrapper (included example)` mirroring the pi section structure:

- Intro: wrapper at `scripts/bob-as-claude/bob-as-claude.sh` translates bob's `--output-format stream-json` event stream to Claude stream-json format. Uses `jq`.
- Wrapper runs bob with `--chat-mode <mode> --output-format stream-json --hide-intermediary-output --yolo --trust` and passes the prompt on stdin.
- **Setup** block with `claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh` and one-off run example.
- **Environment variables** table: `BOB_CHAT_MODE` (default `code`), `BOB_MODEL`, `BOB_VERBOSE` (default `0`), `BOB_EXTRA_ARGS`.
- **Model and effort mapping** subsection: `--model` forwarded to bob's `-m` (bob 1.0.6 supports it); `--effort` accepted but ignored (bob has no `--effort`; stderr note emitted for non-empty values).
- **Chat modes** table: `ask`/`code`/`plan`/`advanced` with use cases; recommend `code` for task/review.
- **Event translation** table (from the Event mapping table above).
- **How it works** code example showing bob's JSONL → Claude stream-json.
- **Review adapter** note: sequential execution for `<<<RALPHEX:REVIEW_DONE>>>` prompts.
- **`--trust` and `--yolo`** note: required for real filesystem writes.
- **Plan creation** note: untested (like pi).

**Step 7: CLAUDE.md — project-structure inventory**

Add `scripts/bob-as-claude/` to the scripts section (near the pi line):

```
scripts/bob-as-claude/ # IBM Bob Shell CLI wrapper for Claude-compatible output
```

**Step 8: CLAUDE.md — alternative-provider docs**

Add bob wrapper path mention alongside the pi wrapper path.

**Step 9: Run the docs test to verify all assertions pass**

```bash
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
# expected: "summary: N passed, 0 failed, N total", exit 0
```

**Step 10: Commit**

```bash
git add README.md llms.txt docs/custom-providers.md CLAUDE.md
git commit -m "docs: add bob-as-claude wrapper to repo documentation"
```

---

### Task 7: Final verification

**Objective:** Run all tests and verify the wrapper works end-to-end with real bob.

**Step 1: Run all wrapper tests**

```bash
bash scripts/bob-as-claude/bob-as-claude_test.sh
bash scripts/bob-as-claude/bob-as-claude_docs_test.sh
```

Both must exit 0 with 0 failures.

**Step 2: Smoke test with real bob (if installed)**

```bash
echo "reply with exactly: end-to-end works" | bash scripts/bob-as-claude/bob-as-claude.sh 2>/dev/null
# expected: content_block_delta with "end-to-end works\n", then result event, exit 0
```

**Step 3: Verify no regressions in existing wrapper tests**

```bash
bash scripts/pi-as-claude/pi-as-claude_test.sh
bash scripts/pi-as-claude/pi-as-claude_docs_test.sh
bash scripts/agy-as-claude/agy-as-claude_test.sh
bash scripts/codex-as-claude/codex-as-claude_test.sh
```

All must still pass (the bob additions are purely additive; no existing files are changed in a way that affects other wrappers).

**Step 4: Verify file permissions**

```bash
ls -la scripts/bob-as-claude/
# bob-as-claude.sh, bob-as-claude_test.sh, bob-as-claude_docs_test.sh must be -rwxr-xr-x
```

---

## Risks and gotchas

1. **bob `--effort` rejection is silent (exit 0).** `bob --effort high` prints `Unknown argument: effort` and exits 0 (not non-zero). This means if the wrapper accidentally passed `--effort` to bob, bob would silently exit without doing the task. The wrapper MUST strip `--effort` (accept and ignore it), never forward it. Verified empirically.

2. **bob `--model` IS supported in 1.0.6.** The task brief says bob has no `--model`, but `bob --help` and empirical testing confirm `-m`/`--model` works. The wrapper forwards `--model` to `-m`. If a future bob version removes `-m`, the wrapper would pass an unknown flag and bob would exit 0 silently. Mitigation: document the bob 1.0.6 version dependency in README; the `bob --help` check at wrapper startup does NOT validate flag support, so this is a runtime risk.

3. **bob `--hide-intermediary-output` changes the event stream.** Without it, bob emits token-level `message` deltas (`delta:true`) that would require the pi-style line-buffering machinery. With it, only `tool_use`/`tool_result`/`result` events arrive, and `attempt_completion.parameters.result` carries the full text. The wrapper uses `--hide-intermediary-output` for simplicity. If a user overrides this via `BOB_EXTRA_ARGS="--no-hide-intermediary-output"` (hypothetical), the wrapper's jq would emit keepalives for the token deltas (they'd match the `else` branch), which is acceptable but loses the token text. Document that `--hide-intermediary-output` is required and should not be overridden.

4. **bob's bare plaintext line between `tool_result` and `result`.** With `--hide-intermediary-output`, bob emits a non-JSON plaintext line (the final result text) between the `tool_result` and `result` JSON events. The wrapper's jq pipeline uses `fromjson?` + `objects`, so this plaintext line is silently skipped. The text is already captured from `attempt_completion.parameters.result`, so no information is lost. Verified empirically.

5. **bob stderr includes `[WARN]` lines for unreadable directories.** When run in `/tmp`, bob prints `[WARN] Skipping unreadable directory: ...` to stderr. These are benign but will be re-emitted as `content_block_delta` events by the wrapper's stderr handler. ralphex's error/limit pattern detection should not match `[WARN]`, so this is harmless noise. If it becomes a problem, the wrapper could filter `[WARN]` lines, but that risks suppressing real warnings — leave as-is and document.

6. **bob exit code on unknown flags is 0, not non-zero.** This means a misconfigured `BOB_EXTRA_ARGS` with an invalid flag will silently produce no output. The wrapper's fallback `result` event ensures ralphex still sees a terminal event, but the task would appear to succeed with no work done. Mitigation: document that `BOB_EXTRA_ARGS` should be tested manually first (`bob <args> --help`).

7. **No `BOB_EFFORT` env var.** Unlike pi's `PI_THINKING`, there is no bob equivalent to map `--effort` to. Do not invent one. The `--effort` flag is purely a no-op with a stderr note.

8. **bob `--chat-mode ask` may still call tools.** The brief raises this as an open question. Empirically, `ask` mode with `--hide-intermediary-output` still produced an `attempt_completion` tool call (which is how bob returns its result). This is fine — `attempt_completion` is the expected terminal tool. If `ask` mode calls unexpected write tools, the adapter text's "read-only" instruction should discourage it, but the wrapper does not enforce read-only behavior. Document that `code` mode (default) is the safe choice for task/review.

9. **SIGTERM trap and background jq.** The pi wrapper's comment (lines 131-145) explains why jq must run in the background with an interruptible `wait`: bash defers traps until the current foreground external command finishes, and jq only exits when bob closes the FIFO. Copy this pattern exactly. A foreground jq would make the wrapper unresponsive to SIGTERM while bob is alive.

10. **`set -u` and empty arrays on bash 3.2.** The `BOB_EXTRA_ARGS` word-split uses `read -ra` and guards on `${#bob_extra_args[@]} -gt 0` before expanding. This mirrors pi's guard (lines 106-110) for macOS system bash compatibility. Do not simplify to `[[ -n "$BOB_EXTRA_ARGS" ]] && bob_args+=($BOB_EXTRA_ARGS)` — that trips `set -u` on empty arrays in bash 3.2.

11. **Prompt-file vs `@file` delivery.** bob supports `bob @prompt.md` (file prompt), which is simpler than the temp-file + stdin pipe. However, the pi/codex wrappers use stdin for consistency and to avoid any file-path edge cases (permissions, special chars). Stick with stdin from a temp file. The `@file` approach is documented as an alternative in the bob skill but not used by the wrapper.

12. **bob version drift.** The wrapper is tested against bob 1.0.6. bob's event shapes (`type: init/message/tool_use/tool_result/result`) and flags (`-m`, `--chat-mode`, `--hide-intermediary-output`) are specific to this version. Document the version dependency in README. If bob changes its stream-json schema, the jq pipeline will need updating — the `fromjson?` + `objects` guard prevents hard crashes (malformed lines are skipped), but the translation logic would silently produce no output for unrecognized event types.

---

## Out of scope (explicitly NOT in this plan)

- Go code changes to `pkg/executor/` or `pkg/config/`. The wrapper is a pure bash script; ralphex's `ClaudeExecutor` already handles it via `claude_command`.
- A first-class `--bob` flag (like `--codex`). That would require Go changes and is a separate, larger effort. The wrapper uses the `claude_command` config path only.
- A bob-specific custom review script (`scripts/bob-as-claude/bob-review.sh`). External review uses a separate `custom_review_script`; if needed, it can be added later by pointing `custom_review_script` at a script that calls `bob` directly. Not part of this plan.
- Plan-creation (`ralphex --plan`) testing with bob. The wrapper has no plan-specific adapter (like pi). Documented as untested.
- Parallel sub-agent support. bob has no parallel sub-agents; the review adapter instructs sequential execution. No Go-side multi-agent wiring.
- MCP server configuration for bob. bob supports `bob mcp add`, but that is user-side setup, not wrapper responsibility.

---

## Verification checklist (implementer must confirm before declaring done)

- [ ] `scripts/bob-as-claude/bob-as-claude.sh` exists, is executable, and passes `bash -n` (syntax check).
- [ ] `scripts/bob-as-claude/bob-as-claude_test.sh` exists, is executable, passes with 0 failures, and makes NO real API calls (uses mock bob).
- [ ] `scripts/bob-as-claude/bob-as-claude_docs_test.sh` exists, is executable, passes with 0 failures.
- [ ] `scripts/bob-as-claude/README.md` exists and documents all 4 env vars, config snippet, test commands, requirements, and troubleshooting.
- [ ] `README.md` updated: requirements list, alternative-providers list, env-var list, jq-requirement sentence, source-tree sentence.
- [ ] `llms.txt` updated: wrapper inventory sentence, requirements list.
- [ ] `docs/custom-providers.md` has a new "## IBM Bob Shell CLI wrapper (included example)" section.
- [ ] `CLAUDE.md` updated: project-structure inventory, alternative-provider docs.
- [ ] Existing wrapper tests (`pi-as-claude`, `agy-as-claude`, `codex-as-claude`) still pass.
- [ ] Smoke test with real bob (if installed) produces `content_block_delta` + `result` events.
- [ ] All commits use conventional-commit messages (`feat(bob-as-claude):`, `test(bob-as-claude):`, `docs(bob-as-claude):`, `docs:`).