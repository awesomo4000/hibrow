///! Small cross-platform OS primitives, kept in one place so the rest of the
///! codebase never branches on the operating system. Each function has a POSIX
///! arm (macOS/Linux — unchanged from the original raw-syscall code) and a
///! Windows arm. Heavier Windows logic (process discovery, registry lookup)
///! lives in os_windows.zig; this file holds only the little primitives.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const is_windows = builtin.os.tag == .windows;

const Stream = std.Io.net.Stream;

/// Portable process identifier. `posix.pid_t` is an i32; Windows PIDs are
/// DWORDs. A process id is always a small non-negative integer, so u32 holds
/// either and serializes straight to JSON. We never expose `posix.pid_t`
/// publicly because on Windows it is a HANDLE (a pointer), not a number.
pub const Pid = u32;

/// Value for `std.process.SpawnOptions.pgid` that starts the child in its own
/// process group (detached from ours). Windows has no equivalent, so leave it
/// null there.
pub const new_process_group: ?posix.pid_t = switch (builtin.os.tag) {
    .windows => null,
    else => 0,
};

/// Win32 functions we call directly. Declared here (rather than relying on a
/// particular std layout) and only referenced on Windows, so the externs are
/// never pulled in on POSIX.
const win = if (is_windows) struct {
    const w = std.os.windows;
    extern "kernel32" fn Sleep(dwMilliseconds: w.DWORD) callconv(.winapi) void;
    extern "kernel32" fn GetProcessId(Process: w.HANDLE) callconv(.winapi) w.DWORD;
} else struct {};

/// Numeric PID of a spawned child. On POSIX `child.id` is already the pid; on
/// Windows it is a process HANDLE, so ask the OS for its id.
pub fn childPid(child: std.process.Child) Pid {
    const id = child.id.?;
    if (is_windows) return @intCast(win.GetProcessId(id));
    return @intCast(id);
}

var rng_state: std.Random.DefaultPrng = undefined;
var rng_ready = false;

/// Fill `buf` with pseudo-random bytes. Used only for WebSocket masking keys,
/// which must merely vary, not be cryptographically strong (the peer is a local
/// browser). 0.17 removed the OS-seeded `std.crypto.random`, so seed a PRNG from
/// the clock once. Not thread-safe; hibrow's socket I/O is single-threaded.
pub fn randomBytes(buf: []u8) void {
    if (!rng_ready) {
        // Seed from address entropy (ASLR varies these per run); 0.17's clock
        // needs an Io we do not have here, and masking keys only need to vary.
        const seed: u64 = @intFromPtr(&rng_state) ^ @intFromPtr(buf.ptr);
        rng_state = std.Random.DefaultPrng.init(seed);
        rng_ready = true;
    }
    rng_state.random().bytes(buf);
}

/// Read an environment variable and dupe its value; null if unset. Uses libc
/// getenv so env access does not have to be threaded through every caller.
pub fn envOwned(allocator: std.mem.Allocator, name: [*:0]const u8) !?[]u8 {
    const val = std.c.getenv(name) orelse return null;
    return try allocator.dupe(u8, std.mem.span(val));
}

/// Per-user runtime directory holding the gateway socket and pid file.
/// POSIX: /tmp/hibrow-{uid}. Windows: %LOCALAPPDATA%\hibrow (per-user, always
/// present). Caller owns the returned path.
pub fn runtimeDir(allocator: std.mem.Allocator) ![]u8 {
    if (is_windows) {
        if (try envOwned(allocator, "LOCALAPPDATA")) |base| {
            defer allocator.free(base);
            return std.fmt.allocPrint(allocator, "{s}\\hibrow", .{base});
        }
        return allocator.dupe(u8, "C:\\Windows\\Temp\\hibrow");
    }
    const uid = std.c.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/hibrow-{d}", .{uid});
}

/// Current process id.
pub fn getpid() Pid {
    if (is_windows) return @intCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.c.getpid());
}

/// Sleep for the given number of milliseconds.
pub fn sleepMs(ms: u64) void {
    if (is_windows) {
        win.Sleep(@intCast(ms));
        return;
    }
    const ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Blocking read of up to `buf.len` bytes from a connected socket.
///
/// POSIX reads the fd directly: the Io backend hands us blocking sockets, so a
/// raw `read` matches the stream semantics the callers manage by hand. Windows
/// exposes no public raw socket syscall, so it goes through the Io vtable (the
/// low-level `Stream.read`, which does not buffer, so callers keep owning any
/// leftover bytes just as with the POSIX path).
pub fn sockRead(io: std.Io, stream: Stream, buf: []u8) !usize {
    if (is_windows) {
        // Stream.read's low-level destructure is miscompiled on Windows in
        // 0.17; readWithControl returns a uniform ReadResult on all platforms.
        // data_len == 0 means EOF, matching posix.read's 0 return.
        var iov = [_][]u8{buf};
        const res = try stream.readWithControl(io, &iov, &[_]u8{});
        return res.data_len;
    }
    return posix.read(stream.socket.handle, buf);
}

/// Write all `bytes` to a connected socket, looping over partial writes.
pub fn sockWriteAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    if (is_windows) {
        var wbuf: [16 * 1024]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        return;
    }
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(stream.socket.handle, bytes[i..].ptr, bytes.len - i);
        if (rc <= 0) return error.WriteFailed;
        i += @intCast(rc);
    }
}
