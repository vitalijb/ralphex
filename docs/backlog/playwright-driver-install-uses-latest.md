---
worth: yes
where: Makefile:e2e-setup
added: 2026-09-14
---
# playwright driver install uses @latest and drifts from the vendored client

`make e2e-setup` (Makefile:37), the manual e2e workflow (.github/workflows/e2e.yml:26) and the CLAUDE.md
example (CLAUDE.md:389) all install the Playwright driver with `go run .../cmd/playwright@latest`. The
vendored client is pinned to `github.com/mxschmitt/playwright-go v0.6201.1`, which requires driver 1.62.1
(vendor/github.com/mxschmitt/playwright-go/run.go:22). Once upstream publishes a newer release, `@latest`
installs a newer driver and the tests fail with `please install the driver (v1.62.1) first` after an
install step that looked successful. The Makefile additionally still uses the old module path
`github.com/playwright-community/playwright-go`, which PR #434 (f5a4557) replaced in the workflow and in
CLAUDE.md but not here; that path resolves to no release newer than v0.6000.0.

Fix in all three places:

```
go run -mod=mod github.com/mxschmitt/playwright-go/cmd/playwright install --with-deps chromium
```

Dropping `@latest` makes `go run` resolve the version from go.mod, so the driver follows the client
automatically. `-mod=mod` is required because `cmd/playwright` is not in the vendor tree and the default
vendor mode cannot resolve it. Checked in a scratch copy of go.mod/go.sum: resolves to v0.6201.1 and does
not modify go.sum. Surfaced reviewing PR #458.
