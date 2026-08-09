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
unset BOB_CUSTOM_MODES_FILE BOB_SETTINGS_FILE
unset MOCK_STDOUT_FILE MOCK_STDERR_FILE MOCK_EXIT_CODE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$SCRIPT_DIR/bob-as-claude.sh"
TMPDIR_TEST=$(mktemp -d)
# exported so the wrapper and the mock bob subprocess inherit it without a
# redundant inline env assignment at every call site (avoids SC2097/SC2098)
export TMPDIR_TEST

passed=0
failed=0
total=0
# `set -e` aborts the suite on the first unguarded non-zero command, which without
# this looks identical to a clean run that printed no summary. Report how far it got
# so the failing region is findable.
suite_completed=0
cleanup() {
    local status=$?
    if [[ $suite_completed -eq 0 ]]; then
        echo "" >&2
        echo "ABORTED: suite exited early with status $status after $total assertions" \
             "($passed passed, $failed failed)" >&2
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

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
	"slices"
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
	"ralphex-task":   {"read", "edit", "execute"},
	"ralphex-review": {"read", "edit", "execute", "subagent"},
	"ralphex-plan":   {"read", "edit", "execute"},
}

// the only group names bob v2 recognizes, per its bundled mode-schema docs.
// an invalid name silently grants nothing, so it must fail the suite loudly.
var validGroupNames = map[string]bool{
	"read":     true,
	"edit":     true,
	"execute":  true,
	"mcp":      true,
	"skill":    true,
	"todo":     true,
	"subagent": true,
	"mode":     true,
}

var requiredInstructions = map[string][]string{
	"ralphex-task": {
		"one task at a time",
		"Commit completed work",
		"<<<RALPHEX:ALL_TASKS_DONE>>>",
		"<<<RALPHEX:TASK_FAILED>>>",
	},
	"ralphex-review": {
		"spawn_subagent",
		"single turn",
		"in parallel",
		"Consolidate the subagent findings",
		"temporary files",
		"verify every finding",
		"Fix every confirmed issue",
		"run the requested tests",
		"git commit",
		"<<<RALPHEX:REVIEW_DONE>>>",
		"<<<RALPHEX:TASK_FAILED>>>",
	},
	"ralphex-plan": {
		"Do not edit source files",
		"use the edit tool to write only the requested plan file under docs/plans",
		"ordinary assistant text",
		"ralphex alone owns that log",
		"<<<RALPHEX:QUESTION>>>",
		"<<<RALPHEX:PLAN_DRAFT>>>",
		"<<<RALPHEX:PLAN_READY>>>",
	},
}

// v1 contracts that must not survive anywhere in the shipped modes.
var forbiddenInstructions = map[string][]string{
	"ralphex-task":   {"attempt_completion"},
	"ralphex-plan":   {"attempt_completion"},
	"ralphex-review": {"attempt_completion", "Never launch", "sequentially"},
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
			if !validGroupNames[name] {
				invalid(
					"mode %s declares group %q, which bob v2 does not recognize",
					current.Slug,
					name,
				)
			}
			actualGroups = append(actualGroups, name)
		}
		if current.Slug == "ralphex-review" && !slices.Contains(actualGroups, "subagent") {
			invalid("mode %s must grant the subagent group", current.Slug)
		}
		// the exact-match check below also rejects duplicates, since every expected
		// list is unique — no separate duplicate scan is needed.
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
		for _, banned := range forbiddenInstructions[current.Slug] {
			if strings.Contains(current.CustomInstructions, banned) {
				invalid(
					"mode %s still carries the v1 instruction %q",
					current.Slug,
					banned,
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

# building the validator is test setup, not an assertion about the wrapper, so a
# failure aborts rather than counting toward the results.
if ! GOFLAGS=-mod=vendor go build -o "$yaml_validator_bin" "$yaml_validator_source"; then
    echo "error: vendored yaml.v3 validator failed to compile" >&2
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

# the group and instruction assertions are only meaningful if they can fail, so
# every negative shape is exercised against a mutated copy of a shipped mode.
assert_yaml_invalid() {
    local label="$1"
    local expected="$2"
    shift 2
    local output
    if output=$(validate_yaml "$@" 2>&1); then
        fail "$label" "validator accepted the mutated document"
    elif [[ "$output" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label" "unexpected diagnostic: $output"
    fi
}

# create a mock bob script that records its arguments and emits predefined stdout.
# MOCK_STDOUT_FILE: file containing text to emit on stdout
# MOCK_STDERR_FILE: file containing text to emit on stderr
# MOCK_EXIT_CODE:   exit code to return (default 0)
# bob_args:         space-joined arguments written to $TMPDIR_TEST/bob_args
# bob_args_lines:   one argument per line for exact token assertions
# bob_path:         the PATH bob was launched with, for guard-shim assertions
# bob_prompt:       stdin captured to $TMPDIR_TEST/bob_prompt (the prompt arrives
#                   via stdin now, not as a positional arg)
create_mock_bob() {
    local mock_script="$TMPDIR_TEST/bob"
    cat > "$mock_script" << 'MOCK_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TMPDIR_TEST/bob_args"
printf '%s\n' "$@" > "$TMPDIR_TEST/bob_args_lines"
printf '%s\n' "$PATH" > "$TMPDIR_TEST/bob_path"
# capture stdin (the prompt) separately for assertions
cat > "$TMPDIR_TEST/bob_prompt"

if [[ "${MOCK_STDERR_FIRST:-0}" == "1" && -n "${MOCK_STDERR_FILE:-}" && -f "$MOCK_STDERR_FILE" ]]; then
    cat "$MOCK_STDERR_FILE" >&2
    sleep "${MOCK_DELAY_AFTER_STDERR:-0}"
fi
if [[ -n "${MOCK_STDOUT_FILE:-}" && -f "$MOCK_STDOUT_FILE" ]]; then
    cat "$MOCK_STDOUT_FILE"
fi
if [[ "${MOCK_STDERR_FIRST:-0}" != "1" && -n "${MOCK_STDERR_FILE:-}" && -f "$MOCK_STDERR_FILE" ]]; then
    cat "$MOCK_STDERR_FILE" >&2
fi
exit "${MOCK_EXIT_CODE:-0}"
MOCK_EOF
    chmod +x "$mock_script"
    echo "$mock_script"
}

create_mock_bob > /dev/null

# validate every shipped mode against bob's yaml shape, its v2 group allow-list,
# and its v2 instruction contract. the glob (rather than a fixed slug list) makes
# a newly added mode file fail until the validator knows about it.
shipped_mode_count=0
for mode_path in "$SCRIPT_DIR"/modes/*.yaml; do
    shipped_mode_count=$((shipped_mode_count + 1))
    assert_yaml_valid \
        "$(basename "$mode_path" .yaml) mode parses with the vendored YAML validator" \
        --strict "$mode_path"
done
if [[ "$shipped_mode_count" -eq 3 ]]; then
    pass "all three shipped mode files were validated"
else
    fail "unexpected shipped mode file count" "count: $shipped_mode_count"
fi

# the group allow-list is enforced by the YAML validator above (validGroupNames),
# which parses the document instead of pattern-matching indentation. A second awk
# scan here would fail open on any re-indentation, so it is deliberately absent;
# the mutant below proves the validator's check can fail.

mutant_dir="$TMPDIR_TEST/mode-mutants"
mkdir -p "$mutant_dir"

# an invalid group name silently grants nothing in bob, so it must be rejected.
sed 's/^      - execute$/      - command/' \
    "$SCRIPT_DIR/modes/ralphex-task.yaml" > "$mutant_dir/invalid-group.yaml"
assert_yaml_invalid \
    "validator rejects a v1 group name" \
    "bob v2 does not recognize" \
    --strict "$mutant_dir/invalid-group.yaml"

# the review mode cannot spawn native subagents without the subagent group.
grep -v '^      - subagent$' "$SCRIPT_DIR/modes/ralphex-review.yaml" \
    > "$mutant_dir/no-subagent.yaml"
assert_yaml_invalid \
    "validator rejects a review mode without the subagent group" \
    "must grant the subagent group" \
    --strict "$mutant_dir/no-subagent.yaml"

# bob drops a whole mode document that repeats a group entry. The exact-match check
# reports it as a group-set mismatch, since no expected list contains duplicates.
sed 's/^      - edit$/      - read/' \
    "$SCRIPT_DIR/modes/ralphex-task.yaml" > "$mutant_dir/duplicate-group.yaml"
assert_yaml_invalid \
    "validator rejects a duplicate group entry" \
    "expected" \
    --strict "$mutant_dir/duplicate-group.yaml"

# the required-instruction contract must be able to fail: renaming the tool the review
# mode is built around leaves valid YAML and valid groups, so only this check catches it.
sed 's/spawn_subagent/spawn_agent/g' \
    "$SCRIPT_DIR/modes/ralphex-review.yaml" > "$mutant_dir/renamed-subagent-tool.yaml"
assert_yaml_invalid \
    "validator rejects a mode missing a required instruction" \
    "missing custom instruction" \
    --strict "$mutant_dir/renamed-subagent-tool.yaml"

# v2 removed attempt_completion, so no mode may still instruct bob to call it.
sed 's/Work on one task at a time/Call attempt_completion when done. Work on one task at a time/' \
    "$SCRIPT_DIR/modes/ralphex-task.yaml" > "$mutant_dir/attempt-completion.yaml"
assert_yaml_invalid \
    "validator rejects a surviving attempt_completion instruction" \
    "v1 instruction" \
    --strict "$mutant_dir/attempt-completion.yaml"

# minimal valid bob v2 event stream: assistant message text produces the output.
# v2 has no attempt_completion tool, so every phase reads the assistant messages.
cat > "$TMPDIR_TEST/minimal_events.txt" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"test\n"}
{"type":"message","timestamp":"t","role":"assistant","content":"hello world\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":1,"cost":0}}
EOF

cat > "$TMPDIR_TEST/plan_ready_events.txt" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"test\n"}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_READY>>>","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":1,"cost":0}}
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
# test: bob v2 launched as `run -f stream-json --mode=<slug> --trust` with the
# prompt on stdin, and with no removed v1 flag
# ---------------------------------------------------------------------------
echo "test: bob invocation flags"

rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
run_wrapper -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
# the v2 invocation is fixed and ordered: the subcommand comes first and the
# whole prefix is asserted at once so a stray or reordered token is caught.
if [[ "$recorded" == "run -f stream-json --mode=ralphex-task --trust" ]]; then
    pass "bob invoked as run -f stream-json --mode=ralphex-task --trust"
else
    fail "unexpected v2 bob invocation" "args: $recorded"
fi
if [[ "$(head -1 "$TMPDIR_TEST/bob_args_lines")" == "run" ]]; then
    pass "run subcommand is the first bob argument"
else
    fail "run subcommand missing or not first" "args: $recorded"
fi
for token in "-f" "stream-json" "--mode=ralphex-task" "--trust"; do
    if grep -qxF -- "$token" "$TMPDIR_TEST/bob_args_lines"; then
        pass "bob invoked with $token"
    else
        fail "bob not invoked with $token" "args: $recorded"
    fi
done

# every flag bob v2 removed (or rejects on `run`) must never be passed. exact
# token matching keeps "-m" from matching "--mode=" and "--max-turns".
for removed in "--yolo" "--auto-approve" "--hide-intermediary-output" "--disable-subagents" "-m"; do
    if grep -qxF -- "$removed" "$TMPDIR_TEST/bob_args_lines"; then
        fail "removed v1 flag $removed passed to bob v2" "args: $recorded"
    else
        pass "removed v1 flag $removed not passed to bob v2"
    fi
done
for removed_prefix in "--output-format" "--chat-mode" "--model"; do
    if grep -qF -- "$removed_prefix" "$TMPDIR_TEST/bob_args_lines"; then
        fail "removed v1 flag $removed_prefix passed to bob v2" "args: $recorded"
    else
        pass "removed v1 flag $removed_prefix not passed to bob v2"
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

# bob v2 blocks nested bob natively through its own BOB_SESSION check, so the
# wrapper ships no guard shims. The PATH assertion for that lives with the
# guard-shim removal tests.

# ---------------------------------------------------------------------------
# test: no guard-shim directory is prepended to PATH for ralphex-review
#
# v1 wrote a directory of `bob`/`claude`/`codex` stubs that exited 64 and
# prepended it to PATH. bob v2 blocks nested bob itself through BOB_SESSION,
# so the shim is gone and bob must inherit the caller's PATH verbatim.
# ---------------------------------------------------------------------------
echo "test: guard-shim removal"

review_prompt="## Step 2: Launch ALL 5 Review Agents IN PARALLEL"
expected_path="$TMPDIR_TEST:$PATH"

rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_path"
run_wrapper -p "$review_prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if [[ "$recorded" == *"--mode=ralphex-review"* ]]; then
    pass "review prompt selects ralphex-review for the guard-shim assertion"
else
    fail "review prompt did not select ralphex-review" "args: $recorded"
fi

# full-string equality already proves nothing was inserted anywhere in PATH, so no
# separate first-entry check is needed. A source-text ban on the words "guard"/"shim"
# is not asserted either: it would fail on an explanatory comment while a shim built
# under a different name would pass.
recorded_path=$(cat "$TMPDIR_TEST/bob_path")
if [[ "$recorded_path" == "$expected_path" ]]; then
    pass "no guard-shim directory prepended to PATH for ralphex-review"
else
    fail "PATH altered for ralphex-review" "got: $recorded_path"
fi

# ---------------------------------------------------------------------------
# test: model selection is accepted, reported once, and never forwarded
#
# bob v2 stable removed model selection (gated behind BOB_USE_MODEL_ENV plus a
# dev gateway key), so --model / --model= / BOB_MODEL are swallowed with a note.
# ---------------------------------------------------------------------------
echo "test: model note"

assert_model_ignored() {
    local label="$1"
    local value="$2"
    local err_out="$3"
    local args="$4"

    if echo "$args" | grep -qE '(^| )-m( |$)'; then
        fail "$label: -m forwarded to bob v2" "args: $args"
    elif echo "$args" | grep -qF -- "$value"; then
        fail "$label: model value leaked to bob argv" "args: $args"
    else
        pass "$label: no model argument forwarded to bob"
    fi

    local notes
    notes=$(echo "$err_out" | grep -ci "bob v2 stable has no model selection" || true)
    if [[ "$notes" == "1" ]]; then
        pass "$label: one stderr note emitted"
    else
        fail "$label: expected exactly one stderr note, got $notes" "stderr: $err_out"
    fi

    if echo "$err_out" | grep -qF -- "$value"; then
        pass "$label: stderr note names the ignored value"
    else
        fail "$label: stderr note omits the ignored value" "stderr: $err_out"
    fi
}

rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper --model "anthropic/claude-x" -p "test prompt" 2>&1 >/dev/null)
assert_model_ignored "--model flag" "anthropic/claude-x" \
    "$err_out" "$(cat "$TMPDIR_TEST/bob_args")"

# direct invocations may use the documented equals form.
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper --model=anthropic/claude-equals -p "test prompt" 2>&1 >/dev/null)
assert_model_ignored "--model=<value>" "anthropic/claude-equals" \
    "$err_out" "$(cat "$TMPDIR_TEST/bob_args")"

rm -f "$TMPDIR_TEST/bob_args"
err_out=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>&1 >/dev/null)
assert_model_ignored "BOB_MODEL env" "google/gemini-x" \
    "$err_out" "$(cat "$TMPDIR_TEST/bob_args")"

# the flag still wins over the env var, and only its value is reported.
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" --model "anthropic/claude-x" -p "test prompt" 2>&1 >/dev/null)
recorded=$(cat "$TMPDIR_TEST/bob_args")
assert_model_ignored "--model over BOB_MODEL" "anthropic/claude-x" \
    "$err_out" "$recorded"
if echo "$err_out$recorded" | grep -qF -- "google/gemini-x"; then
    fail "BOB_MODEL reported or forwarded when --model is set" "stderr: $err_out; args: $recorded"
else
    pass "--model over BOB_MODEL: env value neither reported nor forwarded"
fi

# no note and no -m when neither flag nor env set
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper -p "test prompt" 2>&1 >/dev/null)
recorded=$(cat "$TMPDIR_TEST/bob_args")
# use word-boundary grep so "-m" does not match "--mode" or "--max-turns"
if echo "$recorded" | grep -qE '(^| )-m( |$)'; then
    fail "-m present when no model configured" "args: $recorded"
else
    pass "-m omitted when no model configured"
fi
if echo "$err_out" | grep -qi "no model selection"; then
    fail "stderr note emitted with no model configured" "stderr: $err_out"
else
    pass "no stderr note when no model configured"
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
if echo "$recorded" | grep -q -- "--mode=my-custom-mode"; then
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
{"type":"message","timestamp":"t","role":"assistant","content":"done\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":1}}
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
# test: task-phase assistant message translation — v2 has no attempt_completion,
# so assistant message text is the only source of the phase output
# ---------------------------------------------------------------------------
echo "test: assistant message translation"

output=$(run_wrapper -p "test prompt" 2>/dev/null)

# select the first non-empty delta
text_line=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text != "")' | head -1)
if echo "$text_line" | jq -e '.delta.text == "hello world\n"' >/dev/null 2>&1; then
    pass "assistant message forwarded as content_block_delta with trailing newline"
else
    fail "assistant message not translated correctly" "got: $output"
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
# test: review-phase assistant message translation — the review phase reads the
# same v2 assistant message stream as the task phase (no attempt_completion)
# ---------------------------------------------------------------------------
echo "test: review-phase assistant message translation"

review_prompt="## Step 2: Launch Review Agents IN PARALLEL"

cat > "$TMPDIR_TEST/review_events.jsonl" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"review\n"}
{"type":"message","timestamp":"t","role":"assistant","content":"no issues found\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:REVIEW_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":2,"cost":0}}
EOF

rm -f "$TMPDIR_TEST/bob_args"
review_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/review_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$review_prompt" 2>/dev/null)

if grep -q -- "--mode=ralphex-review" "$TMPDIR_TEST/bob_args"; then
    pass "review prompt selects ralphex-review mode"
else
    fail "review prompt did not select ralphex-review" "args: $(cat "$TMPDIR_TEST/bob_args")"
fi

review_text=$(echo "$review_output" | grep '"content_block_delta"' |
    jq -r 'select(.delta.text != "") | .delta.text' | tr -d '\n')
if [[ "$review_text" == "no issues found<<<RALPHEX:REVIEW_DONE>>>" ]]; then
    pass "review-phase assistant message text forwarded verbatim"
else
    fail "review-phase assistant message not forwarded" "got: $review_output"
fi

# the review signal must land intact inside a single delta so ralphex can parse it.
if echo "$review_output" | grep '"content_block_delta"' |
        jq -e 'select(.delta.text == "<<<RALPHEX:REVIEW_DONE>>>\n")' >/dev/null 2>&1; then
    pass "review signal emitted in one content_block_delta"
else
    fail "review signal split across deltas" "got: $review_output"
fi

# ---------------------------------------------------------------------------
# test: isReasoning replaces the v1 <thinking> text heuristic
# ---------------------------------------------------------------------------
echo "test: isReasoning message filtering"

cat > "$TMPDIR_TEST/reasoning_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"weighing the options\n","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"final answer\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":1}}
EOF

reasoning_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/reasoning_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$reasoning_output" | grep -q "weighing the options"; then
    fail "isReasoning message leaked with BOB_VERBOSE=0" "got: $reasoning_output"
else
    pass "isReasoning message suppressed by default"
fi
if echo "$reasoning_output" | grep -q "final answer"; then
    pass "non-reasoning assistant message still forwarded"
else
    fail "non-reasoning assistant message dropped" "got: $reasoning_output"
fi

reasoning_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/reasoning_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$reasoning_output" | grep -q "weighing the options"; then
    pass "isReasoning message shown with BOB_VERBOSE=1"
else
    fail "isReasoning message missing with BOB_VERBOSE=1" "got: $reasoning_output"
fi

# ---------------------------------------------------------------------------
# test: exactly one terminating result event, whether or not bob sent one
# ---------------------------------------------------------------------------
echo "test: terminal result event"

# ClaudeExecutor treats a result event as end-of-turn, so the wrapper must emit
# exactly one — its own terminating result, after the line buffer is flushed. A
# bob result event is consumed, never forwarded as a second result.
cat > "$TMPDIR_TEST/withresult_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"text only\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success"}
EOF
output_withresult=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/withresult_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
withresult_results=$(echo "$output_withresult" | grep -c '"result"')
if [[ "$withresult_results" -eq 1 ]]; then
    pass "bob result event consumed, one terminating result emitted"
else
    fail "unexpected result count" "expected 1, got $withresult_results: $output_withresult"
fi

# a partial trailing line must be flushed BEFORE the terminating result, otherwise
# ralphex ends the turn without ever seeing the last (possibly signal-bearing) line.
cat > "$TMPDIR_TEST/flushorder_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"tail without newline","isReasoning":false}
{"type":"result","timestamp":"t","status":"success"}
EOF
output_flushorder=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/flushorder_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
flushorder_text_line=$(echo "$output_flushorder" | grep -n "tail without newline" | head -1 | cut -d: -f1)
flushorder_result_line=$(echo "$output_flushorder" | grep -n '"result"' | head -1 | cut -d: -f1)
if [[ -n "$flushorder_text_line" && -n "$flushorder_result_line" &&
      "$flushorder_text_line" -lt "$flushorder_result_line" ]]; then
    pass "partial trailing line flushed before the terminating result"
else
    fail "trailing line not flushed before the result event" "got: $output_flushorder"
fi

# a stream with no result event yields exactly one (the fallback) result.
cat > "$TMPDIR_TEST/noresult_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"text only\n","isReasoning":false}
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

# v2 result events always carry status "success" and a stats object — there is no
# result-failure channel any more ({type:"error"} covers that, tested below). The
# stats payload must be consumed, not leaked, and the stream must end with exactly
# one terminating result event.
cat > "$TMPDIR_TEST/v2_result_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"work done\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":4,"cost":0.0123,"durationMs":4200,"tokensIn":1200,"tokensOut":340}}
EOF
set +e
v2_result_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/v2_result_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
v2_result_exit=$?
set -e

if echo "$v2_result_output" | grep -qE 'durationMs|tokensIn|0\.0123'; then
    fail "v2 result stats leaked into the translated stream" "got: $v2_result_output"
else
    pass "v2 result stats consumed, not leaked"
fi

# the last line terminates the stream and is the only result event after the
# final text delta; a v2 success result never turns into a failure.
v2_last_line=$(echo "$v2_result_output" | tail -1)
if echo "$v2_last_line" | jq -e '.type == "result" and .result == ""' >/dev/null 2>&1; then
    pass "stream terminates with exactly one empty result event"
else
    fail "stream did not terminate with an empty result event" "got: $v2_result_output"
fi
if [[ $(echo "$v2_result_output" | grep -c '"result"') -eq 1 ]]; then
    pass "v2 result event consumed without emitting a second result"
else
    fail "unexpected v2 result count" "got: $v2_result_output"
fi
if [[ $v2_result_exit -eq 0 ]]; then
    pass "v2 success result exits zero"
else
    fail "v2 success result did not exit zero" "got: $v2_result_exit"
fi

# ---------------------------------------------------------------------------
# test: {type:"error"} is v2's only failure channel — it must surface as an
# error line and force a non-zero exit, not be swallowed into a keepalive
# ---------------------------------------------------------------------------
echo "test: error event is a real failure"

cat > "$TMPDIR_TEST/error_event_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"starting\n","isReasoning":false}
{"type":"error","timestamp":"t","severity":"error","message":"Max cost exceeded: $5.00 limit reached"}
{"type":"result","timestamp":"t","status":"success","stats":{"turns":3}}
EOF
set +e
error_event_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/error_event_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
error_event_exit=$?
set -e

if echo "$error_event_output" | grep -q "error: bob: Max cost exceeded"; then
    pass "error event emitted as an error line"
else
    fail "error event not emitted" "got: $error_event_output"
fi
if [[ $error_event_exit -ne 0 ]]; then
    pass "error event forces non-zero exit ($error_event_exit)"
else
    fail "error event did not force non-zero exit" "got: $error_event_exit"
fi
# the wrapper already emitted a real diagnostic, so the synthetic no-diagnostic
# fallback must stay quiet.
if echo "$error_event_output" | grep -q "without diagnostic output"; then
    fail "synthetic diagnostic duplicated the bob error event" "got: $error_event_output"
else
    pass "error event suppresses the synthetic fallback diagnostic"
fi

# a signal token inside an error message must be neutralized so a bob failure
# cannot forge a ralphex completion signal.
cat > "$TMPDIR_TEST/error_signal_events.jsonl" << 'EOF'
{"type":"error","timestamp":"t","severity":"error","message":"aborted before <<<RALPHEX:ALL_TASKS_DONE>>>"}
EOF
set +e
error_signal_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/error_signal_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
set -e
if echo "$error_signal_output" | grep -q "<<<RALPHEX:ALL_TASKS_DONE>>>"; then
    fail "error event leaked a live ralphex signal" "got: $error_signal_output"
else
    pass "error event signal token neutralized"
fi

# an error event carrying no usable message must still name something searchable:
# a bare "error: bob:" line tells the user nothing about why the run failed.
assert_error_placeholder() {
    local label="$1"
    local event="$2"
    local placeholder_output=""
    local placeholder_exit=0

    printf '%s\n' "$event" > "$TMPDIR_TEST/error_empty_events.jsonl"
    set +e
    placeholder_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/error_empty_events.jsonl" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" 2>/dev/null)
    placeholder_exit=$?
    set -e

    if echo "$placeholder_output" | grep -q "error: bob: unspecified bob error" &&
        [[ $placeholder_exit -ne 0 ]]; then
        pass "$label"
    else
        fail "$label" "exit: $placeholder_exit output: $placeholder_output"
    fi
}

assert_error_placeholder "error event with no message field names a placeholder cause" \
    '{"type":"error","timestamp":"t","severity":"error"}'
assert_error_placeholder "error event with an empty message names a placeholder cause" \
    '{"type":"error","timestamp":"t","severity":"error","message":""}'
assert_error_placeholder "error event with a whitespace message names a placeholder cause" \
    '{"type":"error","timestamp":"t","severity":"error","message":"   "}'

# severity is not inspected: bob may label an error event "warning" or omit the
# field entirely, and either way {type:"error"} is the failure channel.
cat > "$TMPDIR_TEST/error_severity_events.jsonl" << 'EOF'
{"type":"error","timestamp":"t","severity":"warning","message":"quota exhausted"}
EOF
set +e
error_severity_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/error_severity_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
error_severity_exit=$?
set -e
if echo "$error_severity_output" | grep -q "error: bob: quota exhausted" &&
    [[ $error_severity_exit -ne 0 ]]; then
    pass "error event with a non-error severity still fails the run"
else
    fail "error event severity changed the outcome" \
        "exit: $error_severity_exit output: $error_severity_output"
fi

# result.status is always "success" in v2, but a hypothetical error status must not
# be mistaken for a failure channel — the contract is {type:"error"} only.
cat > "$TMPDIR_TEST/result_status_error_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"finished\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"error","stats":{}}
EOF
set +e
result_status_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/result_status_error_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
result_status_exit=$?
set -e
if [[ $result_status_exit -eq 0 ]] &&
    echo "$result_status_output" | grep -q '"finished' &&
    ! echo "$result_status_output" | grep -q "error: bob:"; then
    pass "result.status is not treated as a failure channel"
else
    fail "result.status changed the run outcome" \
        "exit: $result_status_exit output: $result_status_output"
fi

# a failed tool_result whose `error` is a bare string instead of {message: ...}
# must still surface its text rather than an empty marker line.
cat > "$TMPDIR_TEST/tool_error_string_events.jsonl" << 'EOF'
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":"plain string failure"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
tool_error_string_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_string_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$tool_error_string_output" | grep -q "\[tool_error\] plain string failure"; then
    pass "string-shaped tool_result error text surfaced"
else
    fail "string-shaped tool_result error text lost" "got: $tool_error_string_output"
fi

# a failed tool_result with no usable message must still name a cause: this line
# marks the failure detail as emitted, so a bare "[tool_error]" would leave the
# progress log with no searchable text for the failure at all.
cat > "$TMPDIR_TEST/tool_error_blank_events.jsonl" << 'EOF'
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"   "}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
tool_error_blank_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_blank_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$tool_error_blank_output" | grep -q "\[tool_error\] unspecified bob tool error"; then
    pass "message-less tool_result error falls back to a named cause"
else
    fail "message-less tool_result error emitted no cause" "got: $tool_error_blank_output"
fi

# ---------------------------------------------------------------------------
# test: tool_result(status=error) always emitted even with BOB_VERBOSE=0.
# In v2 a failed tool_result has no `output` — the text moved to error.message.
# ---------------------------------------------------------------------------
echo "test: tool_result error always emitted"

cat > "$TMPDIR_TEST/tool_error_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"bash","tool_id":"tool-1","parameters":{"cmd":"false"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"command failed"}}
{"type":"message","timestamp":"t","role":"assistant","content":"done\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "\[tool_error\] command failed"; then
    pass "tool_result error message read from error.message with BOB_VERBOSE=0"
else
    fail "tool_result error not emitted" "got: $output"
fi

# the v1 shape put the text in `output`; a v2 error tool_result has none, so an
# empty [tool_error] line means the wrapper is still reading the old field.
if echo "$output" | grep -qE '\[tool_error\] *$'; then
    fail "tool_result error line empty (still reading .output)" "got: $output"
else
    pass "tool_result error line carries the error text"
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

# a successful tool_result still carries its text in `output` (only the error
# shape moved to error.message), and is verbose-only.
cat > "$TMPDIR_TEST/tool_success_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"read_file","tool_id":"tool-1","parameters":{"path":"main.go"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"package main"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_success_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q "\[tool_result\] package main"; then
    pass "success tool_result output emitted with BOB_VERBOSE=1"
else
    fail "success tool_result output missing with BOB_VERBOSE=1" "got: $output"
fi

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_success_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q "\[tool_result\]"; then
    fail "success tool_result leaked with BOB_VERBOSE=0" "got: $output"
else
    pass "success tool_result suppressed with BOB_VERBOSE=0"
fi

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

# suppressed events emit empty keepalive deltas so idle_timeout does not fire while
# bob works quietly. This fixture suppresses exactly two events at BOB_VERBOSE=0 —
# the bash tool_use and the consumed bob result — while the error tool_result and the
# assistant message emit non-empty text. Assert the exact count: a loose lower bound
# would pass even if only one of the two suppressed events kept the stream alive.
keepalives=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text == "")' | wc -l | tr -d ' ')
if [[ "$keepalives" -eq 2 ]]; then
    pass "suppressed events each emit an empty keepalive delta"
else
    fail "expected 2 keepalive deltas for the suppressed tool_use and result" \
        "got $keepalives: $output"
fi

# a blank line in bob's stream still proves the process is alive, so it must produce
# a keepalive rather than being dropped silently.
printf '%s\n' '{"type":"message","timestamp":"t","role":"assistant","content":"before\n","isReasoning":false}' \
    '' '' '{"type":"result","timestamp":"t","status":"success"}' \
    > "$TMPDIR_TEST/blankline_events.jsonl"
blankline_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/blankline_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
blankline_keepalives=$(echo "$blankline_output" | grep '"content_block_delta"' |
    jq -c 'select(.delta.text == "")' | wc -l | tr -d ' ')
if [[ "$blankline_keepalives" -eq 3 ]]; then
    pass "blank stream lines emit keepalive deltas"
else
    fail "blank stream lines did not each emit a keepalive" \
        "got $blankline_keepalives: $blankline_output"
fi
if echo "$blankline_output" | grep -q "before"; then
    pass "blank stream lines do not disturb surrounding text"
else
    fail "blank stream lines lost surrounding text" "got: $blankline_output"
fi

# ---------------------------------------------------------------------------
# test: text the model did not author is neutralized before being forwarded.
# ralphex matches signals as a plain substring, so a tool error or tool output
# quoting a signal token would otherwise forge a real completion signal — and
# ralphex's own prompts and test fixtures contain those literals.
# ---------------------------------------------------------------------------
echo "test: non-model text cannot forge signals"

cat > "$TMPDIR_TEST/forge_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"grep <<<RALPHEX:ALL_TASKS_DONE>>>","tool_id":"tool-1","parameters":{}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"grep failed on <<<RALPHEX:ALL_TASKS_DONE>>>"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-2","status":"success","output":"match: <<<RALPHEX:REVIEW_DONE>>>"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
for forge_verbose in 0 1; do
    forge_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/forge_events.jsonl" \
        BOB_VERBOSE="$forge_verbose" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" 2>/dev/null)
    if echo "$forge_output" | grep -q "<<<RALPHEX:"; then
        fail "tool text forged a live ralphex signal (BOB_VERBOSE=$forge_verbose)" \
            "got: $forge_output"
    else
        pass "tool text signal tokens neutralized (BOB_VERBOSE=$forge_verbose)"
    fi
done
# neutralizing must not delete the text — the finding still has to be readable.
forge_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/forge_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$forge_output" | grep -q "<<< RALPHEX:ALL_TASKS_DONE>>>" &&
    echo "$forge_output" | grep -q "<<< RALPHEX:REVIEW_DONE>>>"; then
    pass "neutralized tool text stays readable"
else
    fail "neutralized tool text lost its content" "got: $forge_output"
fi

# ---------------------------------------------------------------------------
# test: verbose reasoning text is neutralized and kept out of the answer buffer
# ---------------------------------------------------------------------------
echo "test: verbose reasoning isolation"

# reasoning is bob's own narration, not the model's answer, so a signal token in it
# must not reach ralphex intact; and a reasoning chunk with no trailing newline must
# not splice itself onto the front of the next real answer line.
cat > "$TMPDIR_TEST/reasoning_isolation_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"considering <<<RALPHEX:ALL_TASKS_DONE>>> as a token","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:ALL_TASKS_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
reasoning_isolation_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/reasoning_isolation_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$reasoning_isolation_output" | grep -q "considering <<< RALPHEX:ALL_TASKS_DONE>>>"; then
    pass "verbose reasoning signal token neutralized"
else
    fail "verbose reasoning leaked a live signal token" \
        "got: $reasoning_isolation_output"
fi
# the model's own signal line must arrive on its own, not glued behind reasoning.
if echo "$reasoning_isolation_output" |
    jq -re 'select(.type == "content_block_delta") | .delta.text' 2>/dev/null |
    grep -qx '<<<RALPHEX:ALL_TASKS_DONE>>>'; then
    pass "answer line unaffected by an unterminated reasoning chunk"
else
    fail "reasoning chunk spliced into the answer line" \
        "got: $reasoning_isolation_output"
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
{"type":"message","role":"assistant","content":"after garbage\n","isReasoning":false}
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
{"type":"message","timestamp":"t","role":"assistant","content":"hello\n","isReasoning":false}
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
{"type":"message","timestamp":"t","role":"assistant","content":"partial\n","isReasoning":false}
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
# test: automatic phase selection and prompt delivery
# ---------------------------------------------------------------------------
echo "test: automatic phase selection"

assert_selected_mode() {
    local expected="$1"
    local test_prompt="$2"
    local events_file="$TMPDIR_TEST/minimal_events.txt"

    [[ "$expected" == "ralphex-plan" ]] && events_file="$TMPDIR_TEST/plan_ready_events.txt"

    rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
    MOCK_STDOUT_FILE="$events_file" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "$test_prompt" >/dev/null 2>&1

    if grep -q -- "--mode=$expected" "$TMPDIR_TEST/bob_args"; then
        pass "prompt selected $expected"
    else
        fail "prompt did not select $expected" "args: $(cat "$TMPDIR_TEST/bob_args")"
    fi
    # v2 has no attempt_completion tool, so plan mode no longer prepends a
    # terminal-tool protocol adapter: every mode delivers the prompt byte-for-byte.
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
    local events_file="$TMPDIR_TEST/minimal_events.txt"

    [[ "$expected" == "ralphex-plan" ]] && events_file="$TMPDIR_TEST/plan_ready_events.txt"

    rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
    MOCK_STDOUT_FILE="$events_file" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" < "$prompt_file" >/dev/null 2>&1
    if grep -q -- "--mode=$expected" "$TMPDIR_TEST/bob_args"; then
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
if grep -q -- "--mode=user-defined-mode" "$TMPDIR_TEST/bob_args"; then
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
if grep -q -- "--mode=code" "$TMPDIR_TEST/bob_args"; then
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
# test: plan mode invocation — v2 removed attempt_completion, so the wrapper no
# longer prepends a terminal-tool protocol adapter and the prompt reaches bob
# byte-for-byte. Plan boundaries are read from assistant deltas alone.
# ---------------------------------------------------------------------------
echo "test: plan mode invocation"

plan_prompt=$'<<<RALPHEX:QUESTION>>>\n<<<RALPHEX:PLAN_DRAFT>>>\n<<<RALPHEX:PLAN_READY>>>'
rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_args_lines" "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_ready_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--hide-intermediary-output"; then
    fail "plan mode must expose intermediary assistant deltas" "args: $recorded"
else
    pass "plan mode omits --hide-intermediary-output"
fi
if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "$plan_prompt" ]]; then
    pass "plan prompt delivered without a protocol adapter"
else
    fail "plan prompt was modified" "prompt: $(cat "$TMPDIR_TEST/bob_prompt")"
fi
if grep -qi 'attempt_completion' "$TMPDIR_TEST/bob_prompt"; then
    fail "plan prompt still mentions the removed attempt_completion tool" \
        "prompt: $(cat "$TMPDIR_TEST/bob_prompt")"
else
    pass "plan prompt carries no attempt_completion instructions"
fi

# ---------------------------------------------------------------------------
# regression: Bob streams a valid QUESTION across several assistant deltas after
# mentioning a malformed example in a reasoning message, then keeps talking. The
# wrapper must ignore the reasoning example, stop at END, and drop the rest.
# ---------------------------------------------------------------------------
echo "test: streamed QUESTION boundary recovery"

cat > "$TMPDIR_TEST/plan_intermediary_question.jsonl" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"assistant","content":"Example only: <<<RALPHEX:QUESTION>>> {bad} <<<RALPHEX:END>>>\n","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:QUES","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"TION>>>\n{\"question\":\"Which mode?\",\"options\":[\"TCP\",\"UDP\"]}\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"user","content":"This is an automated message: use a tool"}
{"type":"message","timestamp":"t","role":"assistant","content":"Signal: <<<RALPHEX:QUESTION>>>\nQuestion: Which mode?","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_intermediary_question.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
question_text=$(echo "$output" | jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
if [[ "$question_text" == $'<<<RALPHEX:QUESTION>>>\n{"question":"Which mode?","options":["TCP","UDP"]}\n<<<RALPHEX:END>>>' ]]; then
    pass "QUESTION streamed across deltas recovered as one boundary"
else
    fail "streamed QUESTION was not recovered exactly" "text: $question_text"
fi
if echo "$question_text" | grep -q '{bad}'; then
    fail "malformed example from a reasoning message leaked" "text: $question_text"
else
    pass "reasoning-message boundary example ignored"
fi
if echo "$question_text" | grep -q 'automated message\|Signal:'; then
    fail "post-boundary Bob continuation leaked" "text: $question_text"
else
    pass "post-boundary Bob continuation suppressed"
fi

# ---------------------------------------------------------------------------
# test: a single-delta QUESTION with a valid payload is forwarded as-is
# ---------------------------------------------------------------------------
echo "test: assistant message QUESTION validation"

cat > "$TMPDIR_TEST/plan_completion_question.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:QUESTION>>>\n{\"question\":\"Choose stack?\",\"options\":[\"JS\",\"TS\"]}\n<<<RALPHEX:END>>>","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_completion_question.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("\"question\":\"Choose stack?\"")) and (.delta.text | contains("<<<RALPHEX:END>>>")))' >/dev/null 2>&1; then
    pass "valid QUESTION in an assistant message forwarded"
else
    fail "valid QUESTION in an assistant message rejected" "output: $output"
fi

# Bob may ignore the prompt's preferred 2-4 option count. Ralphex's parser only
# requires a non-empty string array, so the adapter must not reject an otherwise
# valid boundary before ralphex can display it.
cat > "$TMPDIR_TEST/plan_completion_many_options.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"\n<<<RALPHEX:QUESTION>>>\n{\"question\": \"Which planet?\", \"options\": [\"Mercury\", \"Venus\", \"Earth\", \"Mars\", \"Outer planet\", \"Multiple planets\"]}\n<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_completion_many_options.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("Multiple planets")) and (.delta.text | contains("<<<RALPHEX:END>>>")))' >/dev/null 2>&1; then
    pass "QUESTION with more than four options follows ralphex parser contract"
else
    fail "valid QUESTION with many options rejected" "output: $output"
fi

# an invalid QUESTION payload must be rejected rather than forwarded to ralphex,
# even though its markers are well formed.
cat > "$TMPDIR_TEST/plan_invalid_question_payload.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:QUESTION>>>\n{\"question\":\"Choose stack?\",\"options\":[]}\n<<<RALPHEX:END>>>","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_invalid_question_payload.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
invalid_payload_exit=$?
set -e
if [[ $invalid_payload_exit -ne 0 ]] &&
    echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("invalid QUESTION payload from Bob")))' >/dev/null 2>&1; then
    pass "QUESTION with an empty options array fails closed"
else
    fail "invalid QUESTION payload was not rejected" \
        "exit: $invalid_payload_exit output: $output"
fi

# the failure diagnostic above is the only error line: the status is synthesized by
# the wrapper, so the silent-failure fallback must not also claim bob exited without
# diagnostic output at a code bob never reported.
if echo "$output" | grep -q "without diagnostic output"; then
    fail "plan boundary failure also reported as a silent failure" "output: $output"
else
    pass "plan boundary failure suppresses the synthetic fallback diagnostic"
fi

# a malformed occurrence must only lose candidacy, not abandon the marker type:
# plan_stream_buffer only grows, so a model that self-corrects and re-emits a
# well-formed payload would otherwise keep losing to the same bad occurrence forever.
cat > "$TMPDIR_TEST/plan_question_selfcorrect.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:QUESTION>>>\n{\"question\":\"Choose stack?\",\"options\":[]}\n<<<RALPHEX:END>>>\nThat payload was malformed, asking again:\n<<<RALPHEX:QUESTION>>>\n{\"question\":\"Choose stack?\",\"options\":[\"JS\",\"TS\"]}\n<<<RALPHEX:END>>>","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_question_selfcorrect.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
selfcorrect_exit=$?
set -e
if [[ $selfcorrect_exit -eq 0 ]] &&
    echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("\"options\":[\"JS\",\"TS\"]")))' >/dev/null 2>&1; then
    pass "a valid QUESTION after an invalid one is still emitted"
else
    fail "self-corrected QUESTION was discarded with the invalid occurrence" \
        "exit: $selfcorrect_exit output: $output"
fi
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("invalid QUESTION payload from Bob")))' >/dev/null 2>&1; then
    fail "self-corrected QUESTION still reported the earlier payload error" "output: $output"
else
    pass "recovered QUESTION reports no payload error"
fi
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("was malformed, asking again")))' >/dev/null 2>&1; then
    fail "narration between the two QUESTION occurrences leaked into the boundary" \
        "output: $output"
else
    pass "narration before the recovered QUESTION is not forwarded"
fi

# ---------------------------------------------------------------------------
# test: malformed terminal QUESTION fails closed instead of starting iteration 2
# ---------------------------------------------------------------------------
echo "test: malformed plan boundary fails closed"

cat > "$TMPDIR_TEST/plan_malformed_question.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"Signal: <<<RALPHEX:QUESTION>>>\nQuestion: Choose stack?\nOptions: JS, TS","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_malformed_question.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
malformed_exit=$?
set -e
if [[ $malformed_exit -ne 0 ]]; then
    pass "malformed QUESTION exits non-zero"
else
    fail "malformed QUESTION should fail closed" "output: $output"
fi
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("without a complete ralphex plan boundary")))' >/dev/null 2>&1; then
    pass "malformed QUESTION reports a clear boundary error"
else
    fail "malformed QUESTION error missing" "output: $output"
fi

# a plan run that never emits any boundary marker must fail the same way rather
# than reporting a clean success on ordinary prose.
cat > "$TMPDIR_TEST/plan_no_boundary.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"I explored the repository and have some thoughts.\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_no_boundary.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
no_boundary_exit=$?
set -e
if [[ $no_boundary_exit -ne 0 ]] &&
    echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("without a complete ralphex plan boundary")))' >/dev/null 2>&1; then
    pass "missing plan boundary fails closed"
else
    fail "missing plan boundary was not reported" \
        "exit: $no_boundary_exit output: $output"
fi
if echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("some thoughts")))' >/dev/null 2>&1; then
    fail "plan-mode prose leaked into the translated stream" "output: $output"
else
    pass "plan-mode prose outside a boundary is not forwarded"
fi

# an empty PLAN_DRAFT body is rejected: ralphex would otherwise present an empty
# draft for review.
cat > "$TMPDIR_TEST/plan_empty_draft.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_DRAFT>>>\n   \n<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_empty_draft.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
empty_draft_exit=$?
set -e
if [[ $empty_draft_exit -ne 0 ]] &&
    echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("empty PLAN_DRAFT payload from Bob")))' >/dev/null 2>&1; then
    pass "empty PLAN_DRAFT payload fails closed"
else
    fail "empty PLAN_DRAFT payload was not rejected" \
        "exit: $empty_draft_exit output: $output"
fi

# {type:"error"} is bob v2's only failure channel, so plan runs must surface it too:
# a rate-limit, auth, or max-cost message swallowed into a keepalive would show up
# only as a generic missing-boundary error with no cause.
cat > "$TMPDIR_TEST/plan_error_event.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"exploring the repository\n","isReasoning":false}
{"type":"error","timestamp":"t","severity":"error","message":"Rate limit exceeded, retry later <<<RALPHEX:PLAN_READY>>>"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_error_event.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
plan_error_exit=$?
set -e
if [[ $plan_error_exit -ne 0 ]] &&
    echo "$output" | jq -e 'select(.type=="content_block_delta" and (.delta.text | contains("error: bob: Rate limit exceeded")))' >/dev/null 2>&1; then
    pass "plan mode surfaces a bob error event"
else
    fail "plan mode swallowed a bob error event" \
        "exit: $plan_error_exit output: $output"
fi
if echo "$output" | grep -q "<<<RALPHEX:PLAN_READY>>>"; then
    fail "plan-mode error event forged a plan signal" "output: $output"
else
    pass "plan-mode error event signal token neutralized"
fi
if echo "$output" | grep -q "without diagnostic output"; then
    fail "plan-mode error event still reported as a silent failure" "output: $output"
else
    pass "plan-mode error event suppresses the synthetic fallback diagnostic"
fi

# ---------------------------------------------------------------------------
# test: streamed PLAN_DRAFT stops at END and discards trailing prose
# ---------------------------------------------------------------------------
echo "test: streamed PLAN_DRAFT boundary"

cat > "$TMPDIR_TEST/plan_intermediary_draft.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"planning","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\n\n## Overview\nBody.\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:END>>>\nThis must not leak","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_intermediary_draft.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
draft_text=$(echo "$output" | jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
if echo "$draft_text" | grep -q '<<<RALPHEX:PLAN_DRAFT>>>' &&
    echo "$draft_text" | grep -q '<<<RALPHEX:END>>>' &&
    ! echo "$draft_text" | grep -q 'must not leak' &&
    ! echo "$draft_text" | grep -q 'planning'; then
    pass "PLAN_DRAFT boundary preserved and truncated"
else
    fail "PLAN_DRAFT boundary handling failed" "text: $draft_text"
fi

# ---------------------------------------------------------------------------
# test: bare PLAN_READY and TASK_FAILED boundaries need no END marker, and the
# earliest valid boundary in the buffer wins.
# ---------------------------------------------------------------------------
echo "test: bare plan boundary markers"

assert_bare_plan_boundary() {
    local label="$1"
    local content="$2"
    local expected="$3"
    local boundary_text=""

    printf '%s\n' \
        "{\"type\":\"message\",\"timestamp\":\"t\",\"role\":\"assistant\",\"content\":$(jq -Rn --arg c "$content" '$c'),\"isReasoning\":false}" \
        '{"type":"result","timestamp":"t","status":"success","stats":{}}' \
        > "$TMPDIR_TEST/plan_bare_boundary.jsonl"

    boundary_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_bare_boundary.jsonl" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null |
        jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')

    if [[ "$boundary_text" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label" "text: $boundary_text"
    fi
}

assert_bare_plan_boundary "bare PLAN_READY forwarded alone" \
    $'Wrote the plan file.\n<<<RALPHEX:PLAN_READY>>>\n' '<<<RALPHEX:PLAN_READY>>>'
assert_bare_plan_boundary "bare TASK_FAILED forwarded alone" \
    $'Cannot continue.\n<<<RALPHEX:TASK_FAILED>>>\n' '<<<RALPHEX:TASK_FAILED>>>'
# PLAN_READY appears first in the buffer, so it wins over the later PLAN_DRAFT.
assert_bare_plan_boundary "earliest boundary wins over a later PLAN_DRAFT" \
    $'<<<RALPHEX:PLAN_READY>>>\n<<<RALPHEX:PLAN_DRAFT>>>\nlate draft\n<<<RALPHEX:END>>>\n' \
    '<<<RALPHEX:PLAN_READY>>>'
# a bare marker quoted INSIDE a draft is the model narrating the protocol, not a
# boundary. Accepting it would discard the whole draft and report a plan run as
# complete with nothing for the user to review.
assert_bare_plan_boundary "bare marker quoted inside a draft body is not a boundary" \
    $'<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nI will emit <<<RALPHEX:PLAN_READY>>> once written.\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nI will emit <<<RALPHEX:PLAN_READY>>> once written.\n<<<RALPHEX:END>>>'
# same hole, but split across deltas: the draft is still open when the quoted
# marker arrives, so the first loop has no candidate yet to compare against.
cat > "$TMPDIR_TEST/plan_quoted_marker_split.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nI will emit <<<RALPHEX:PLAN_READY>>> once the file is written.\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"## Overview\nBody.\n<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
quoted_marker_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_quoted_marker_split.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
if [[ "$quoted_marker_text" == '<<<RALPHEX:PLAN_DRAFT>>>'* ]] &&
    echo "$quoted_marker_text" | grep -q 'Body.' &&
    echo "$quoted_marker_text" | grep -q '<<<RALPHEX:END>>>'; then
    pass "streamed draft survives a bare marker quoted before its END"
else
    fail "streamed draft discarded in favour of a quoted bare marker" \
        "text: $quoted_marker_text"
fi

# the still-open-boundary guard above must only arm on a marker that starts a
# line. An unterminated marker never clears, so arming on a mid-sentence mention
# would suppress every later terminal boundary and fail the whole plan run on
# narration the model is entitled to produce.
assert_bare_plan_boundary "narrated mid-sentence marker does not suppress PLAN_READY" \
    $'I considered asking via <<<RALPHEX:QUESTION>>> but had enough context.\n<<<RALPHEX:PLAN_READY>>>\n' \
    '<<<RALPHEX:PLAN_READY>>>'
assert_bare_plan_boundary "narrated mid-sentence marker does not suppress TASK_FAILED" \
    $'A <<<RALPHEX:PLAN_DRAFT>>> was never viable here.\n<<<RALPHEX:TASK_FAILED>>>\n' \
    '<<<RALPHEX:TASK_FAILED>>>'

# a marker named in prose BEFORE the real boundary must not capture it. ralphex
# extracts leftmost-marker-to-nearest-END, so binding to the first occurrence
# would hand the user the narration plus a stray protocol token as the draft.
assert_bare_plan_boundary "narrated marker before the real draft does not capture it" \
    $'I will emit <<<RALPHEX:PLAN_DRAFT>>> once ready.\n<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>'
assert_bare_plan_boundary "narrated marker before the real QUESTION does not capture it" \
    $'I could ask via <<<RALPHEX:QUESTION>>> here.\n<<<RALPHEX:QUESTION>>>\n{"question":"Which store?","options":["postgres","sqlite"]}\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:QUESTION>>>\n{"question":"Which store?","options":["postgres","sqlite"]}\n<<<RALPHEX:END>>>'
# tolerance for an inlined marker is preserved: with no line-leading occurrence
# anywhere, the mid-sentence one is still accepted rather than failing closed.
assert_bare_plan_boundary "inlined marker with no line-leading occurrence still parses" \
    $'Here it is: <<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>'

# the narration preference applies to the TERMINAL markers too, not just the
# opening ones. A prose mention of PLAN_READY before a real, complete draft used
# to win on "leftmost occurrence" alone, ending the run with a PLAN_READY signal
# and nothing for the user to review; the TASK_FAILED variant aborted the run.
assert_bare_plan_boundary "narrated PLAN_READY does not outrank a later real draft" \
    $'I will emit <<<RALPHEX:PLAN_READY>>> once you accept.\n<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nBody.\n<<<RALPHEX:END>>>'
assert_bare_plan_boundary "narrated TASK_FAILED does not outrank a later real QUESTION" \
    $'If blocked I would emit <<<RALPHEX:TASK_FAILED>>>.\n<<<RALPHEX:QUESTION>>>\n{"question":"Which store?","options":["postgres","sqlite"]}\n<<<RALPHEX:END>>>\n' \
    $'<<<RALPHEX:QUESTION>>>\n{"question":"Which store?","options":["postgres","sqlite"]}\n<<<RALPHEX:END>>>'
# narration must not make the wrapper fail closed either: a real line-leading
# terminal marker after a prose mention of itself is still a boundary.
assert_bare_plan_boundary "narrated PLAN_READY does not block a later real PLAN_READY" \
    $'I will emit <<<RALPHEX:PLAN_READY>>> now that the file exists.\n<<<RALPHEX:PLAN_READY>>>\n' \
    '<<<RALPHEX:PLAN_READY>>>'

# same hole on the streaming path, for a draft the model opened INLINE: the
# still-open guard used to arm only on a line-leading opening, so a marker quoted
# inside an inline-opened body killed bob mid-draft.
cat > "$TMPDIR_TEST/plan_inline_open_quoted.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"Here is the draft: <<<RALPHEX:PLAN_DRAFT>>>\n# Draft\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"Later I will send <<<RALPHEX:PLAN_READY>>>.\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"## Overview\nBody.\n<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
inline_open_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_inline_open_quoted.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
if [[ "$inline_open_text" == '<<<RALPHEX:PLAN_DRAFT>>>'* ]] &&
    echo "$inline_open_text" | grep -q 'Body.' &&
    echo "$inline_open_text" | grep -q '<<<RALPHEX:END>>>'; then
    pass "inline-opened streamed draft survives a quoted bare marker"
else
    fail "inline-opened streamed draft discarded for a quoted bare marker" \
        "text: $inline_open_text"
fi

# conversely, a LINE-LEADING opening still suppresses a line-leading terminal
# marker inside its unterminated body. A plan about ralphex's own signal protocol
# can legitimately put one of these tokens on its own line, and discarding the
# draft for it would be the same silent no-plan failure.
cat > "$TMPDIR_TEST/plan_leading_quoted_marker.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_DRAFT>>>\n# Draft\nThe wrapper emits:\n<<<RALPHEX:PLAN_READY>>>\n","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"## Overview\nBody.\n<<<RALPHEX:END>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
leading_quoted_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_leading_quoted_marker.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
if [[ "$leading_quoted_text" == '<<<RALPHEX:PLAN_DRAFT>>>'* ]] &&
    echo "$leading_quoted_text" | grep -q 'Body.' &&
    echo "$leading_quoted_text" | grep -q '<<<RALPHEX:END>>>'; then
    pass "streamed draft survives a line-leading marker quoted before its END"
else
    fail "streamed draft discarded for a line-leading quoted marker" \
        "text: $leading_quoted_text"
fi

# ---------------------------------------------------------------------------
# test: after a valid plan boundary the wrapper terminates bob and normalizes the
# exit status. Bob keeps working autonomously otherwise, so a slow-exiting bob
# must not hold the wrapper open, and bob's own status must not leak.
# ---------------------------------------------------------------------------
echo "test: plan boundary terminates bob"

plan_stop_bin="$TMPDIR_TEST/plan_stop_bin"
mkdir -p "$plan_stop_bin"
cat > "$plan_stop_bin/bob" << 'PLAN_STOP_EOF'
#!/usr/bin/env bash
cat > /dev/null  # consume the prompt
echo $$ > "$TMPDIR_TEST/plan_stop_pid"
printf '%s\n' '{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_READY>>>\n","isReasoning":false}'
exec sleep 30
PLAN_STOP_EOF
chmod +x "$plan_stop_bin/bob"

rm -f "$TMPDIR_TEST/plan_stop_pid"
plan_stop_start=$SECONDS
set +e
plan_stop_output=$(PATH="$plan_stop_bin:$PATH" bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
plan_stop_exit=$?
set -e
plan_stop_elapsed=$((SECONDS - plan_stop_start))

if [[ $plan_stop_exit -eq 0 && $plan_stop_elapsed -lt 20 ]]; then
    pass "wrapper returns promptly with status 0 after a plan boundary"
else
    fail "wrapper did not stop cleanly after a plan boundary" \
        "exit: $plan_stop_exit elapsed: ${plan_stop_elapsed}s"
fi
if echo "$plan_stop_output" | grep -q '<<<RALPHEX:PLAN_READY>>>'; then
    pass "plan boundary emitted before bob was terminated"
else
    fail "plan boundary lost when bob was terminated" "got: $plan_stop_output"
fi

plan_stop_pid=$(cat "$TMPDIR_TEST/plan_stop_pid" 2>/dev/null || echo "")
if [[ -n "$plan_stop_pid" ]]; then
    for _ in $(seq 1 20); do
        kill -0 "$plan_stop_pid" 2>/dev/null || break
        sleep 0.1
    done
fi
if [[ -n "$plan_stop_pid" ]] && kill -0 "$plan_stop_pid" 2>/dev/null; then
    fail "bob still running after the plan boundary" "pid: $plan_stop_pid"
    kill -9 "$plan_stop_pid" 2>/dev/null || true
else
    pass "bob terminated after the plan boundary"
fi
rm -rf "$plan_stop_bin"

# bob v2's own handler (`e&&process.exit(1),e=!0,t.abort(...)`) treats the FIRST
# TERM as "abort the in-flight task" and only exits on a second one, so a mock
# that dies on one TERM cannot prove the wrapper gets out. These two emulate the
# real ladder: abort-then-exit, and a bob that never honors TERM at all.
assert_stubborn_bob_stops() {
    local label="$1"
    local trap_body="$2"
    local stubborn_bin="$TMPDIR_TEST/stubborn_bin"
    local pid_file="$TMPDIR_TEST/stubborn_pid"
    local start=0 elapsed=0 exit_code=0 output="" pid=""

    rm -rf "$stubborn_bin"
    mkdir -p "$stubborn_bin"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'cat > /dev/null'
        printf 'echo $$ > "%s"\n' "$pid_file"
        printf '%s\n' "$trap_body"
        printf '%s\n' \
            "printf '%s\\n' '{\"type\":\"message\",\"timestamp\":\"t\",\"role\":\"assistant\",\"content\":\"<<<RALPHEX:PLAN_READY>>>\\n\",\"isReasoning\":false}'"
        printf '%s\n' 'while true; do sleep 0.2; done'
    } > "$stubborn_bin/bob"
    chmod +x "$stubborn_bin/bob"

    rm -f "$pid_file"
    start=$SECONDS
    set +e
    output=$(PATH="$stubborn_bin:$PATH" bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
    exit_code=$?
    set -e
    elapsed=$((SECONDS - start))

    if [[ $exit_code -eq 0 && $elapsed -lt 20 ]] &&
        echo "$output" | grep -q '<<<RALPHEX:PLAN_READY>>>'; then
        pass "$label"
    else
        fail "$label" "exit: $exit_code elapsed: ${elapsed}s output: $output"
    fi

    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        fail "$label (bob left running)" "pid: $pid"
        kill -9 "$pid" 2>/dev/null || true
    else
        pass "$label (bob no longer running)"
    fi
    rm -rf "$stubborn_bin"
}

assert_stubborn_bob_stops "wrapper escalates to a second TERM when the first only aborts" \
    'term_count=0
handle_term() { term_count=$((term_count + 1)); [[ $term_count -ge 2 ]] && exit 1; }
trap handle_term TERM'
assert_stubborn_bob_stops "wrapper escalates to KILL when bob ignores TERM entirely" \
    "trap '' TERM"

# the intentional stop must also override a non-zero status from the terminated
# bob, otherwise every successful plan iteration would look like a failure.
printf '%s\n' \
    '{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:PLAN_READY>>>\n","isReasoning":false}' \
    > "$TMPDIR_TEST/plan_stop_code.jsonl"
set +e
plan_stop_code_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plan_stop_code.jsonl" \
    MOCK_EXIT_CODE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "$plan_prompt" 2>/dev/null)
plan_stop_code_exit=$?
set -e
if [[ $plan_stop_code_exit -eq 0 ]] &&
    echo "$plan_stop_code_output" | grep -q '<<<RALPHEX:PLAN_READY>>>'; then
    pass "intentional stop overrides bob's non-zero exit after a plan boundary"
else
    fail "bob's exit code leaked past an emitted plan boundary" \
        "exit: $plan_stop_code_exit output: $plan_stop_code_output"
fi

# ---------------------------------------------------------------------------
# test: signal passthrough in assistant message text
# ---------------------------------------------------------------------------
echo "test: signal passthrough"

cat > "$TMPDIR_TEST/signal_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:ALL_TASKS_DONE>>>\n","isReasoning":false}
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
# test: a signal token split across several streaming message deltas is
# re-assembled by the line buffer and emitted intact in one content_block_delta.
# ralphex's parser scans individual text blocks, so a signal delivered in pieces
# would otherwise never match.
# ---------------------------------------------------------------------------
echo "test: split signal re-assembly"

assert_split_signal() {
    local label="$1"
    local expected="$2"
    shift 2
    local fixture="$TMPDIR_TEST/split_signal.jsonl"
    local chunk=""
    local matches=""
    local text=""

    : > "$fixture"
    for chunk in "$@"; do
        jq -cn --arg c "$chunk" \
            '{type:"message",timestamp:"t",role:"assistant",content:$c,isReasoning:false}' \
            >> "$fixture"
    done
    printf '%s\n' '{"type":"result","timestamp":"t","status":"success","stats":{}}' >> "$fixture"

    text=$(MOCK_STDOUT_FILE="$fixture" PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" 2>/dev/null |
        jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text')
    matches=$(printf '%s\n' "$text" | grep -c "$expected" || true)

    if [[ "$matches" == "1" ]]; then
        pass "$label"
    else
        fail "$label" "matches: $matches text: $text"
    fi
}

# the token is split mid-marker across three deltas.
assert_split_signal "signal split across three deltas arrives in one block" \
    '<<<RALPHEX:ALL_TASKS_DONE>>>' '<<<RALPH' 'EX:ALL_TASKS_' 'DONE>>>'$'\n'
# a per-character trickle is the worst case for the buffer.
assert_split_signal "signal split one character per delta arrives in one block" \
    '<<<RALPHEX:REVIEW_DONE>>>' '<' '<' '<' 'R' 'A' 'L' 'P' 'H' 'E' 'X' ':' 'R' 'E' \
    'V' 'I' 'E' 'W' '_' 'D' 'O' 'N' 'E' '>' '>' '>' $'\n'
# leading prose on the same line must not split the signal off from its line.
assert_split_signal "signal split after prose on the same line arrives in one block" \
    '<<<RALPHEX:TASK_FAILED>>>' 'giving up: ' '<<<RALPHEX:TASK' '_FAILED>>>'$'\n'
# a signal with no trailing newline is flushed once at stream end.
assert_split_signal "split signal without a trailing newline is flushed once" \
    '<<<RALPHEX:ALL_TASKS_DONE>>>' '<<<RALPHEX:ALL' '_TASKS_DONE>>>'

# the re-assembled block must be exactly one delta carrying the whole line, not a
# concatenation spread over the deltas bob produced.
cat > "$TMPDIR_TEST/split_signal_exact.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:ALL","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"_TASKS_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/split_signal_exact.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
# count blocks, not lines: the delta text itself ends in a newline.
signal_blocks=$(echo "$output" | jq -s \
    '[.[] | select(.type=="content_block_delta" and .delta.text != "")] | length')
if [[ "$signal_blocks" == "1" ]] &&
    echo "$output" | jq -e \
        'select(.type=="content_block_delta" and .delta.text == "<<<RALPHEX:ALL_TASKS_DONE>>>\n")' \
        >/dev/null 2>&1; then
    pass "partial deltas emit no block until the line completes"
else
    fail "split signal produced more than one text block" \
        "blocks: $signal_blocks output: $output"
fi

# ---------------------------------------------------------------------------
# test: a non-message event arriving mid-line flushes the partial remainder under
# the kind it was buffered as, so reasoning text is never promoted to a live
# signal — EXCEPT when the answer remainder may hold half a signal token, which
# is kept buffered so the token is emitted whole.
# ---------------------------------------------------------------------------
echo "test: partial line flushed on kind change"

# a tool_result error between two halves of a signal line. ralphex matches
# signals per content_block_delta, so flushing the first half here would make the
# token undetectable and the finished iteration would be re-run: the halves must
# rejoin and the signal must arrive live, in exactly one block.
cat > "$TMPDIR_TEST/partial_line_tool_error.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:ALL","isReasoning":false}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"command failed"}}
{"type":"message","timestamp":"t","role":"assistant","content":"_TASKS_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
partial_tool_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/partial_line_tool_error.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
partial_tool_blocks=$(echo "$partial_tool_output" |
    jq -r 'select(.type=="content_block_delta" and (.delta.text | contains("<<<RALPHEX:ALL_TASKS_DONE>>>"))) | .delta.text' |
    grep -c . || true)
if echo "$partial_tool_output" | grep -q "\[tool_error\] command failed" &&
    [[ "$partial_tool_blocks" -eq 1 ]]; then
    pass "signal halves split by a tool_result error rejoin into one block"
else
    fail "partial signal line was split by a tool_result error" \
        "blocks: $partial_tool_blocks output: $partial_tool_output"
fi

# the hold-back is narrow: an answer remainder that cannot be a partial signal
# token still flushes ahead of the diagnostic, so ordinary prose is never logged
# out of order behind a tool error that came after it.
cat > "$TMPDIR_TEST/partial_line_prose.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"checking the build","isReasoning":false}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"command failed"}}
{"type":"message","timestamp":"t","role":"assistant","content":" done\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
partial_prose_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/partial_line_prose.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text' |
    tr -d '\n')
if [[ "$partial_prose_text" == "checking the build[tool_error] command failed done" ]]; then
    pass "prose remainder still flushes ahead of a tool_result error"
else
    fail "prose remainder ordering changed" "text: $partial_prose_text"
fi

# a bare opening-marker prefix with no colon yet must also be held: bob splits
# message text at arbitrary offsets, so the prefix check cannot assume the buffer
# already contains the full `<<<RALPHEX:` lead-in.
cat > "$TMPDIR_TEST/partial_line_marker_prefix.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"done <<<RALP","isReasoning":false}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"command failed"}}
{"type":"message","timestamp":"t","role":"assistant","content":"HEX:REVIEW_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
marker_prefix_blocks=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/partial_line_marker_prefix.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and (.delta.text | contains("<<<RALPHEX:REVIEW_DONE>>>"))) | .delta.text' |
    grep -c . || true)
if [[ "$marker_prefix_blocks" -eq 1 ]]; then
    pass "partial opening-marker prefix is held across a tool_result error"
else
    fail "partial opening-marker prefix was flushed mid-token" \
        "blocks: $marker_prefix_blocks"
fi

# a held remainder must still be emitted when the line never completes, otherwise
# the model's last words would be dropped instead of merely re-ordered.
cat > "$TMPDIR_TEST/partial_line_never_completed.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"almost <<<RALPHEX:ALL","isReasoning":false}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","error":{"type":"execution","message":"command failed"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
never_completed_text=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/partial_line_never_completed.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text' |
    tr -d '\n')
if [[ "$never_completed_text" == "[tool_error] command failedalmost <<<RALPHEX:ALL" ]]; then
    pass "held remainder is force-flushed at stream end"
else
    fail "held remainder lost at stream end" "text: $never_completed_text"
fi

# with BOB_VERBOSE=1 reasoning shares the line buffer with answer text. A signal
# token split across two reasoning chunks is re-assembled by the buffer, so
# neutralization has to happen on flush — a per-chunk substitution matches neither
# half and would emit a live signal the model never actually produced.
cat > "$TMPDIR_TEST/split_reasoning_signal.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"planning <<<RALP","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"HEX:ALL_TASKS_DONE>>>\n","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"real answer\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
split_reasoning_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/split_reasoning_signal.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$split_reasoning_output" | grep -q '<<< RALPHEX:ALL_TASKS_DONE>>>' &&
    ! echo "$split_reasoning_output" | grep -q '<<<RALPHEX:ALL_TASKS_DONE>>>'; then
    pass "signal split across reasoning chunks is neutralized after re-assembly"
else
    fail "reasoning-split signal token was not neutralized" \
        "got: $split_reasoning_output"
fi

# a reasoning chunk with no newline followed by real answer text: the remainder is
# flushed as reasoning (neutralized) and the answer line stays live.
cat > "$TMPDIR_TEST/reasoning_remainder_signal.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"about to emit <<<RALPHEX:REVIEW_DONE>>>","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"<<<RALPHEX:ALL_TASKS_DONE>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
reasoning_remainder_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/reasoning_remainder_signal.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$reasoning_remainder_output" | grep -q '<<< RALPHEX:REVIEW_DONE>>>' &&
    ! echo "$reasoning_remainder_output" | grep -q '<<<RALPHEX:REVIEW_DONE>>>' &&
    echo "$reasoning_remainder_output" | grep -q '<<<RALPHEX:ALL_TASKS_DONE>>>'; then
    pass "newline-less reasoning remainder is neutralized without touching the answer"
else
    fail "reasoning remainder handling changed the answer signal" \
        "got: $reasoning_remainder_output"
fi

# the reverse direction: a reasoning message arriving BETWEEN two halves of an
# answer line must not split the answer. Answer and reasoning keep independent
# buffers precisely so the signal the buffering exists to re-assemble survives a
# verbose run — a shared buffer emitted "done. <<<RALPHEX:COM" on its own and the
# phase looped on a task that had actually finished.
cat > "$TMPDIR_TEST/reasoning_between_answer_halves.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"done. <<<RALPHEX:COM","isReasoning":false}
{"type":"message","timestamp":"t","role":"assistant","content":"let me double check\n","isReasoning":true}
{"type":"message","timestamp":"t","role":"assistant","content":"PLETED>>>\n","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
for verbose_setting in 0 1; do
    interleaved_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/reasoning_between_answer_halves.jsonl" \
        BOB_VERBOSE="$verbose_setting" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" 2>/dev/null |
        jq -r 'select(.type=="content_block_delta") | .delta.text')
    if echo "$interleaved_output" | grep -qF 'done. <<<RALPHEX:COMPLETED>>>'; then
        pass "answer signal survives an interleaved reasoning message (BOB_VERBOSE=$verbose_setting)"
    else
        fail "interleaved reasoning message split the answer signal (BOB_VERBOSE=$verbose_setting)" \
            "got: $interleaved_output"
    fi
done

# a message delta with no newline emits no line, so it has to emit a keepalive
# like every other suppressed path — otherwise a long newline-less stretch reads
# as a dead session to ralphex's idle_timeout.
cat > "$TMPDIR_TEST/newlineless_answer_chunk.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"a long line still being written","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
newlineless_keepalives=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/newlineless_answer_chunk.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text == "") | .delta.text' | wc -l)
if [[ "$newlineless_keepalives" -ge 1 ]]; then
    pass "newline-less answer chunk still emits a keepalive"
else
    fail "newline-less answer chunk emitted no stream event" \
        "keepalives: $newlineless_keepalives"
fi

# a non-JSON diagnostic must not be logged ahead of assistant text buffered
# before it, or the progress log misorders cause and effect around a failure.
cat > "$TMPDIR_TEST/diagnostic_ordering.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"partial answer without newline","isReasoning":false}
plain diagnostic line from bob
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
diagnostic_order=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/diagnostic_ordering.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null |
    jq -r 'select(.type=="content_block_delta" and .delta.text != "") | .delta.text' |
    grep -n 'partial answer\|plain diagnostic')
if [[ "$(echo "$diagnostic_order" | head -1)" == *"partial answer"* ]]; then
    pass "buffered answer text is flushed before a non-JSON diagnostic"
else
    fail "non-JSON diagnostic was emitted ahead of buffered answer text" \
        "order: $diagnostic_order"
fi

# defensive: v2 puts the failure text in the top-level message, but a nested
# error.message must not be dropped — ralphex's limit/error pattern matching
# reads this line, so losing the cause also loses --wait retry.
cat > "$TMPDIR_TEST/nested_error_message.jsonl" << 'EOF'
{"type":"error","timestamp":"t","error":{"message":"rate limit exceeded"},"severity":"fatal"}
EOF
nested_error_rc=0
nested_error_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/nested_error_message.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null) || nested_error_rc=$?
if echo "$nested_error_output" | grep -qF 'error: bob: rate limit exceeded' &&
    [[ "$nested_error_rc" -ne 0 ]]; then
    pass "nested error.message is surfaced instead of the unspecified placeholder"
else
    fail "nested error.message was discarded" \
        "rc: $nested_error_rc got: $nested_error_output"
fi

# ---------------------------------------------------------------------------
# test: multi-line assistant message split into separate content_block_delta blocks
# ---------------------------------------------------------------------------
echo "test: multi-line message split"

cat > "$TMPDIR_TEST/multiline_events.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"line one\nline two\nline three\n","isReasoning":false}
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
    pass "multi-line assistant message split into separate line blocks"
else
    fail "multi-line assistant message not split correctly" "got: $output"
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

# stderr must be translated as Bob emits it, not buffered until after stdout and
# process exit. The mock pauses after stderr so output order is deterministic; the
# pause is generous because a short one makes the assertion a race against process
# startup on a loaded machine rather than a test of the wrapper.
cat > "$TMPDIR_TEST/stderr_early.txt" << 'EOF'
early diagnostic
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_early.txt" \
    MOCK_STDERR_FIRST=1 \
    MOCK_DELAY_AFTER_STDERR=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
stderr_line_number=$(echo "$output" | grep -n "early diagnostic" | head -1 | cut -d: -f1)
completion_line_number=$(echo "$output" | grep -n "hello world" | head -1 | cut -d: -f1)
if [[ -n "$stderr_line_number" && -n "$completion_line_number" && "$stderr_line_number" -lt "$completion_line_number" ]]; then
    pass "stderr streamed before later Bob stdout"
else
    fail "stderr remained buffered until Bob stdout completed" "got: $output"
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

# a silent non-zero exit still needs an actionable progress-log diagnostic.
set +e
silent_failure_output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/empty_stdout.txt" \
    MOCK_EXIT_CODE=9 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
silent_failure_exit=$?
set -e
if echo "$silent_failure_output" | grep -q "error: bob exited with status 9 after .* without diagnostic output"; then
    pass "silent non-zero Bob exit gains synthetic diagnostic"
else
    fail "silent non-zero Bob exit lacks diagnostic" "got: $silent_failure_output"
fi
if [[ $silent_failure_exit -eq 9 ]]; then
    pass "silent Bob failure preserves exit code"
else
    fail "silent Bob failure exit code changed" "got: $silent_failure_exit"
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
# the wrapper's own format setting replaces any ralphex one: v2 takes -f, and the
# removed v1 --output-format must never reach bob even when ralphex passes it.
if echo "$recorded" | grep -c -- "-f stream-json" | grep -q "^1$" &&
    ! echo "$recorded" | grep -q -- "--output-format"; then
    pass "exactly one -f stream-json and no --output-format in bob args"
else
    fail "unexpected format flags" "args: $recorded"
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
# test: trailing newline edge case — assistant message without trailing newline
# ---------------------------------------------------------------------------
echo "test: assistant message without trailing newline"

cat > "$TMPDIR_TEST/no_trailing_newline.jsonl" << 'EOF'
{"type":"message","timestamp":"t","role":"assistant","content":"line one\nline two","isReasoning":false}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/no_trailing_newline.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

line_one=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line one\n") | .delta.text' 2>/dev/null)
# the trailing partial line is forwarded verbatim: bob's message had no trailing
# newline, so the wrapper must not synthesize one.
line_two=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line two") | .delta.text' 2>/dev/null)
if [[ -n "$line_one" && -n "$line_two" ]]; then
    pass "assistant message without trailing newline preserves last line"
else
    fail "last line lost when assistant message lacks trailing newline" "got: $output"
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
# test: the wrapper does not inspect bob's approval settings
#
# tool access in headless `bob run` comes from the mode's `groups` list plus
# `--trust`. The approval.* block in bob's settings.json is read only by the
# interactive approval handler, which `bob run` never constructs, so the wrapper
# must not warn about it — a warning there fires on every default install and
# points at a setting that changes nothing for a headless run.
# ---------------------------------------------------------------------------
echo "test: no approval preflight"

preflight_home="$TMPDIR_TEST/preflight-home"
mkdir -p "$preflight_home/.bob/settings"
# bob's own read-only default shape: nothing here grants edit or execute.
printf '%s\n' '{"approval":{"allowed_permissions":["read"],"autoApprovalEnabled":false}}' \
    > "$preflight_home/.bob/settings/settings.json"

run_wrapper_with_home() {
    local prompt="${1:-test prompt}"
    rm -f "$TMPDIR_TEST/bob_args"
    preflight_rc=0
    preflight_err=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
        HOME="$preflight_home" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "$prompt" 2>&1 >/dev/null) ||
        preflight_rc=$?
}

for preflight_prompt_label in task review; do
    if [[ "$preflight_prompt_label" == "review" ]]; then
        run_wrapper_with_home '## Step 2: Launch ALL 5 Review Agents IN PARALLEL'
    else
        run_wrapper_with_home 'test prompt'
    fi
    if [[ "$preflight_rc" -eq 0 && -f "$TMPDIR_TEST/bob_args" ]]; then
        pass "$preflight_prompt_label prompt runs against read-only bob settings"
    else
        fail "$preflight_prompt_label prompt aborted on read-only bob settings" \
            "rc: $preflight_rc stderr: $preflight_err"
    fi
    if echo "$preflight_err" | grep -qi "approval"; then
        fail "$preflight_prompt_label prompt warned about approvals" \
            "stderr: $preflight_err"
    else
        pass "$preflight_prompt_label prompt emits no approval warning"
    fi
    if echo "$preflight_err" | grep -qF "install-modes.sh --grant-approvals"; then
        fail "$preflight_prompt_label prompt still points at --grant-approvals" \
            "stderr: $preflight_err"
    else
        pass "$preflight_prompt_label prompt does not point at --grant-approvals"
    fi
done

# HOME is not needed by the wrapper at all; a sanitized parent env must not trip
# `set -u` or produce a diagnostic about bob's settings path.
rm -f "$TMPDIR_TEST/bob_args"
nohome_rc=0
nohome_err=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    env -u HOME bash "$WRAPPER" -p "test prompt" 2>&1 >/dev/null) ||
    nohome_rc=$?
if [[ $nohome_rc -eq 0 && -f "$TMPDIR_TEST/bob_args" ]]; then
    pass "wrapper runs with HOME unset"
else
    fail "wrapper aborted with HOME unset" "rc: $nohome_rc stderr: $nohome_err"
fi
if echo "$nohome_err" | grep -qi "BOB_SETTINGS_FILE\|settings.json"; then
    fail "wrapper still reports a bob settings path with HOME unset" \
        "stderr: $nohome_err"
else
    pass "wrapper reports no settings path with HOME unset"
fi

# the wrapper is read-only with respect to bob's home.
if [[ ! -e "$preflight_home/.bob/custom_modes.yaml" &&
    ! -e "$preflight_home/.bob/settings/custom_modes.yaml" ]]; then
    pass "wrapper writes nothing into the temporary bob home"
else
    fail "wrapper wrote into the temporary bob home"
fi
if [[ "$(cat "$preflight_home/.bob/settings/settings.json")" == \
    '{"approval":{"allowed_permissions":["read"],"autoApprovalEnabled":false}}' ]]; then
    pass "wrapper leaves bob settings.json untouched"
else
    fail "wrapper modified bob settings.json"
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
# test: the installer does not touch bob's approval settings
#
# the removed --grant-approvals flag wrote approval.* into settings.json, which
# only bob's interactive approval handler reads. Granting it changed nothing for
# a headless `bob run` while silently disabling approval prompts in the user's
# interactive sessions, so the flag must stay rejected as an unknown argument.
# ---------------------------------------------------------------------------
echo "test: installer leaves approval settings alone"

approval_root="$TMPDIR_TEST/approval-installer"
mkdir -p "$approval_root"

run_installer_isolated() {
    local case_dir="$1"
    shift
    mkdir -p "$case_dir"
    HOME="$case_dir" \
        BOB_CUSTOM_MODES_FILE="$case_dir/custom_modes.yaml" \
        bash "$SCRIPT_DIR/install-modes.sh" "$@" 2>&1
}

grant_dir="$approval_root/grant-flag"
grant_exit=0
grant_output=$(run_installer_isolated "$grant_dir" --grant-approvals) || grant_exit=$?
if [[ "$grant_exit" -ne 0 ]] &&
    echo "$grant_output" | grep -qF "unknown argument: --grant-approvals"; then
    pass "installer rejects --grant-approvals as an unknown argument"
else
    fail "installer accepted --grant-approvals" \
        "exit: $grant_exit; output: $grant_output"
fi
if [[ ! -e "$grant_dir/custom_modes.yaml" ]]; then
    pass "rejected argument installs no modes"
else
    fail "installer wrote modes despite a rejected argument"
fi

# a default run must install modes and still leave settings.json alone.
default_dir="$approval_root/default"
mkdir -p "$default_dir/.bob/settings"
default_settings="$default_dir/.bob/settings/settings.json"
printf '%s\n' '{"approval":{"allowed_permissions":["read"],"autoApprovalEnabled":false}}' \
    > "$default_settings"
default_before=$(cat "$default_settings")
run_installer_isolated "$default_dir" >/dev/null
if [[ -s "$default_dir/custom_modes.yaml" ]]; then
    pass "default installer run installs the modes"
else
    fail "default installer run did not install the modes"
fi
if [[ "$(cat "$default_settings")" == "$default_before" ]]; then
    pass "default installer run leaves settings.json untouched"
else
    fail "default installer run modified settings.json" \
        "after: $(cat "$default_settings")"
fi
if [[ ! -e "$default_settings.bak" ]]; then
    pass "default installer run writes no settings backup"
else
    fail "default installer run created a settings backup"
fi

# the installer must not reference the removed grant path anywhere.
if ! grep -qF -- "--grant-approvals" "$SCRIPT_DIR/install-modes.sh"; then
    pass "installer source has no --grant-approvals handling left"
else
    fail "installer source still handles --grant-approvals"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
suite_completed=1
echo ""
echo "results: $passed passed, $failed failed, $total total"

if [[ $failed -gt 0 ]]; then
    exit 1
fi
