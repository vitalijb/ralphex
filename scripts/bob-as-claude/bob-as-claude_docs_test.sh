#!/usr/bin/env bash
# bob-as-claude_docs_test.sh — validates bob wrapper documentation and repo integration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

assert_contains() {
    local file="$1"
    local needle="$2"
    local label="$3"

    if grep -Fq -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label" "missing '$needle' in $file"
    fi
}

assert_matches() {
    local file="$1"
    local regex="$2"
    local label="$3"

    if grep -Eq -- "$regex" "$file"; then
        pass "$label"
    else
        fail "$label" "no line matching '$regex' in $file"
    fi
}

assert_executable() {
    local file="$1"
    local label="$2"

    if [[ -x "$file" ]]; then
        pass "$label"
    else
        fail "$label" "$file is not executable"
    fi
}

echo "running bob-as-claude docs tests"
echo ""

assert_executable "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude.sh" "wrapper script is executable"
assert_executable "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" "wrapper shell test is executable"

# wrapper README
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh" \
    "wrapper README contains config snippet"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_VERBOSE" \
    "wrapper README documents BOB_VERBOSE env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_CHAT_MODE" \
    "wrapper README documents BOB_CHAT_MODE env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_MODEL" \
    "wrapper README documents BOB_MODEL env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_EXTRA_ARGS" \
    "wrapper README documents BOB_EXTRA_ARGS env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "bash scripts/bob-as-claude/bob-as-claude_test.sh" \
    "wrapper README includes wrapper test command"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "## Limitations" \
    "wrapper README includes Limitations section"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "## Security considerations" \
    "wrapper README includes Security considerations section"

# custom providers doc
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "## IBM Bob Shell CLI wrapper (included example)" \
    "custom providers doc includes bob section"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "custom providers doc references bob wrapper path"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "attempt_completion" \
    "custom providers doc documents bob event translation"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "### Chat modes" \
    "custom providers doc documents bob chat-mode mapping"

# top-level README
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "top-level README mentions bob wrapper"
# anchor on the stable facts (bob + jq on one line), not exact prose
assert_matches \
    "$REPO_ROOT/README.md" \
    "bob wrappers.*\`jq\`" \
    "top-level README documents jq requirement for bob wrapper"
assert_contains \
    "$REPO_ROOT/README.md" \
    "BOB_CHAT_MODE" \
    "top-level README documents bob-specific environment variables"
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/" \
    "top-level README requirements list mentions bob wrapper dir"

# llms.txt
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "llms.txt wrapper inventory mentions bob wrapper"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/" \
    "llms.txt requirements list mentions bob wrapper dir"

# CLAUDE.md
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/ # IBM Bob Shell CLI wrapper for Claude-compatible output" \
    "CLAUDE inventory includes bob wrapper directory"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "CLAUDE alternative provider docs mention bob wrapper path"

echo ""
echo "summary: $passed passed, $failed failed, $total total"

if [[ $failed -ne 0 ]]; then
    exit 1
fi