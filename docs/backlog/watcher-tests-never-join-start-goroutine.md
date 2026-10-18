---
worth: later
where: pkg/web/watcher_test.go:TestWatcher_ResumesStreamingAfterFlockRace
added: 2026-09-14
---
# watcher tests never join the Start goroutine before closing the manager

Twelve tests in `pkg/web/watcher_test.go` run `go func() { _ = w.Start(ctx) }()` with `ctx := t.Context()`
and never wait for `Start` to return. `t.Context()` is canceled just before cleanups run, but cancellation
is not a join: `Watcher.run` selects between `ctx.Done()` and the fsnotify event channel, so an event still
queued or still inside `handleProgressFileChange` when the test body returns can run after the
`t.Cleanup(func() { sm.Close() })` added in #459 has emptied the manager. `Discover` then registers a new
session, or a handler holding a `Session` pointer from before `Close` calls `Reactivate` on it (Session has
no closed flag), and the new tailer holds the progress file open with nothing left to stop it. On Windows
that fails `t.TempDir` removal after testing's 2s retry; on Linux and macOS it is a leaked goroutine.

#459 turned this from a certain Windows failure into a narrow window: it needs a late second write event for
one `OpenFile+WriteString+Close`, and most tests sleep after their last write, which makes it unlikely without
being a barrier. `TestWatcher_ResumesStreamingAfterFlockRace` returns straight off `assert.Eventually` with
no trailing sleep, so it is the most exposed.

Fix: a `startWatcher(t, w, sm)` helper owning the context, a done channel for `Start`, and cleanups registered
so the join runs before `sm.Close`. `Start` also spawns `refreshLoop` on its own; `RefreshStates` cannot create
a tailer, but a helper promising full shutdown should wait for it too. Deferred because the edit repeats
across twelve tests and there is no Windows runner to observe either the flake or the fix.
