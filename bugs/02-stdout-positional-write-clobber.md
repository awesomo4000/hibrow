# hibrow bugs

## BUG-002: stdout/stderr clobbered when redirected to a file (positional writes)

**Date:** 09/30/2026
**Severity:** High — silently drops command output
**Status:** Fixed
**Affected commands:** all (any command that prints via `writeStdout`/`writeStderr`)

### Symptom

When hibrow output is redirected to a regular file, output goes missing. Each
write lands back at the start of the file and overwrites what came before, so
only a fragment survives:

```bash
hibrow ls > out.txt        # out.txt is truncated / partially overwritten
hibrow eval work "..." >> log.txt   # append is defeated too
```

Piping to a terminal or another process looked fine, which is why this hid for
a while.

### Root cause

`main.zig` built its writers with `File.stdout().writer(&buf)`. In Zig 0.15.2,
`File.writer()` initializes the `File.Writer` in **positional mode** (`mode =
.positional`, `pos = 0`) and drains with `pwritev(handle, iovecs, pos)` — a
positioned write at an explicit offset (see `std/fs/File.zig`).

Two consequences:

1. Each `writeStdout` call constructs a *fresh* writer with `pos = 0`, so every
   write — even multiple prints within a single command — targets byte 0.
2. `pwrite` writes at the explicit offset and ignores `O_APPEND`, so even `>>`
   redirection is clobbered.

When stdout is a tty or pipe, `pwritev` returns `error.Unseekable` and the
writer transparently downgrades to streaming mode (`writev`), which appends at
the kernel file offset — hence the bug only showed up for regular files.

### Fix

Use `writerStreaming(&buf)` instead of `writer(&buf)`. This initializes the
writer in **streaming mode** (`writev`/`write`), which honors the kernel file
offset and `O_APPEND`, so sequential writes append correctly to files, pipes,
and terminals alike.

```zig
// Before:
var stdout_writer = std.fs.File.stdout().writer(&buf);
// After:
var stdout_writer = std.fs.File.stdout().writerStreaming(&buf);
```

Applied to both `writeStdout` and `writeStderr` in `main.zig`. Verified: a
redirected `hibrow --help > file` now captures the full output byte-for-byte.

`gateway.zig`'s `writePidFile` still uses `file.writer()`, which is fine — it is
a single write to a freshly truncated file, where positional-at-0 is correct.
