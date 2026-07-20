#!/usr/bin/env bash
# bob-as-claude.sh - wraps IBM Bob Shell CLI to produce Claude-compatible stream-json output.
#
# this script translates bob's stream-json event stream into the Claude stream-json format
# that ralphex's ClaudeExecutor can parse.
#
# environment variables:
#   BOB_CHAT_MODE  - explicit bob chat-mode slug override (default: automatic)
#   BOB_MODEL      - model to use when --model is absent
#   BOB_VERBOSE    - set to 1 to include tool_result output and tool markers (default: 0)
#   BOB_EXTRA_ARGS - extra bob arguments, word-split on whitespace

set -euo pipefail

# verify required commands before doing any prompt work.
command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not found" >&2; exit 1; }
command -v bob >/dev/null 2>&1 || { echo "error: bob is required but not found" >&2; exit 1; }

# accept prompts through stdin, with -p retained for direct invocations.
prompt=""
model_flag=""
effort_flag=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)       prompt="${2:-}"; shift; shift 2>/dev/null || true ;;
        --model)  model_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        --effort) effort_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        *)        shift ;;
    esac
done

if [[ -z "$prompt" && ! -t 0 ]]; then
    prompt=$(cat)
fi
if [[ -z "$prompt" ]]; then
    echo "error: no prompt provided (expected -p flag or stdin)" >&2
    exit 1
fi

# load environment configuration.
BOB_CHAT_MODE="${BOB_CHAT_MODE:-}"
BOB_MODEL="${BOB_MODEL:-}"
BOB_VERBOSE="${BOB_VERBOSE:-0}"
if [[ "$BOB_VERBOSE" != "0" && "$BOB_VERBOSE" != "1" ]]; then
    echo "warning: BOB_VERBOSE must be 0 or 1, got '$BOB_VERBOSE', defaulting to 0" >&2
    BOB_VERBOSE=0
fi
BOB_EXTRA_ARGS="${BOB_EXTRA_ARGS:-}"

# resolve the model and retain the existing effort compatibility note.
model="$model_flag"
[[ -z "$model" ]] && model="$BOB_MODEL"
if [[ -n "$effort_flag" ]]; then
    echo "note: bob has no --effort flag; ignoring '$effort_flag'" >&2
fi

# classify unconfigured prompts outside fenced code blocks. explicit overrides are
# intentionally unrestricted so users can select built-in or installed custom slugs.
selected_chat_mode="$BOB_CHAT_MODE"
if [[ -z "$selected_chat_mode" ]]; then
    selected_chat_mode=$(printf '%s\n' "$prompt" | awk '
        /^[[:space:]]*```/ || /^[[:space:]]*~~~/ { in_fence = !in_fence; next }
        !in_fence && /Use the Task tool to launch/ { review = 1 }
        !in_fence && /Launch.*Review Agents IN PARALLEL/ { review = 1 }
        !in_fence && /<<<RALPHEX:QUESTION>>>/ { question = 1 }
        !in_fence && /<<<RALPHEX:PLAN_DRAFT>>>/ { draft = 1 }
        !in_fence && /<<<RALPHEX:PLAN_READY>>>/ { ready = 1 }
        END {
            if (review) print "ralphex-review"
            else if (question && draft && ready) print "ralphex-plan"
            else print "ralphex-task"
        }
    ')
fi

# build bob arguments. the prompt is delivered through stdin, not argv.
bob_args=("--chat-mode=$selected_chat_mode" --output-format stream-json --hide-intermediary-output --yolo --trust)
[[ -n "$model" ]] && bob_args+=(-m "$model")
if [[ -n "$BOB_EXTRA_ARGS" ]]; then
    read -ra bob_extra_args <<< "$BOB_EXTRA_ARGS"
    for arg in "${bob_extra_args[@]}"; do
        [[ -n "$arg" ]] && bob_args+=("$arg")
    done
fi

# keep temporary files together so cleanup is one private directory operation.
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

stderr_file="$tmp_dir/stderr"
stdout_pipe="$tmp_dir/stdout.fifo"
mkfifo "$stdout_pipe"
prompt_file="$tmp_dir/prompt"
printf '%s' "$prompt" > "$prompt_file"

# forward termination to bob while jq drains the named pipe in the background.
bob_pid=""
forward_signal() {
    if [[ -n "$bob_pid" ]]; then
        kill -TERM "$bob_pid" 2>/dev/null || true
    fi
    exit 143
}
trap forward_signal TERM

bob "${bob_args[@]}" < "$prompt_file" 2>"$stderr_file" > "$stdout_pipe" &
bob_pid=$!

# translate bob events into claude-compatible text deltas and terminal results.
jq -Rcn --unbuffered --argjson verbose "$BOB_VERBOSE" '
    def emit($t): {type: "content_block_delta", delta: {type: "text_delta", text: $t}};
    foreach ((inputs | fromjson? | objects), {type: "__eof__"}) as $e (
        {buf: "", out: []};
        if $e.type == "tool_use" and ($e.tool_name // "") == "attempt_completion" then
            (($e.parameters.result // "") | tostring | split("\n")) as $parts
            | if ($parts[-1] // "") == "" then
                {buf: "", out: ($parts[0:-1] | map(emit(. + "\n")))}
              else
                {buf: "", out: ($parts | map(emit(. + "\n")))}
              end
        elif $e.type == "result" then
            {buf: .buf, out: [{type: "result", result: ""}]}
        elif $e.type == "__eof__" then
            {buf: .buf, out: (if .buf != "" then [emit(.buf + "\n")] else [] end)}
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

# preserve bob's exit status after the translation process has drained.
bob_exit=0
wait "$bob_pid" || bob_exit=$?
trap - TERM
bob_pid=""

# forward stderr for executor error detection, but neutralize signal-looking text.
if [[ -s "$stderr_file" ]]; then
    while IFS= read -r err_line || [[ -n "$err_line" ]]; do
        [[ -z "$err_line" ]] && continue
        err_line="${err_line//<<<RALPHEX:/<<< RALPHEX:}"
        printf '%s\n' "$err_line" \
            | jq -Rc '{type: "content_block_delta", delta: {type: "text_delta", text: (. + "\n")}}'
    done < "$stderr_file"
fi

echo '{"type":"result","result":""}'
exit "$bob_exit"
