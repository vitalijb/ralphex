---
worth: later
where: cmd/ralphex/main.go:945
added: 2026-08-22
---
# a finished worktree run archives the unticked plan, so the dashboard reports 0 done

Under `--worktree` the run ticks the plan copy inside the worktree and commits it on the feature branch.
The main-checkout copy is never touched. At the end of the run `archivePlan` prefers `MainGitSvc` and
`MainPlanFile` (`cmd/ralphex/main.go:945-947`), so `MovePlanToCompleted` moves that untouched copy into
`docs/plans/completed/` and commits it on the main checkout's branch. The archived plan therefore records
zero completed tasks for a run that finished every one of them.

The dashboard follows it there. #442 added a `Worktree plan:` header line so `handleSessionPlan` serves the
copy the run actually ticks, but the worktree is removed at the end of the run, so the path stops
resolving, the handler falls back to `Plan:`, and `loadPlanWithFallback` finds the unticked copy under
`completed/`. A finished worktree session in a watch-mode dashboard reads 0 of N done, permanently. This is
the remaining half of issue #440, which was closed once the during-run case was fixed.

Two candidate fixes, and they differ in lifetime rather than difficulty:

- **snapshot** the ticked copy under `.ralphex/progress` before `RemoveWorktree`, and point the header at
  it. That directory is already ignored runtime data owned by the progress log, so it is not the
  tracked-main-checkout boundary that produced #435 and #437. The snapshot is immutable and stays tied to
  the session that produced it. Costs an artifact and a retention policy.
- **read it back from the branch**, which already carries the ticked plan in every task commit. Smaller,
  but a branch advances, gets renamed, and is deleted after merge, so a historical session would either
  change under the reader or break. It also holds only committed state, while cleanup after a failure or
  SIGINT can discard newer uncommitted ticks. Doing it soundly means recording a commit SHA and repository
  identity in the header, since `pkg/web` has no `GitSvc`, no recorded `vcs_command` and no repo root, and
  it would have to duplicate the original/completed/alternate-name probing that `loadPlanWithFallback`
  already does.

The snapshot is the better durable answer; the branch is only the smaller one under a weaker contract.
Deferred because the choice is a product decision about how long a finished session stays readable, not a
patch. Surfaced fixing #440, and argued through with codex.
