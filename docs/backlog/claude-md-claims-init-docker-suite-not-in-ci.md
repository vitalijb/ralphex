---
worth: yes
where: CLAUDE.md
added: 2026-09-14
---
# CLAUDE.md says no CI job runs the init-docker suite, but ci.yml does

CLAUDE.md:157 (section "CLI Refresh at Container Start") states that `scripts/internal/init-docker_test.sh`
is run by hand only and "no CI job or make target invokes it". `.github/workflows/ci.yml:37` runs it as the
"test container init script" step. The CI step is from 51f0d25 (2026-07-17); the sentence was written the
next day in ed0a87f and was wrong when written. An agent editing `scripts/internal/init-docker.sh` reads
this as fact and either hand-runs a suite CI already gates or adds a duplicate CI job.

Fix: replace the clause with a statement that ci.yml runs the suite as the "test container init script"
step, keeping the by-hand command as the local invocation. Surfaced reviewing PR #458.
