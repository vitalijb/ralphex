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
#                    whitespace (e.g. "--max-coins 100" to cap spend). NOTE: word-splitting
#                    does NOT preserve quotes; arguments containing spaces or quotes cannot
#                    be expressed via BOB_EXTRA_ARGS. Use a wrapper script instead.
#
# NOTE on --model: bob v1.0.6 DOES support -m/--model (contrary to some older docs).
# This wrapper forwards ralphex's --model to bob's -m. --effort is accepted but ignored
# (bob has no --effort flag; a one-line note is printed to stderr when a non-empty value
# is passed). bob rejects unknown flags with exit 1 (e.g. `bob --effort high` exits 1),
# so stripping --effort is mandatory, not cosmetic.
#
# NOTE on review-adapter trigger: the adapter is prepended ONLY when the exact standalone
# line `<<<RALPHEX:REVIEW_DONE>>>` appears in the prompt. It is NOT triggered by the token
# appearing inside code blocks, strings, or other embedded contexts. This avoids prompt-
# injection false positives where a review string is mentioned but no actual review is
# requested.

set -euo pipefail

# verify jq is available (required for JSON translation)
command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not found" >&2; exit 1; }

# verify bob is available
command -v bob >/dev/null 2>&1 || { echo "error: bob is required but not found" >&2; exit 1; }

# ralphex passes prompt via stdin (primary path, avoids Windows 8191-char cmd limit).
# also accept -p flag for backward compatibility with direct invocations.
# --model is forwarded to bob's -m (bob 1.0.6 supports it).
# --effort is accepted but ignored (bob has no --effort flag; bob rejects it with exit 1).
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

# validate BOB_CHAT_MODE: bob accepts ask | code | plan | advanced
case "$BOB_CHAT_MODE" in
    ask|code|plan|advanced) ;;
    *)
        echo "error: BOB_CHAT_MODE must be one of: ask, code, plan, advanced (got '$BOB_CHAT_MODE')" >&2
        exit 1
        ;;
esac

# resolve model: explicit --model flag wins over BOB_MODEL env
model="$model_flag"
[[ -z "$model" ]] && model="$BOB_MODEL"

# --effort is accepted but ignored; emit a note only for a non-empty value
if [[ -n "$effort_flag" ]]; then
    echo "note: bob has no --effort flag; ignoring '$effort_flag'" >&2
fi

# detect review prompts and prepend a bob-appropriate adapter.
# bob exposes no parallel sub-agents, so instruct sequential per-agent review.
#
# STRICT TRIGGER: only prepend the adapter when `<<<RALPHEX:REVIEW_DONE>>>` appears as a
# standalone line in the prompt AND that line is NOT inside a fenced code block
# (``` ... ``` or ~~~ ... ~~~). This avoids false positives where the token appears inside
# code blocks, strings, or other embedded contexts (prompt-injection defense). A standalone
# line check alone is not enough: a fenced code block can contain the token on its own line.
# We track fence state (toggling on ```/~~~ delimiters) and only consider lines outside any
# fence. Inline forms (token inside a longer line, inside a string, etc.) are also rejected
# by the `-x` (exact-match) flag on grep.
if printf '%s\n' "$prompt" | awk '
    /^```/ || /^~~~/ { in_fence = !in_fence; next }
    !in_fence && $0 == "<<<RALPHEX:REVIEW_DONE>>>" { found=1; exit }
    END { exit !found }
'; then
    adapter_text=$'Ralphex review adapter for bob:\n- Interpret review "Task tool" instructions as sequential steps: perform each review agent\'s work one at a time.\n- bob does not support parallel sub-agents, so execute each review task sequentially using bob\'s read, bash, edit, and write tools.\n- Apply fixes after completing all review steps.\n- Keep original review workflow and all <<<RALPHEX:...>>> signals unchanged.'
    prompt="$adapter_text"$'\n\n'"$prompt"
fi

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