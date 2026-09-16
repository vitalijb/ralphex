---
worth: yes
where: .github/workflows/ci.yml
added: 2026-09-14
---
# CI never compiles the e2e-tagged package

Every file under `e2e/` carries `//go:build e2e`, `go test ./...` in ci.yml:30 skips them, and
`.github/workflows/e2e.yml` is `workflow_dispatch` only. Nothing in CI passes `-tags=e2e`, so a
dependency bump that breaks the e2e package merges green and the breakage surfaces on the next manual
dispatch. This already happened once: f5a4557 (#434) had to repair e2e/ as part of a dependency refresh.

Fix: add a compile-only step next to the test step in ci.yml:

```
go vet -tags=e2e ./e2e/...
```

It takes seconds, needs no browsers, and passes on master today. Do not promote the e2e run itself into
CI; that was made manual on purpose (5aa24f9). Surfaced reviewing PR #458.
