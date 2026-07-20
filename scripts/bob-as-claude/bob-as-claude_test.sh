#!/usr/bin/env bash
# bob-as-claude_test.sh — tests for bob-as-claude.sh wrapper.
#
# run from the ralphex directory:
#   bash scripts/bob-as-claude/bob-as-claude_test.sh
#
# requires: jq, bash, awk
# uses a mock bob — no real api calls are made.

set -euo pipefail

unset BOB_CHAT_MODE BOB_MODEL BOB_VERBOSE BOB_EXTRA_ARGS
unset BOB_CUSTOM_MODES_FILE MOCK_STDOUT_FILE MOCK_STDERR_FILE MOCK_EXIT_CODE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$SCRIPT_DIR/bob-as-claude.sh"
TMPDIR_TEST=$(mktemp -d)
# exported so the wrapper and the mock bob subprocess inherit it without a
# redundant inline env assignment at every call site (avoids SC2097/SC2098)
export TMPDIR_TEST
trap 'rm -rf "$TMPDIR_TEST"' EXIT

passed=0
failed=0
total=0

pass() {
    passed=$((passed + 1))
    total=$((total + 1))
    echo "  PASS: $1"
}

fail() {
    failed=$((failed + 1))
    total=$((total + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

# build a temporary validator so shipped and installed yaml use the vendored parser.
yaml_validator_source="$TMPDIR_TEST/yaml_validator.go"
yaml_validator_bin="$TMPDIR_TEST/yaml-validator"
cat > "$yaml_validator_source" << 'YAML_VALIDATOR_EOF'
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"

	"gopkg.in/yaml.v3"
)

type modeDocument struct {
	CustomModes []mode `yaml:"customModes"`
}

type mode struct {
	Slug               string   `yaml:"slug"`
	Name               string   `yaml:"name"`
	Description        string   `yaml:"description"`
	RoleDefinition     string   `yaml:"roleDefinition"`
	WhenToUse          string   `yaml:"whenToUse"`
	CustomInstructions string   `yaml:"customInstructions"`
	Groups             []interface{} `yaml:"groups"`
}

var ralphexGroups = map[string][]string{
	"ralphex-task":   {"read", "edit", "command", "browser"},
	"ralphex-review": {"read", "edit", "command", "browser"},
	"ralphex-plan":   {"read", "command", "browser"},
}

var requiredInstructions = map[string][]string{
	"ralphex-task": {
		"one task at a time",
		"Commit completed work",
		"<<<RALPHEX:ALL_TASKS_DONE>>>",
		"<<<RALPHEX:TASK_FAILED>>>",
	},
	"ralphex-review": {
		"sequentially",
		"verify every finding",
		"Fix every confirmed issue",
		"run the requested tests",
		"git commit",
		"<<<RALPHEX:REVIEW_DONE>>>",
		"<<<RALPHEX:TASK_FAILED>>>",
	},
	"ralphex-plan": {
		"Do not edit source files",
		"<<<RALPHEX:QUESTION>>>",
		"<<<RALPHEX:PLAN_DRAFT>>>",
		"<<<RALPHEX:PLAN_READY>>>",
	},
}

func invalid(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func validate(path string, strict bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		invalid("read %s: %v", path, err)
	}
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(strict)
	var document modeDocument
	if err := decoder.Decode(&document); err != nil {
		invalid("parse %s: %v", path, err)
	}
	var extra modeDocument
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			invalid("%s contains multiple YAML documents", path)
		}
		invalid("parse trailing content in %s: %v", path, err)
	}
	if len(document.CustomModes) == 0 {
		invalid("%s has no customModes sequence", path)
	}
	seenSlugs := make(map[string]bool, len(document.CustomModes))
	for _, current := range document.CustomModes {
		if strings.TrimSpace(current.Slug) == "" {
			invalid("%s contains a mode without a slug", path)
		}
		if seenSlugs[current.Slug] {
			invalid("%s contains duplicate slug %q", path, current.Slug)
		}
		seenSlugs[current.Slug] = true
		if !strict {
			continue
		}
		if strings.TrimSpace(current.Name) == "" ||
			strings.TrimSpace(current.Description) == "" ||
			strings.TrimSpace(current.RoleDefinition) == "" ||
			strings.TrimSpace(current.WhenToUse) == "" ||
			strings.TrimSpace(current.CustomInstructions) == "" {
			invalid("mode %s has an empty required field", current.Slug)
		}
		expectedGroups, known := ralphexGroups[current.Slug]
		if !known {
			invalid("shipped document contains unknown mode %q", current.Slug)
		}
		actualGroups := make([]string, 0, len(current.Groups))
		for _, group := range current.Groups {
			name, ok := group.(string)
			if !ok {
				invalid("mode %s has a non-scalar group", current.Slug)
			}
			actualGroups = append(actualGroups, name)
		}
		if !reflect.DeepEqual(actualGroups, expectedGroups) {
			invalid(
				"mode %s has groups %v, expected %v",
				current.Slug,
				actualGroups,
				expectedGroups,
			)
		}
		for _, requirement := range requiredInstructions[current.Slug] {
			if !strings.Contains(current.CustomInstructions, requirement) {
				invalid(
					"mode %s is missing custom instruction %q",
					current.Slug,
					requirement,
				)
			}
		}
	}
	if strict && len(document.CustomModes) != 1 {
		invalid(
			"%s strict mode document contains %d modes",
			path,
			len(document.CustomModes),
		)
	}
}

func main() {
	strict := false
	validated := 0
	for _, path := range os.Args[1:] {
		switch path {
		case "--strict":
			strict = true
		default:
			validate(path, strict)
			validated++
		}
	}
	if validated == 0 {
		invalid("no YAML documents supplied")
	}
}
YAML_VALIDATOR_EOF

if GOFLAGS=-mod=vendor go build -o "$yaml_validator_bin" "$yaml_validator_source"; then
    pass "vendored yaml.v3 validator compiled"
else
    fail "vendored yaml.v3 validator failed to compile"
    exit 1
fi

validate_yaml() {
    "$yaml_validator_bin" "$@"
}

assert_yaml_valid() {
    local label="$1"
    shift
    if validate_yaml "$@"; then
        pass "$label"
    else
        fail "$label"
    fi
}

# create a mock bob script that records its arguments and emits predefined stdout.
# MOCK_STDOUT_FILE: file containing text to emit on stdout
# MOCK_STDERR_FILE: file containing text to emit on stderr
# MOCK_EXIT_CODE:   exit code to return (default 0)
# bob_args:         space-joined arguments written to $TMPDIR_TEST/bob_args
# bob_args_lines:   one argument per line for exact token assertions
# bob_prompt:       stdin captured to $TMPDIR_TEST/bob_prompt (the prompt arrives
#                   via stdin now, not as a positional arg)
create_mock_bob() {
    local mock_script="$TMPDIR_TEST/bob"
    cat > "$mock_script" << 'MOCK_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TMPDIR_TEST/bob_args"
printf '%s\n' "$@" > "$TMPDIR_TEST/bob_args_lines"
# capture stdin (the prompt) separately for assertions
cat > "$TMPDIR_TEST/bob_prompt"

if [[ -n "${MOCK_STDOUT_FILE:-}" && -f "$MOCK_STDOUT_FILE" ]]; then
    cat "$MOCK_STDOUT_FILE"
fi
if [[ -n "${MOCK_STDERR_FILE:-}" && -f "$MOCK_STDERR_FILE" ]]; then
    cat "$MOCK_STDERR_FILE" >&2
fi
exit "${MOCK_EXIT_CODE:-0}"
MOCK_EOF
    chmod +x "$mock_script"
    echo "$mock_script"
}

create_mock_bob > /dev/null

# validate every shipped mode against bob's yaml shape and tool allow-list.
for mode in ralphex-task ralphex-review ralphex-plan; do
    assert_yaml_valid \
        "$mode mode parses with the vendored YAML validator" \
        --strict "$SCRIPT_DIR/modes/$mode.yaml"
done

# minimal valid bob event stream: one attempt_completion produces output.
cat > "$TMPDIR_TEST/minimal_events.txt" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"test\n"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"hello world\n"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"hello world\n"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

run_wrapper() {
    # helper: run wrapper with mock bob on PATH; args forwarded to wrapper
    MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" "$@"
}

echo "running bob-as-claude.sh tests"
echo ""

# ---------------------------------------------------------------------------
# test: bob launched with automatic task mode, stream-json output,
# --hide-intermediary-output, --yolo, --trust, and prompt delivered via stdin
# ---------------------------------------------------------------------------
echo "test: bob invocation flags"

rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
run_wrapper -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
for flag in "--chat-mode=ralphex-task" "--output-format=stream-json" "--hide-intermediary-output" "--yolo" "--trust"; do
    if echo "$recorded" | grep -q -- "$flag"; then
        pass "bob invoked with $flag"
    else
        fail "bob not invoked with $flag" "args: $recorded"
    fi
done

if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "test prompt" ]]; then
    pass "prompt delivered via stdin"
else
    fail "prompt not delivered via stdin" "got: $(cat "$TMPDIR_TEST/bob_prompt")"
fi

# the prompt must NOT appear on argv (avoids the per-arg length cap)
if echo "$recorded" | grep -q -- "test prompt"; then
    fail "prompt leaked onto argv" "args: $recorded"
else
    pass "prompt absent from argv"
fi

# ---------------------------------------------------------------------------
# test: --model flag forwarded to bob as -m
# ---------------------------------------------------------------------------
echo "test: --model forwarding"

rm -f "$TMPDIR_TEST/bob_args"
run_wrapper --model "anthropic/claude-x" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m anthropic/claude-x"; then
    pass "--model forwarded to bob as -m"
else
    fail "--model not forwarded as -m" "args: $recorded"
fi

# direct invocations may use the documented equals form.
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper --model=anthropic/claude-equals -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m anthropic/claude-equals"; then
    pass "--model=<value> forwarded to bob as -m"
else
    fail "--model=<value> not forwarded as -m" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: BOB_MODEL env used as -m when --model flag absent
# ---------------------------------------------------------------------------
echo "test: BOB_MODEL env"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m google/gemini-x"; then
    pass "BOB_MODEL used as -m when flag absent"
else
    fail "BOB_MODEL not used" "args: $recorded"
fi

# --model flag wins over BOB_MODEL
rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" --model "anthropic/claude-x" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m anthropic/claude-x" && ! echo "$recorded" | grep -q -- "google/gemini-x"; then
    pass "--model flag overrides BOB_MODEL"
else
    fail "--model did not override BOB_MODEL" "args: $recorded"
fi

# no -m when neither flag nor env set
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
# use word-boundary grep so "-m" does not match "--chat-mode" or "--max-coins"
if echo "$recorded" | grep -qE '(^| )-m( |$)'; then
    fail "-m present when no model configured" "args: $recorded"
else
    pass "-m omitted when no model configured"
fi

# ---------------------------------------------------------------------------
# test: --effort accepted but ignored (bob has no --effort; bob rejects it)
# ---------------------------------------------------------------------------
echo "test: --effort ignored"

rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper --effort high -p "test prompt" 2>&1 >/dev/null)
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--effort"; then
    fail "--effort leaked to bob argv" "args: $recorded"
else
    pass "--effort not forwarded to bob"
fi

if echo "$err_out" | grep -qi "bob has no --effort flag"; then
    pass "stderr note emitted for non-empty --effort"
else
    fail "stderr note missing for --effort" "stderr: $err_out"
fi

# the equals form is also accepted and stripped.
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper --effort=medium -p "test prompt" 2>&1 >/dev/null)
recorded=$(cat "$TMPDIR_TEST/bob_args")
if ! echo "$recorded" | grep -q -- "--effort" &&
    echo "$err_out" | grep -qi "bob has no --effort flag"; then
    pass "--effort=<value> accepted, reported, and stripped"
else
    fail "--effort=<value> handling is incorrect" "args: $recorded; stderr: $err_out"
fi

# empty --effort must NOT emit a note (avoids noise on default empty)
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" --effort "" -p "test prompt" 2>&1 >/dev/null)
if echo "$err_out" | grep -qi "bob has no --effort flag"; then
    fail "stderr note emitted for empty --effort" "stderr: $err_out"
else
    pass "no stderr note for empty --effort"
fi

# ---------------------------------------------------------------------------
# test: BOB_EXTRA_ARGS appended verbatim (word-split); no positional prompt
# ---------------------------------------------------------------------------
echo "test: BOB_EXTRA_ARGS passthrough"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS="--max-coins 100" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--max-coins 100"; then
    pass "BOB_EXTRA_ARGS appended to bob invocation"
else
    fail "BOB_EXTRA_ARGS not appended" "args: $recorded"
fi

# no positional prompt is appended after the extra args (prompt is on stdin)
if echo "$recorded" | grep -q -- "test prompt"; then
    fail "prompt leaked onto argv after BOB_EXTRA_ARGS" "args: $recorded"
else
    pass "no positional prompt appended after BOB_EXTRA_ARGS"
fi

# no stray args when BOB_EXTRA_ARGS unset
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--max-coins"; then
    fail "extra args present when BOB_EXTRA_ARGS unset" "args: $recorded"
else
    pass "no extra args when BOB_EXTRA_ARGS unset"
fi

# whitespace-only BOB_EXTRA_ARGS must not crash under set -u on bash 3.2:
# it yields an empty array after read, and expanding it would be an unbound-var error.
rm -f "$TMPDIR_TEST/bob_args"
if MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS="   " \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1; then
    pass "whitespace-only BOB_EXTRA_ARGS does not crash"
else
    fail "whitespace-only BOB_EXTRA_ARGS crashed the wrapper" "exit: $?"
fi

# BOB_EXTRA_ARGS word-splitting does NOT preserve quotes: a value like
# '--flag "a b"' is split into ['--flag', '"a', 'b"'] (three tokens), not
# ['--flag', 'a b'] (two tokens). This is a documented limitation.
# the shared mock records each argument on its own line so the split remains
# observable instead of being hidden by a space-joined argv string.
rm -f "$TMPDIR_TEST/bob_args_lines"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS='--flag "a b"' \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
# The args should be split into 3 lines: --flag, "a, b"
args_line_count=$(wc -l < "$TMPDIR_TEST/bob_args_lines" | tr -d ' ')
if [[ "$args_line_count" -ge 3 ]]; then
    pass "BOB_EXTRA_ARGS word-splits without preserving quotes ($args_line_count tokens)"
else
    fail "BOB_EXTRA_ARGS did not word-split as expected" "expected >=3 lines, got $args_line_count: $(cat "$TMPDIR_TEST/bob_args_lines")"
fi
# verify the three expected tokens are present
if grep -qx -- '--flag' "$TMPDIR_TEST/bob_args_lines" \
    && grep -qx -- '"a' "$TMPDIR_TEST/bob_args_lines" \
    && grep -qx -- 'b"' "$TMPDIR_TEST/bob_args_lines"; then
    pass "BOB_EXTRA_ARGS word-split produces expected tokens"
else
    fail "BOB_EXTRA_ARGS word-split tokens unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
fi

# ---------------------------------------------------------------------------
# test: BOB_CHAT_MODE accepts arbitrary custom slugs
# ---------------------------------------------------------------------------
echo "test: arbitrary BOB_CHAT_MODE override"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="my-custom-mode" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--chat-mode=my-custom-mode"; then
    pass "arbitrary BOB_CHAT_MODE slug forwarded unchanged"
else
    fail "BOB_CHAT_MODE not forwarded" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: BOB_VERBOSE validation — invalid value warns and defaults to 0
# ---------------------------------------------------------------------------
echo "test: invalid BOB_VERBOSE falls back to 0"

cat > "$TMPDIR_TEST/tool_events.jsonl" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"tool_use","timestamp":"t","tool_name":"read_file","tool_id":"tool-1","parameters":{"path":"foo"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"content"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-2","parameters":{"result":"done\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_events.jsonl" \
    BOB_VERBOSE="banana" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/verbose_err" >"$TMPDIR_TEST/verbose_out"
if grep -qi "BOB_VERBOSE must be 0 or 1" "$TMPDIR_TEST/verbose_err"; then
    pass "invalid BOB_VERBOSE prints warning"
else
    fail "no warning for invalid BOB_VERBOSE" "stderr: $(cat "$TMPDIR_TEST/verbose_err")"
fi
if grep -q "\[tool\]" "$TMPDIR_TEST/verbose_out"; then
    fail "tool events leaked with invalid BOB_VERBOSE (should default to 0)" "got: $(cat "$TMPDIR_TEST/verbose_out")"
else
    pass "invalid BOB_VERBOSE defaults to 0 (tool events suppressed)"
fi

# ---------------------------------------------------------------------------
# test: attempt_completion translation — parameters.result emitted as delta
# ---------------------------------------------------------------------------
echo "test: attempt_completion translation"

output=$(run_wrapper -p "test prompt" 2>/dev/null)

# select the first non-empty delta
text_line=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text != "")' | head -1)
if echo "$text_line" | jq -e '.delta.text == "hello world\n"' >/dev/null 2>&1; then
    pass "attempt_completion result emitted as content_block_delta with trailing newline"
else
    fail "attempt_completion result not translated correctly" "got: $output"
fi

# init/session header is skipped (emitted as empty keepalive, not leaked)
if echo "$output" | grep -q "\"session_id\":\"s\"" || echo "$output" | grep -q "\"model\":\"premium\""; then
    fail "init header leaked into output" "got: $output"
else
    pass "init header skipped (no leak)"
fi

# user message echo is skipped
if echo "$output" | grep -q "\"role\":\"user\""; then
    fail "user message echo leaked into output" "got: $output"
else
    pass "user message echo skipped"
fi

# ---------------------------------------------------------------------------
# test: result event translation — bob result -> Claude result (count = 2)
# ---------------------------------------------------------------------------
echo "test: terminal result event"

# the wrapper always emits a fallback result, so a single result event would pass even
# if result translation were broken. assert the COUNT: a stream with a result event yields
# 2 results (translated + fallback), a stream without yields 1.
result_count=$(echo "$output" | grep -c '"result"')
if [[ "$result_count" -eq 2 ]]; then
    pass "bob result event translated (2 total with fallback)"
else
    fail "unexpected result count" "expected 2, got $result_count: $output"
fi

# a stream with no result event yields exactly one (the fallback) result.
cat > "$TMPDIR_TEST/noresult_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"text only\n"}}
EOF
output_noterm=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/noresult_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
noterm_results=$(echo "$output_noterm" | grep -c '"result"')
if [[ "$noterm_results" -eq 1 ]]; then
    pass "no result event yields exactly one (fallback) result"
else
    fail "unexpected result count without result event" "expected 1, got $noterm_results: $output_noterm"
fi

# ---------------------------------------------------------------------------
# test: tool_result(status=error) always emitted even with BOB_VERBOSE=0
# ---------------------------------------------------------------------------
echo "test: tool_result error always emitted"

cat > "$TMPDIR_TEST/tool_error_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"bash","tool_id":"tool-1","parameters":{"cmd":"false"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","output":"command failed"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-2","parameters":{"result":"done\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "\[tool_error\] command failed"; then
    pass "tool_result error emitted even with BOB_VERBOSE=0"
else
    fail "tool_result error not emitted" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: tool_result(status=success) only with BOB_VERBOSE=1
# ---------------------------------------------------------------------------
echo "test: tool_result success verbose"

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

# With BOB_VERBOSE=1, the bash tool_use emits [tool] bash
if echo "$output" | grep -q "\[tool\] bash"; then
    pass "tool_use emitted as [tool] marker with BOB_VERBOSE=1"
else
    fail "tool_use [tool] marker missing with BOB_VERBOSE=1" "got: $output"
fi

# A success tool_result does not appear in this fixture (only error), but we
# can verify the verbose tool_use marker is present (covered above).

# ---------------------------------------------------------------------------
# test: tool events skipped by default (BOB_VERBOSE=0)
# ---------------------------------------------------------------------------
echo "test: tool events skipped by default"

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "\[tool\]"; then
    fail "tool [tool] markers leaked (BOB_VERBOSE=0)" "got: $output"
else
    pass "tool_use [tool] markers skipped (BOB_VERBOSE=0)"
fi

# suppressed events (init, user message, non-attempt_completion tool_use) emit
# empty keepalive deltas. This fixture has a bash tool_use (suppressed when
# BOB_VERBOSE=0) -> 1 keepalive. The error tool_result and attempt_completion
# emit non-empty text.
keepalives=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text == "")' | wc -l | tr -d ' ')
if [[ "$keepalives" -ge 1 ]]; then
    pass "suppressed events emit empty keepalive deltas (got $keepalives)"
else
    fail "expected >=1 keepalive delta for suppressed tool_use" "got $keepalives: $output"
fi

# ---------------------------------------------------------------------------
# test: invalid JSON lines do not abort translation
# ---------------------------------------------------------------------------
echo "test: invalid JSON tolerated"

cat > "$TMPDIR_TEST/garbage_events.jsonl" << 'EOF'
not json at all
123
"a bare json string"
[1,2,3]
{"type":"tool_use","tool_name":"attempt_completion","parameters":{"result":"after garbage\n"}}
{"type":"result","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/garbage_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "after garbage"; then
    pass "translation continues past invalid JSON lines"
else
    fail "invalid JSON aborted translation" "got: $output"
fi

# bare plaintext line (like bob's final-text echo) is also tolerated
cat > "$TMPDIR_TEST/plaintext_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"hello\n"}}
Hello
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plaintext_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q "hello"; then
    pass "bare plaintext line between tool_result and result is tolerated"
else
    fail "bare plaintext line broke translation" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: fallback result event — bob exits without result
# ---------------------------------------------------------------------------
echo "test: fallback result event"

cat > "$TMPDIR_TEST/noresult2_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"partial\n"}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/noresult2_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

last_line=$(echo "$output" | tail -1)
if echo "$last_line" | jq -e '.type == "result"' >/dev/null 2>&1; then
    pass "fallback result emitted when no result event"
else
    fail "no fallback result event" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: automatic phase selection and unchanged prompt delivery
# ---------------------------------------------------------------------------
echo "test: automatic phase selection"

assert_selected_mode() {
    local expected="$1"
    local test_prompt="$2"

    rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
    MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "$test_prompt" >/dev/null 2>&1

    if grep -q -- "--chat-mode=$expected" "$TMPDIR_TEST/bob_args"; then
        pass "prompt selected $expected"
    else
        fail "prompt did not select $expected" "args: $(cat "$TMPDIR_TEST/bob_args")"
    fi
    if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "$test_prompt" ]]; then
        pass "prompt delivered unchanged for $expected"
    else
        fail "prompt changed while selecting $expected" "got: $(cat "$TMPDIR_TEST/bob_prompt")"
    fi
}

assert_selected_mode "ralphex-task" "implement this task"
assert_selected_mode "ralphex-task" "finalize the completed work"
assert_selected_mode "ralphex-review" "## Step 2: Launch ALL 5 Review Agents IN PARALLEL"
assert_selected_mode "ralphex-review" "## Step 2: Launch Review Agents IN PARALLEL"
assert_selected_mode "ralphex-plan" $'<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'

# review markers take precedence over a complete plan signal set.
assert_selected_mode "ralphex-review" $'## Step 2: Launch Review Agents IN PARALLEL\n<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'

# markers inside either supported fence do not change the task fallback.
assert_selected_mode "ralphex-task" $'```\n## Step 2: Launch Review Agents IN PARALLEL\n<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>\n```'
assert_selected_mode "ralphex-task" $'~~~\nUse the Task tool to launch a general-purpose agent with this prompt:\n~~~'

# only a compatible fence delimiter closes a block; nested shorter and mixed
# delimiters stay inside the outer fence and cannot expose review markers.
assert_selected_mode "ralphex-task" $'````markdown\n```text\n## Step 2: Launch Review Agents IN PARALLEL\n```\n````'
assert_selected_mode "ralphex-task" $'```text\n~~~\nUse the Task tool to launch a general-purpose agent with this prompt:\n~~~\n```'

# an output completion signal alone is not a review start marker.
assert_selected_mode "ralphex-task" "please review <<<RALPHEX:REVIEW_DONE>>>"

# each plan signal is insufficient on its own, and every incomplete pair stays
# on the task fallback until the complete signal set is present.
assert_selected_mode "ralphex-task" "<<<RALPHEX:QUESTION>>>"
assert_selected_mode "ralphex-task" "<<<RALPHEX:PLAN_DRAFT>>>"
assert_selected_mode "ralphex-task" "<<<RALPHEX:PLAN_READY>>>"
assert_selected_mode "ralphex-task" $'<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>'
assert_selected_mode "ralphex-task" $'<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_READY>>>'
assert_selected_mode "ralphex-task" $'<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'

# review markers take precedence even when a plan marker set appears before or
# after them, while fenced examples remain ordinary task prompt content.
assert_selected_mode "ralphex-review" "Use the Task tool to launch a general-purpose agent with this prompt:"
assert_selected_mode "ralphex-review" "Use the Task tool with model=sonnet to launch a general-purpose agent with this prompt:"
assert_selected_mode "ralphex-review" $'<<<RALPHEX:QUESTION>>>\n## Step 2: Launch Review Agents IN PARALLEL\n<<<RALPHEX:PLAN_READY>>>'
assert_selected_mode "ralphex-task" $'  ```text\nUse the Task tool to launch a general-purpose agent with this prompt:\n```'
assert_selected_mode "ralphex-task" $'  ~~~\n<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>\n~~~'

# fence-like Markdown that cannot open a fenced block must not suppress later
# phase markers.
assert_selected_mode "ralphex-review" $'```literal```\n## Step 2: Launch Review Agents IN PARALLEL'
assert_selected_mode "ralphex-plan" $'    ```\n<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'

# detection resumes after either fence style closes.
assert_selected_mode "ralphex-review" $'```text\n## Step 2: Launch Review Agents IN PARALLEL\n```\nUse the Task tool to launch a general-purpose agent with this prompt:'
assert_selected_mode "ralphex-review" $'~~~\nUse the Task tool to launch a general-purpose agent with this prompt:\n~~~\n## Step 2: Launch Review Agents IN PARALLEL'

# marker-like phrases in ordinary prose are content, not review structure.
assert_selected_mode "ralphex-task" "Update the Launch Review Agents IN PARALLEL documentation"
assert_selected_mode "ralphex-task" "Explain how to Use the Task tool to launch an agent"

# a fenced plan marker cannot combine with two outside markers.
assert_selected_mode "ralphex-task" $'```\n<<<RALPHEX:QUESTION>>>\n```\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'

# exercise the exact embedded prompts through the stdin path used by ralphex.
assert_prompt_file_mode() {
    local expected="$1"
    local prompt_file="$2"
    local expected_prompt

    rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
    MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" < "$prompt_file" >/dev/null 2>&1
    if grep -q -- "--chat-mode=$expected" "$TMPDIR_TEST/bob_args"; then
        pass "$(basename "$prompt_file") selected $expected"
    else
        fail "$(basename "$prompt_file") did not select $expected" \
            "args: $(cat "$TMPDIR_TEST/bob_args")"
    fi
    expected_prompt=$(cat "$prompt_file")
    if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "$expected_prompt" ]]; then
        pass "$(basename "$prompt_file") passed unchanged through stdin"
    else
        fail "$(basename "$prompt_file") changed on stdin delivery"
    fi
}

prompt_dir="$REPO_ROOT/pkg/config/defaults/prompts"
assert_prompt_file_mode "ralphex-task" "$prompt_dir/task.txt"
assert_prompt_file_mode "ralphex-task" "$prompt_dir/finalize.txt"
assert_prompt_file_mode "ralphex-review" "$prompt_dir/review_first.txt"
assert_prompt_file_mode "ralphex-review" "$prompt_dir/review_second.txt"
assert_prompt_file_mode "ralphex-plan" "$prompt_dir/make_plan.txt"

# a user-controlled plan description may mention review marker phrases without
# overriding the complete plan signal set in the rendered prompt.
rendered_plan_prompt=$(< "$prompt_dir/make_plan.txt")
rendered_plan_prompt="${rendered_plan_prompt//\{\{PLAN_DESCRIPTION\}\}/Update the Launch Review Agents IN PARALLEL documentation}"
assert_selected_mode "ralphex-plan" "$rendered_plan_prompt"

# an explicit custom slug wins over every automatic marker.
rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
override_prompt=$'## Step 2: Launch ALL 5 Review Agents IN PARALLEL\n<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="user-defined-mode" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$override_prompt" >/dev/null 2>&1
if grep -q -- "--chat-mode=user-defined-mode" "$TMPDIR_TEST/bob_args"; then
    pass "explicit custom slug overrides automatic phase selection"
else
    fail "explicit custom slug was not forwarded" "args: $(cat "$TMPDIR_TEST/bob_args")"
fi
if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "$override_prompt" ]]; then
    pass "explicit override preserves original prompt"
else
    fail "explicit override changed original prompt" "got: $(cat "$TMPDIR_TEST/bob_prompt")"
fi

# built-in bob slugs remain valid explicit overrides alongside arbitrary custom
# slugs, and both preserve the prompt byte-for-byte.
rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
override_prompt=$'## Step 2: Launch Review Agents IN PARALLEL\n<<<RALPHEX:PLAN_DRAFT>>>'
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="code" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$override_prompt" >/dev/null 2>&1
if grep -q -- "--chat-mode=code" "$TMPDIR_TEST/bob_args"; then
    pass "built-in BOB_CHAT_MODE override is forwarded"
else
    fail "built-in BOB_CHAT_MODE override was not forwarded" "args: $(cat "$TMPDIR_TEST/bob_args")"
fi
if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "$override_prompt" ]]; then
    pass "built-in override preserves original prompt"
else
    fail "built-in override changed original prompt" "got: $(cat "$TMPDIR_TEST/bob_prompt")"
fi

# ---------------------------------------------------------------------------
# test: signal passthrough in attempt_completion result
# ---------------------------------------------------------------------------
echo "test: signal passthrough"

cat > "$TMPDIR_TEST/signal_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"<<<RALPHEX:ALL_TASKS_DONE>>>\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/signal_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "<<<RALPHEX:ALL_TASKS_DONE>>>"; then
    pass "ralphex signal preserved in translated output"
else
    fail "ralphex signal lost in translation" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: multi-line result split into separate content_block_delta blocks
# ---------------------------------------------------------------------------
echo "test: multi-line result split"

cat > "$TMPDIR_TEST/multiline_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"line one\nline two\nline three\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/multiline_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

line_one=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line one\n") | .delta.text' 2>/dev/null)
line_two=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line two\n") | .delta.text' 2>/dev/null)
line_three=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line three\n") | .delta.text' 2>/dev/null)
if [[ -n "$line_one" && -n "$line_two" && -n "$line_three" ]]; then
    pass "multi-line result split into separate line blocks"
else
    fail "multi-line result not split correctly" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr emitted as content_block_delta after stdout
# ---------------------------------------------------------------------------
echo "test: stderr emission"

cat > "$TMPDIR_TEST/stderr_text.txt" << 'EOF'
You've hit your limit
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_text.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

stderr_delta=$(echo "$output" | grep "hit your limit")
if echo "$stderr_delta" | jq -e '.type == "content_block_delta"' >/dev/null 2>&1; then
    pass "stderr emitted as content_block_delta for pattern detection"
else
    fail "stderr not emitted as content_block_delta" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr signal neutralization
# ---------------------------------------------------------------------------
echo "test: stderr signal token neutralized"

cat > "$TMPDIR_TEST/stderr_signal.txt" << 'EOF'
unexpected: <<<RALPHEX:ALL_TASKS_DONE>>> appeared in bob diagnostics
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_signal.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q -- "<<<RALPHEX:ALL_TASKS_DONE>>>"; then
    fail "stderr signal token leaked intact into output" "got: $output"
else
    pass "stderr signal token neutralized (no intact RALPHEX signal)"
fi

# the line is still emitted (just with the token broken), so error context survives
if echo "$output" | grep -q "appeared in bob diagnostics"; then
    pass "neutralized stderr line still emitted"
else
    fail "neutralized stderr line dropped entirely" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr rate-limit phrase preserved verbatim
# ---------------------------------------------------------------------------
echo "test: stderr rate-limit phrase preserved verbatim"

cat > "$TMPDIR_TEST/stderr_limit.txt" << 'EOF'
You've hit your usage limit
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_limit.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

limit_delta=$(echo "$output" | grep "hit your usage limit")
if echo "$limit_delta" | jq -e '.delta.text | contains("You'\''ve hit your usage limit")' >/dev/null 2>&1; then
    pass "rate-limit phrase emitted verbatim as content_block_delta"
else
    fail "rate-limit phrase not emitted verbatim" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: exit code preservation (success and failure)
# ---------------------------------------------------------------------------
echo "test: exit code preservation"

set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
ok_exit=$?
set -e
if [[ $ok_exit -eq 0 ]]; then
    pass "exit code 0 preserved on success"
else
    fail "expected exit 0 on success" "got: $ok_exit"
fi

set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_EXIT_CODE=7 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
fail_exit=$?
set -e
if [[ $fail_exit -eq 7 ]]; then
    pass "non-zero bob exit code preserved"
else
    fail "bob exit code not preserved" "got: $fail_exit"
fi

# ---------------------------------------------------------------------------
# test: realistic failure — bob dies with empty stdout, a limit phrase on
# stderr, and a non-zero exit. This is the exact scenario the stderr
# re-emission exists for.
# ---------------------------------------------------------------------------
echo "test: empty stdout with stderr limit and non-zero exit"

: > "$TMPDIR_TEST/empty_stdout.txt"
cat > "$TMPDIR_TEST/stderr_quota.txt" << 'EOF'
You've hit your usage limit
EOF

set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/empty_stdout.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_quota.txt" \
    MOCK_EXIT_CODE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
quota_exit=$?
set -e

if echo "$output" | grep "hit your usage limit" | jq -e '.type == "content_block_delta"' >/dev/null 2>&1; then
    pass "stderr limit phrase emitted despite empty stdout"
else
    fail "stderr limit phrase missing with empty stdout" "got: $output"
fi
if echo "$output" | tail -1 | jq -e '.type == "result"' >/dev/null 2>&1; then
    pass "fallback result emitted after stderr on failure"
else
    fail "no fallback result on failure path" "got: $output"
fi
if [[ $quota_exit -eq 1 ]]; then
    pass "non-zero exit preserved on failure path"
else
    fail "exit code not preserved on failure path" "got: $quota_exit"
fi

# ---------------------------------------------------------------------------
# test: large prompt (>128KB) delivered via stdin does not break
# ---------------------------------------------------------------------------
echo "test: large prompt (>128KB)"

# generate a 200KB prompt (larger than the 128KB per-arg cap on Linux).
# NOTE: -p cannot deliver this (the shell itself rejects a 200KB argv element),
# so we use the stdin pipe path — the primary path ralphex uses.
large_prompt=$(head -c 200000 /dev/zero | tr '\0' 'x')
rm -f "$TMPDIR_TEST/bob_prompt"
printf '%s' "$large_prompt" | MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" >/dev/null 2>&1
sent_size=$(wc -c < "$TMPDIR_TEST/bob_prompt" | tr -d ' ')
if [[ "$sent_size" -eq 200000 ]]; then
    pass "large prompt (200KB) delivered intact via stdin pipe"
else
    fail "large prompt truncated via stdin pipe" "expected 200000 bytes, got $sent_size"
fi

# also verify via a here-string (another stdin path)
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" <<< "$large_prompt" >/dev/null 2>&1
sent_size=$(wc -c < "$TMPDIR_TEST/bob_prompt" | tr -d ' ')
if [[ "$sent_size" -eq 200000 ]]; then
    pass "large prompt (200KB) delivered intact via here-string"
else
    fail "large prompt truncated via here-string" "expected 200000 bytes, got $sent_size"
fi

# ---------------------------------------------------------------------------
# test: bob/codex unknown-flag exit code handling.
# bob rejects unknown flags with exit 1 (e.g. `bob --effort high` exits 1).
# The wrapper must strip --effort so bob never sees it. We verify by checking
# that the wrapper does NOT pass --effort to bob (already tested above) and
# that a mock bob that would exit 1 on unknown flags is not triggered.
# ---------------------------------------------------------------------------
echo "test: bob unknown-flag exit code handling"

# This is implicitly covered by the --effort test above (bob never sees --effort).
# Here we verify the wrapper does not pass any ralphex-specific flags to bob.
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper --dangerously-skip-permissions --output-format stream-json --verbose --print -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
for ralphex_flag in "--dangerously-skip-permissions" "--verbose" "--print"; do
    if echo "$recorded" | grep -q -- "$ralphex_flag"; then
        fail "ralphex flag $ralphex_flag leaked to bob" "args: $recorded"
    else
        pass "ralphex flag $ralphex_flag not forwarded to bob"
    fi
done
# the wrapper's own output-format setting should replace any ralphex one.
if echo "$recorded" | grep -c -- "--output-format=stream-json" | grep -q "^1$"; then
    pass "exactly one --output-format=stream-json in bob args"
else
    fail "unexpected --output-format count" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: SIGTERM forwarded to bob child
# ---------------------------------------------------------------------------
echo "test: SIGTERM forwarded to bob child"

hang_bin="$TMPDIR_TEST/hang_bin"
mkdir -p "$hang_bin"
cat > "$hang_bin/bob" << 'HANG_EOF'
#!/usr/bin/env bash
cat > /dev/null  # consume the prompt
echo $$ > "$TMPDIR_TEST/hang_bob_pid"
exec sleep 30
HANG_EOF
chmod +x "$hang_bin/bob"

rm -f "$TMPDIR_TEST/hang_bob_pid"
PATH="$hang_bin:$PATH" bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1 &
wrapper_pid=$!

# wait for the mock bob to start (it records its PID once running)
for _ in $(seq 1 50); do
    [[ -f "$TMPDIR_TEST/hang_bob_pid" ]] && break
    sleep 0.1
done

kill -TERM "$wrapper_pid" 2>/dev/null || true

# the wrapper must exit promptly (well under the mock's 30s sleep)
for _ in $(seq 1 50); do
    kill -0 "$wrapper_pid" 2>/dev/null || break
    sleep 0.1
done

if kill -0 "$wrapper_pid" 2>/dev/null; then
    fail "wrapper did not exit promptly after SIGTERM"
    kill -9 "$wrapper_pid" 2>/dev/null || true
    term_exit=-1
else
    set +e
    wait "$wrapper_pid"
    term_exit=$?
    set -e
    pass "wrapper exits promptly on SIGTERM while bob is running"
fi

if [[ $term_exit -eq 143 ]]; then
    pass "wrapper exits 143 on SIGTERM"
else
    fail "unexpected exit code on SIGTERM" "expected 143, got: $term_exit"
fi

hang_pid=$(cat "$TMPDIR_TEST/hang_bob_pid" 2>/dev/null || echo "")
# bob may need a moment to die after the forwarded TERM
if [[ -n "$hang_pid" ]]; then
    for _ in $(seq 1 20); do
        kill -0 "$hang_pid" 2>/dev/null || break
        sleep 0.1
    done
fi
if [[ -n "$hang_pid" ]] && kill -0 "$hang_pid" 2>/dev/null; then
    fail "bob child still alive after wrapper received SIGTERM" "pid: $hang_pid"
    kill -9 "$hang_pid" 2>/dev/null || true
else
    pass "SIGTERM forwarded to bob child"
fi
rm -rf "$hang_bin"

# ---------------------------------------------------------------------------
# test: missing prompt exits with error
# ---------------------------------------------------------------------------
echo "test: missing prompt error"

set +e
PATH="$TMPDIR_TEST:$PATH" bash "$WRAPPER" </dev/null 2>"$TMPDIR_TEST/no_prompt_err"
no_prompt_exit=$?
set -e

if [[ $no_prompt_exit -ne 0 ]]; then
    pass "exits non-zero without prompt"
else
    fail "should exit non-zero without prompt" "got exit code 0"
fi

if grep -q "no prompt provided" "$TMPDIR_TEST/no_prompt_err"; then
    pass "error message mentions missing prompt"
else
    fail "no error about missing prompt" "stderr: $(cat "$TMPDIR_TEST/no_prompt_err")"
fi

# ---------------------------------------------------------------------------
# test: unknown flags ignored gracefully
# ---------------------------------------------------------------------------
echo "test: unknown flags ignored"

output=$(run_wrapper --dangerously-skip-permissions --output-format stream-json --verbose --print -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q '"content_block_delta"'; then
    pass "unknown flags ignored, output produced normally"
else
    fail "wrapper failed with unknown flags" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: bob not found exits with error
# ---------------------------------------------------------------------------
echo "test: bob not found"

set +e
no_bob_bin="$TMPDIR_TEST/no_bob_bin"
mkdir -p "$no_bob_bin"
for tool in jq bash mktemp mkfifo cat rm kill env awk; do
    tool_path=$(command -v "$tool" 2>/dev/null) && ln -sf "$tool_path" "$no_bob_bin/$tool"
done
PATH="$no_bob_bin" bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/no_bob_err"
no_bob_exit=$?
rm -r "$no_bob_bin"
set -e

if [[ $no_bob_exit -ne 0 ]]; then
    pass "exits non-zero when bob not found"
else
    fail "should exit non-zero when bob not found" "got exit code 0"
fi

if grep -q "bob is required" "$TMPDIR_TEST/no_bob_err"; then
    pass "error message mentions bob requirement"
else
    fail "no error about missing bob" "stderr: $(cat "$TMPDIR_TEST/no_bob_err")"
fi

# ---------------------------------------------------------------------------
# test: jq not found exits with error (jq guard precedes the bob guard)
# ---------------------------------------------------------------------------
echo "test: jq not found"

set +e
no_jq_bin="$TMPDIR_TEST/no_jq_bin"
mkdir -p "$no_jq_bin"
for tool in bash mktemp mkfifo cat rm kill env awk; do
    tool_path=$(command -v "$tool" 2>/dev/null) && ln -sf "$tool_path" "$no_jq_bin/$tool"
done
# include a bob so the failure is attributable to jq, not a missing bob
ln -sf "$TMPDIR_TEST/bob" "$no_jq_bin/bob"
PATH="$no_jq_bin" bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/no_jq_err"
no_jq_exit=$?
rm -r "$no_jq_bin"
set -e

if [[ $no_jq_exit -ne 0 ]]; then
    pass "exits non-zero when jq not found"
else
    fail "should exit non-zero when jq not found" "got exit code 0"
fi

if grep -q "jq is required" "$TMPDIR_TEST/no_jq_err"; then
    pass "error message mentions jq requirement"
else
    fail "no error about missing jq" "stderr: $(cat "$TMPDIR_TEST/no_jq_err")"
fi

# ---------------------------------------------------------------------------
# test: trailing newline edge case — result without trailing newline
# ---------------------------------------------------------------------------
echo "test: attempt_completion result without trailing newline"

cat > "$TMPDIR_TEST/no_trailing_newline.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"line one\nline two"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/no_trailing_newline.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

line_one=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line one\n") | .delta.text' 2>/dev/null)
line_two=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line two\n") | .delta.text' 2>/dev/null)
if [[ -n "$line_one" && -n "$line_two" ]]; then
    pass "result without trailing newline preserves last line"
else
    fail "last line lost when result lacks trailing newline" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: BOB_EXTRA_ARGS does not expand globs or command substitution
# ---------------------------------------------------------------------------
echo "test: BOB_EXTRA_ARGS literal passthrough (no glob expansion)"

# Create files that would match if the glob expanded.
touch "$TMPDIR_TEST/should_not_expand.txt"
rm -f "$TMPDIR_TEST/bob_args_lines"
(
    cd "$TMPDIR_TEST"
    export MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt"
    BOB_EXTRA_ARGS='--file *.txt' \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
)

if [[ -f "$TMPDIR_TEST/bob_args_lines" ]]; then
    # The wrapper uses quoted array expansion, so *.txt should remain literal.
    if grep -qx -- '\*.txt' "$TMPDIR_TEST/bob_args_lines" || grep -qx -- '*.txt' "$TMPDIR_TEST/bob_args_lines"; then
        pass "BOB_EXTRA_ARGS passes *.txt literally (no glob expansion)"
    else
        fail "BOB_EXTRA_ARGS glob expansion unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
    fi
else
    fail "BOB_EXTRA_ARGS literal test did not record args"
fi

# Command substitution inside BOB_EXTRA_ARGS should also stay literal.
rm -f "$TMPDIR_TEST/bob_args_lines"
(
    cd "$TMPDIR_TEST"
    export MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt"
    BOB_EXTRA_ARGS='--label $(echo pwned)' \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
)

if [[ -f "$TMPDIR_TEST/bob_args_lines" ]]; then
    # With quoted expansion, command substitution does NOT occur: the $, (, and
    # ) survive as literal characters. The wrapper word-splits BOB_EXTRA_ARGS on
    # whitespace (documented limitation: quotes/spaces are not preserved), so
    # '$(echo pwned)' becomes two argv tokens: '$(echo' and 'pwned)'. If command
    # substitution HAD occurred, we would see 'pwned' alone (no $ or parens).
    # Verify both literal tokens are present (no substitution) and that the
    # substituted form 'pwned' alone is NOT present.
    if grep -qx -- '$(echo' "$TMPDIR_TEST/bob_args_lines" \
        && grep -qx -- 'pwned)' "$TMPDIR_TEST/bob_args_lines" \
        && ! grep -qx -- 'pwned' "$TMPDIR_TEST/bob_args_lines"; then
        pass "BOB_EXTRA_ARGS passes \$(echo pwned) literally (no command substitution)"
    else
        fail "BOB_EXTRA_ARGS command substitution unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
    fi
else
    fail "BOB_EXTRA_ARGS command-substitution test did not record args"
fi

# ---------------------------------------------------------------------------
# test: custom-mode installer creates, merges, and fails safely
# ---------------------------------------------------------------------------
echo "test: custom-mode installer"

INSTALLER="$SCRIPT_DIR/install-modes.sh"
installer_home="$TMPDIR_TEST/home with spaces"
installer_target="$installer_home/.bob/settings/custom_modes.yaml"
rm -rf "$installer_home"

# an absent target is created at bob's active global path.
env -u BOB_CUSTOM_MODES_FILE HOME="$installer_home" bash "$INSTALLER" >/dev/null
if [[ -f "$installer_target" ]]; then
    pass "installer creates missing custom-mode document"
else
    fail "installer did not create missing custom-mode document"
fi
assert_yaml_valid \
    "installer-created document parses with the vendored YAML validator" \
    "$installer_target"
for slug in ralphex-task ralphex-review ralphex-plan; do
    slug_count=$(grep -c -- "^  - slug: $slug$" "$installer_target" || true)
    if [[ "$slug_count" -eq 1 ]]; then
        pass "installer adds $slug once"
    else
        fail "installer did not add $slug exactly once" "count: $slug_count"
    fi
done

# a user-owned mode and a user-owned ralphex slug are preserved during a merge.
merge_home="$TMPDIR_TEST/merge-home"
merge_target="$merge_home/.bob/settings/custom_modes.yaml"
mkdir -p "$(dirname "$merge_target")"
cat > "$merge_target" << 'EOF'
customModes:
  - slug: user-mode
    name: User Mode
    description: A user-owned mode.
    roleDefinition: You are a user-owned mode.
    whenToUse: Use for user-owned work.
    customInstructions: Follow the user's instructions.
    groups:
      - read
  - slug: ralphex-task
    name: User-Owned Task Mode
    description: A user-owned task mode.
    roleDefinition: You are a user-owned task mode.
    whenToUse: Use for user-owned task work.
    customInstructions: Follow the user's task instructions.
    groups:
      - read
EOF
HOME="$merge_home" BOB_CUSTOM_MODES_FILE= bash "$INSTALLER" >/dev/null
if grep -q -- "name: User Mode" "$merge_target" && grep -q -- "name: User-Owned Task Mode" "$merge_target"; then
    pass "installer preserves unrelated and existing ralphex modes"
else
    fail "installer overwrote user-owned modes" "document: $(cat "$merge_target")"
fi
assert_yaml_valid \
    "merged installer document parses and preserves user-owned schemas" \
    "$merge_target"
for slug in ralphex-task ralphex-review ralphex-plan; do
    slug_count=$(grep -c -- "^  - slug: $slug$" "$merge_target" || true)
    if [[ "$slug_count" -eq 1 ]]; then
        pass "merged document contains one $slug"
    else
        fail "merged document contains duplicate or missing $slug" "count: $slug_count"
    fi
done

# bob's documented restricted edit-group form and quoted scalars are preserved.
restricted_target="$TMPDIR_TEST/restricted/custom_modes.yaml"
mkdir -p "$(dirname "$restricted_target")"
cat > "$restricted_target" << 'EOF'
customModes:
  - slug: restricted-user-mode
    name: "Restricted User Mode"
    description: 'A user-owned restricted mode.'
    roleDefinition: "Edit only Markdown files."
    groups:
      - read
      - - edit
        - fileRegex: ".*\\.(md|mdx)$"
          description: "Markdown files only"
      - command  # bob documents inline comments on group entries
EOF
BOB_CUSTOM_MODES_FILE="$restricted_target" bash "$INSTALLER" >/dev/null
assert_yaml_valid "documented restricted edit group remains valid after install" \
    "$restricted_target"
if grep -q -- 'fileRegex: ".*\\\\.(md|mdx)$"' "$restricted_target" &&
    grep -q -- 'name: "Restricted User Mode"' "$restricted_target"; then
    pass "installer preserves quoted scalars and restricted edit groups"
else
    fail "installer changed a documented restricted edit group"
fi

# a second run is a byte-for-byte no-op.
cp "$merge_target" "$TMPDIR_TEST/merge-before-second-install"
HOME="$merge_home" BOB_CUSTOM_MODES_FILE= bash "$INSTALLER" >/dev/null
if cmp -s "$merge_target" "$TMPDIR_TEST/merge-before-second-install"; then
    pass "repeated installer run is idempotent"
else
    fail "repeated installer run changed the document"
fi

# a document with only some ralphex modes receives only the missing modes.
partial_home="$TMPDIR_TEST/partial-home"
partial_target="$partial_home/.bob/settings/custom_modes.yaml"
mkdir -p "$(dirname "$partial_target")"
cat > "$partial_target" << 'EOF'
customModes:
  - slug: ralphex-review
    name: Existing Review Override
    description: An existing review override.
    roleDefinition: You are an existing review override.
    whenToUse: Use for an existing review override.
    customInstructions: Preserve this user-owned review mode.
    groups:
      - read
EOF
HOME="$partial_home" BOB_CUSTOM_MODES_FILE= bash "$INSTALLER" >/dev/null
assert_yaml_valid \
    "partially installed document parses after adding missing modes" \
    "$partial_target"
for slug in ralphex-task ralphex-review ralphex-plan; do
    slug_count=$(grep -c -- "^  - slug: $slug$" "$partial_target" || true)
    if [[ "$slug_count" -eq 1 ]]; then
        pass "partial installation contains one $slug"
    else
        fail "partial installation contains duplicate or missing $slug" "count: $slug_count"
    fi
done
if grep -q -- "name: Existing Review Override" "$partial_target"; then
    pass "partial installation preserves existing ralphex slug"
else
    fail "partial installation replaced existing ralphex slug"
fi

# slug-shaped text inside a block scalar is not an installed mode field.
block_text_target="$TMPDIR_TEST/block-text/custom_modes.yaml"
mkdir -p "$(dirname "$block_text_target")"
cat > "$block_text_target" << 'EOF'
customModes:
  - slug: user-mode
    name: User Mode
    customInstructions: |
      Example configuration:
      slug: ralphex-task
    groups:
      - read
EOF
BOB_CUSTOM_MODES_FILE="$block_text_target" bash "$INSTALLER" >/dev/null
assert_yaml_valid "block-scalar slug example remains valid after install" \
    "$block_text_target"
if [[ "$(grep -c -- '^  - slug: ralphex-task$' "$block_text_target" || true)" -eq 1 ]]; then
    pass "block-scalar slug text does not suppress mode installation"
else
    fail "block-scalar slug text was mistaken for an installed mode"
fi

# malformed input must fail before replacing the target.
bad_home="$TMPDIR_TEST/bad-home"
bad_target="$bad_home/.bob/settings/custom_modes.yaml"
mkdir -p "$(dirname "$bad_target")"
printf '%s\n' 'this is not a safe customModes document' > "$bad_target"
cp "$bad_target" "$TMPDIR_TEST/bad-before-install"
set +e
HOME="$bad_home" BOB_CUSTOM_MODES_FILE= bash "$INSTALLER" >/dev/null 2>"$TMPDIR_TEST/installer-error"
installer_exit=$?
set -e
if [[ $installer_exit -ne 0 ]]; then
    pass "installer rejects unsafe existing document"
else
    fail "installer accepted unsafe existing document"
fi
if cmp -s "$bad_target" "$TMPDIR_TEST/bad-before-install"; then
    pass "unsafe installer merge leaves target unchanged"
else
    fail "unsafe installer merge changed target"
fi

# a syntactically malformed nested value must also be rejected unchanged.
malformed_target="$TMPDIR_TEST/malformed/custom_modes.yaml"
mkdir -p "$(dirname "$malformed_target")"
cat > "$malformed_target" << 'EOF'
customModes:
  - slug: malformed-mode
    name: Malformed Mode
    groups: [
EOF
cp "$malformed_target" "$TMPDIR_TEST/malformed-before-install"
set +e
BOB_CUSTOM_MODES_FILE="$malformed_target" bash "$INSTALLER" \
    >/dev/null 2>"$TMPDIR_TEST/malformed-installer-error"
malformed_exit=$?
set -e
if [[ $malformed_exit -ne 0 ]] &&
    cmp -s "$malformed_target" "$TMPDIR_TEST/malformed-before-install"; then
    pass "installer rejects malformed nested yaml without replacing it"
else
    fail "installer changed or accepted malformed nested yaml"
fi

# an unterminated quoted scalar is another shape the previous indentation-only
# check accepted even though a yaml parser rejects it.
quoted_target="$TMPDIR_TEST/quoted-malformed/custom_modes.yaml"
mkdir -p "$(dirname "$quoted_target")"
cat > "$quoted_target" << 'EOF'
customModes:
  - slug: quoted-malformed
    name: "unterminated
    groups:
      - read
EOF
cp "$quoted_target" "$TMPDIR_TEST/quoted-before-install"
set +e
BOB_CUSTOM_MODES_FILE="$quoted_target" bash "$INSTALLER" >/dev/null 2>&1
quoted_exit=$?
set -e
if [[ $quoted_exit -ne 0 ]] &&
    cmp -s "$quoted_target" "$TMPDIR_TEST/quoted-before-install"; then
    pass "installer rejects an unterminated quoted scalar unchanged"
else
    fail "installer changed or accepted an unterminated quoted scalar"
fi

# a comment-looking line inside a block scalar is content and establishes its
# indentation; a later deindent that remains under the field is malformed yaml.
block_comment_target="$TMPDIR_TEST/block-comment-malformed/custom_modes.yaml"
mkdir -p "$(dirname "$block_comment_target")"
cat > "$block_comment_target" << 'EOF'
customModes:
  - slug: block-comment-malformed
    customInstructions: |
        # literal scalar content
      invalid deindent
    groups:
      - read
EOF
cp "$block_comment_target" "$TMPDIR_TEST/block-comment-before-install"
set +e
BOB_CUSTOM_MODES_FILE="$block_comment_target" bash "$INSTALLER" >/dev/null 2>&1
block_comment_exit=$?
set -e
if [[ $block_comment_exit -ne 0 ]] &&
    cmp -s "$block_comment_target" "$TMPDIR_TEST/block-comment-before-install"; then
    pass "installer rejects malformed block indentation after literal hash content"
else
    fail "installer changed or accepted malformed block indentation after literal hash content"
fi

# malformed block-scalar indicators must fail before replacing the target.
for invalid_indicator in '|foo' '>foo'; do
    indicator_name="${invalid_indicator:0:1}"
    indicator_target="$TMPDIR_TEST/block-indicator-$indicator_name/custom_modes.yaml"
    mkdir -p "$(dirname "$indicator_target")"
    cat > "$indicator_target" << EOF
customModes:
  - slug: malformed-block
    name: Malformed Block
    roleDefinition: $invalid_indicator
    groups:
      - read
EOF
    indicator_before="$indicator_target.before"
    cp "$indicator_target" "$indicator_before"
    set +e
    BOB_CUSTOM_MODES_FILE="$indicator_target" bash "$INSTALLER" >/dev/null 2>&1
    indicator_exit=$?
    set -e
    if [[ $indicator_exit -ne 0 ]] && cmp -s "$indicator_target" "$indicator_before"; then
        pass "installer rejects malformed $invalid_indicator block indicator unchanged"
    else
        fail "installer changed or accepted malformed $invalid_indicator block indicator"
    fi
done

# an explicit override path may contain spaces and bypasses the global target.
override_target="$TMPDIR_TEST/override path/custom modes.yaml"
BOB_CUSTOM_MODES_FILE="$override_target" bash "$INSTALLER" >/dev/null
if [[ -f "$override_target" ]]; then
    pass "BOB_CUSTOM_MODES_FILE selects a path containing spaces"
else
    fail "BOB_CUSTOM_MODES_FILE override was not created"
fi
assert_yaml_valid "override installation parses as yaml" "$override_target"

# bob migrates a legacy global file on startup, so merge it when no canonical
# settings file exists instead of hiding its user-owned modes.
legacy_home="$TMPDIR_TEST/legacy-home"
legacy_target="$legacy_home/.bob/custom_modes.yaml"
mkdir -p "$(dirname "$legacy_target")"
cat > "$legacy_target" << 'EOF'
customModes:
  - slug: legacy-user-mode
    name: Legacy User Mode
    roleDefinition: Preserve the legacy user mode.
    groups:
      - read
EOF
HOME="$legacy_home" BOB_CUSTOM_MODES_FILE= bash "$INSTALLER" >/dev/null
if grep -q -- "slug: legacy-user-mode" "$legacy_target" &&
    grep -q -- "slug: ralphex-plan" "$legacy_target" &&
    [[ ! -e "$legacy_home/.bob/settings/custom_modes.yaml" ]]; then
    pass "installer preserves bob's legacy migration source"
else
    fail "installer hid or replaced the legacy global mode document"
fi
assert_yaml_valid "legacy installation remains valid yaml" "$legacy_target"

# an explicit empty sequence is converted before the shipped modes are added.
empty_target="$TMPDIR_TEST/empty-sequence/custom_modes.yaml"
mkdir -p "$(dirname "$empty_target")"
printf '%s\n' 'customModes: []' > "$empty_target"
BOB_CUSTOM_MODES_FILE="$empty_target" bash "$INSTALLER" >/dev/null
assert_yaml_valid "customModes empty sequence installs valid modes" "$empty_target"
if ! grep -q -- 'customModes: \[\]' "$empty_target"; then
    pass "empty customModes sequence converted to block form"
else
    fail "empty customModes sequence was not converted"
fi

# bob also accepts an empty null-valued customModes key; appending the shipped
# sequence turns it into the normal block form.
empty_null_target="$TMPDIR_TEST/empty-null/custom_modes.yaml"
mkdir -p "$(dirname "$empty_null_target")"
printf '%s\n' 'customModes: # initially empty' > "$empty_null_target"
BOB_CUSTOM_MODES_FILE="$empty_null_target" bash "$INSTALLER" >/dev/null
assert_yaml_valid "empty customModes key installs valid modes" "$empty_null_target"

# alternate valid indentation and a non-leading slug stay valid after append.
indented_target="$TMPDIR_TEST/four-space/custom_modes.yaml"
mkdir -p "$(dirname "$indented_target")"
cat > "$indented_target" << 'EOF'
customModes:
    - name: Four Space Mode
      slug: four-space-mode
      roleDefinition: Preserve four-space sequence indentation.
      groups:
        - read
EOF
BOB_CUSTOM_MODES_FILE="$indented_target" bash "$INSTALLER" >/dev/null
assert_yaml_valid "four-space-indented installation remains valid yaml" \
    "$indented_target"
if grep -q -- '^    - slug: ralphex-task$' "$indented_target"; then
    pass "installer matches existing sequence indentation"
else
    fail "installer appended modes with the wrong indentation"
fi

# defensive target checks must fail before following or replacing special files.
sentinel="$TMPDIR_TEST/symlink-sentinel"
symlink_target="$TMPDIR_TEST/symlink-target"
printf '%s\n' 'sentinel content' > "$sentinel"
ln -s "$sentinel" "$symlink_target"
set +e
BOB_CUSTOM_MODES_FILE="$symlink_target" bash "$INSTALLER" >/dev/null 2>&1
symlink_exit=$?
set -e
if [[ $symlink_exit -ne 0 ]] &&
    [[ "$(cat "$sentinel")" == "sentinel content" ]]; then
    pass "installer refuses a symlink without changing its target"
else
    fail "installer followed or accepted a symlink target"
fi

directory_target="$TMPDIR_TEST/non-regular-directory"
mkdir -p "$directory_target"
set +e
BOB_CUSTOM_MODES_FILE="$directory_target" bash "$INSTALLER" >/dev/null 2>&1
directory_exit=$?
set -e
if [[ $directory_exit -ne 0 && -d "$directory_target" ]]; then
    pass "installer refuses a directory target"
else
    fail "installer accepted or replaced a directory target"
fi

fifo_target="$TMPDIR_TEST/non-regular-fifo"
mkfifo "$fifo_target"
set +e
BOB_CUSTOM_MODES_FILE="$fifo_target" bash "$INSTALLER" >/dev/null 2>&1
fifo_exit=$?
set -e
if [[ $fifo_exit -ne 0 && -p "$fifo_target" ]]; then
    pass "installer refuses a fifo target"
else
    fail "installer accepted or replaced a fifo target"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo ""
echo "results: $passed passed, $failed failed, $total total"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
