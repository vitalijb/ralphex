# Add Per-Phase Custom Modes to bob-as-claude

## Overview

Enhance the IBM Bob wrapper with installable ralphex-specific task, review, and plan modes. The wrapper will select the appropriate mode from strict prompt markers, preserve explicit `BOB_CHAT_MODE` overrides, and stop mutating review prompts. Documentation and mock-based regression coverage will be updated without changing Go code or making real API calls.

## Context

- Files involved:
  - Modify: `scripts/bob-as-claude/bob-as-claude.sh`
  - Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`
  - Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`
  - Modify: `scripts/bob-as-claude/README.md`
  - Create: `scripts/bob-as-claude/install-modes.sh`
  - Create: `scripts/bob-as-claude/modes/ralphex-task.yaml`
  - Create: `scripts/bob-as-claude/modes/ralphex-review.yaml`
  - Create: `scripts/bob-as-claude/modes/ralphex-plan.yaml`
  - Modify: `docs/custom-providers.md`
  - Modify: `README.md`
  - Modify: `llms.txt`
  - Modify: `CLAUDE.md`
- Existing review findings:
  - `BOB_CHAT_MODE` is restricted to four built-in values, preventing valid custom-mode slug overrides.
  - One default mode is used for every phase, while plan creation remains documented as untested.
  - Sequential review instructions are injected into every detected review prompt instead of residing in a Bob mode.
  - `CLAUDE.md` incorrectly describes `REVIEW_DONE` as the adapter trigger, while the wrapper actually uses review start markers.
  - Bob documentation contains long options with separated values instead of the project's required `--flag=value` form.
  - Existing Bob scripts contain uppercase prose in comments that should be normalized where touched.
- Related patterns:
  - Preserve the Pi-inspired stdin delivery, private temporary directory, FIFO streaming, signal forwarding, keepalive events, stderr neutralization, and exit-code handling.
  - Reuse the wrapper's fence-aware review-marker detection for phase classification.
  - Task and finalize prompts default to `ralphex-task`; strict review start markers select `ralphex-review`; the complete plan-creation signal set selects `ralphex-plan`.
  - Explicit non-empty `BOB_CHAT_MODE` always wins and may name either a built-in or user-defined custom mode.
  - Existing wrapper and documentation tests currently pass with 80 and 22 assertions respectively.
- Dependencies:
  - Follow the official [IBM Bob custom-mode schema](https://bob.ibm.com/docs/shell/configuration/custom-modes-bobshell).
  - Use the repository's vendored `gopkg.in/yaml.v3` when syntactic YAML parsing is needed in tests; add no runtime dependency.
  - No Go source changes and no real Bob/API calls.

## Development Approach

- **Testing approach**: Regular, with focused regression tests added alongside each change and a final test-hardening pass.
- Keep the wrapper as one Bash script; place only declarative mode files and the installer beside it.
- Preserve unrelated user modes during installation and make repeated installation idempotent.
- Do not silently fall back to built-in modes when the shipped modes have not been installed; document installation clearly.
- Use isolated temporary `HOME` directories and the existing mock Bob in all tests.
- Complete each task fully and pass its tests before moving to the next.
- Use the requested conventional commit messages and do not push.

## Implementation Steps

### Task 1: Implement custom modes, installation, and phase selection

**Files:**

- Modify: `scripts/bob-as-claude/bob-as-claude.sh`
- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`
- Create: `scripts/bob-as-claude/install-modes.sh`
- Create: `scripts/bob-as-claude/modes/ralphex-task.yaml`
- Create: `scripts/bob-as-claude/modes/ralphex-review.yaml`
- Create: `scripts/bob-as-claude/modes/ralphex-plan.yaml`

- [x] define `ralphex-task` with `read`, `edit`, `command`, and `browser` groups, a one-task-at-a-time implementation role, commit guidance, and interactive `whenToUse` guidance
- [x] define `ralphex-review` with `read`, `edit`, `command`, and `browser` groups and move the complete sequential-agent, finding verification, fix, test, commit, and ralphex signal guidance into `customInstructions`
- [x] define `ralphex-plan` with only `read`, `command`, and `browser` groups, planning-specific role and selection guidance, and instructions that prevent source edits while retaining the prompt-driven plan-file workflow
- [x] add an executable installer that creates `~/.bob/custom_modes.yaml` when absent, preserves unrelated existing modes, appends missing shipped slugs, skips existing slugs as user-owned overrides, and produces no duplicates on repeated runs
- [x] make installer updates atomic and fail without changing the target when the existing document cannot be merged safely
- [x] replace built-in-only `BOB_CHAT_MODE` validation with explicit override passthrough so arbitrary Bob custom-mode slugs are supported
- [x] add fence-aware phase classification with precedence `BOB_CHAT_MODE` override, review start markers, complete plan-creation signal markers, then task/finalize default
- [x] pass the selected mode as `--chat-mode=<slug>`, remove review-adapter prompt prepending, and preserve original prompt content
- [x] normalize comments touched in the wrapper and tests to the repository's lowercase-comment convention
- [x] add focused mock tests for default task/finalize selection, both review-pass markers, plan signal detection, fenced-marker false positives, arbitrary explicit overrides, and unchanged prompt delivery
- [x] add isolated installer tests for create, merge, existing-slug preservation, idempotence, and safe failure behavior
- [x] run `bash scripts/bob-as-claude/bob-as-claude_test.sh` and resolve all failures
- [x] commit the feature as `feat(bob-as-claude): add per-phase custom bob modes`

### Task 2: Document custom-mode installation and phase mapping

**Files:**

- Modify: `scripts/bob-as-claude/README.md`
- Modify: `docs/custom-providers.md`
- Modify: `README.md`
- Modify: `llms.txt`
- Modify: `CLAUDE.md`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [x] document the three shipped modes, exact tool groups, installer command, safe merge behavior, existing-slug precedence, and the requirement to install modes before automatic selection
- [x] document the mapping from review and plan prompt markers to custom modes, with task and finalize using `ralphex-task`
- [x] document `BOB_CHAT_MODE` as an unrestricted explicit override that preserves built-in-mode compatibility
- [x] replace review-adapter and "plan creation untested" descriptions with the new mode-driven behavior
- [x] update top-level inventories and project conventions for the new `modes/` directory and `install-modes.sh`
- [x] correct the stale review-trigger description in `CLAUDE.md`
- [x] normalize Bob command examples to `--flag=value` form, including chat-mode and extra-argument examples
- [x] extend documentation tests to require the executable installer, all three mode files, installation instructions, phase mapping, override behavior, and updated repository inventories
- [x] run both Bob shell test scripts and resolve all failures
- [x] commit the documentation as `docs(bob-as-claude): document custom modes and phase mapping`

### Task 3: Harden regression coverage and verify acceptance criteria

**Files:**

- Modify: `scripts/bob-as-claude/bob-as-claude_test.sh`
- Modify: `scripts/bob-as-claude/bob-as-claude_docs_test.sh`

- [x] parse every shipped and installer-produced YAML document with a temporary validator using vendored `gopkg.in/yaml.v3`
- [x] assert unique slugs, required schema fields, exact tool-group allow-lists, plan-mode exclusion of `edit`, and review-mode inclusion of sequential review and signal instructions
- [x] complete the phase-detection matrix, including review precedence, individual plan-signal false positives, fenced markers, built-in overrides, arbitrary custom overrides, and task/finalize fallback
- [x] verify installer behavior with absent configuration, unrelated modes, partially installed ralphex modes, repeated installation, malformed input, paths containing spaces, and an isolated `HOME`
- [x] verify all tests continue using mock Bob and make no real API calls
- [x] run `bash scripts/bob-as-claude/bob-as-claude_test.sh` with zero failures
- [x] run `bash scripts/bob-as-claude/bob-as-claude_docs_test.sh` with zero failures
- [x] run `make test` and confirm repository coverage remains at least 80%
- [x] run `make lint` and resolve all reported issues
- [x] verify the working tree contains no unrelated changes and no push was performed
- [x] commit the test work as `test(bob-as-claude): add custom mode tests`
