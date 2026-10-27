///! Platform-specific process enumeration for discovering Chrome browsers.
///!
///! On macOS, uses proc_listpids + sysctl(KERN_PROCARGS2) to find Chrome
///! processes and parse --remote-debugging-port and --user-data-dir from
///! their command-line arguments. This is how `ps` works — zero files,
///! zero port scanning, fully stateless.
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const builtin = @import("builtin");
const browser_mod = @import("browser.zig");
const os = @import("os.zig");
const os_windows = @import("os_windows.zig");

/// A discovered Chrome process with its CDP port and profile info.
pub const DiscoveredProcess = struct {
    pid: os.Pid,
    /// CDP debugging port (Chrome) or Marionette port (Firefox).
    port: u16,
    /// Profile name (basename of profile/user-data-dir path).
    profile: []const u8,
    /// Full profile directory path.
    user_data_dir: []const u8,
    /// Browser engine type.
    browser_type: browser_mod.BrowserType = .chrome,
};

/// Find all Chrome processes with --remote-debugging-port in their args.
/// Caller owns the returned slice and all strings within it.
/// Free with freeDiscovered().
pub fn findChromeBrowsers(allocator: mem.Allocator, io: std.Io) ![]DiscoveredProcess {
    switch (comptime builtin.os.tag) {
        .macos, .linux => return findBrowsersScan(allocator, io),
        .windows => return os_windows.findBrowsers(allocator, io),
        else => return &[_]DiscoveredProcess{},
    }
}

/// Free a slice returned by findChromeBrowsers().
pub fn freeDiscovered(allocator: mem.Allocator, procs: []DiscoveredProcess) void {
    for (procs) |p| {
        allocator.free(p.user_data_dir);
        // profile is a sub-slice of user_data_dir or separately allocated
        // Actually profile is extracted via basename which returns a slice into
        // user_data_dir, so we must NOT free it. But if user_data_dir is empty
        // and profile was separately allocated, we need to handle that.
        // Our implementation always makes profile a slice into user_data_dir,
        // so only free user_data_dir.
    }
    allocator.free(procs);
}

// ===========================================================================
// macOS implementation
// ===========================================================================

// libproc / sysctl constants and extern declarations.
// These live in libSystem which Zig links automatically on macOS.

const PROC_ALL_PIDS: u32 = 1;

extern "c" fn proc_listpids(
    @"type": u32,
    typeinfo: u32,
    buffer: ?[*]u8,
    buffersize: c_int,
) c_int;

// sysctl constants
const CTL_KERN: c_int = 1;
const KERN_PROCARGS2: c_int = 49;

fn findBrowsersScan(allocator: mem.Allocator, io: std.Io) ![]DiscoveredProcess {
    // Step 1: Get list of all PIDs
    const pids = try listAllPids(allocator, io);
    defer allocator.free(pids);

    var results: std.ArrayList(DiscoveredProcess) = .empty;
    errdefer {
        for (results.items) |p| allocator.free(p.user_data_dir);
        results.deinit(allocator);
    }

    // Step 2: For each PID, try to read its command-line args
    for (pids) |pid| {
        if (pid <= 0) continue;

        const parsed = getProcArgs(allocator, io, pid) catch continue;
        defer allocator.free(parsed.raw_buf);
        defer allocator.free(parsed.argv);

        // Check for Chrome: --remote-debugging-port= and --user-data-dir=
        var cdp_port: ?u16 = null;
        var user_data_dir: ?[]const u8 = null;
        // Check for Firefox: --marionette and --profile <dir>
        var has_marionette = false;
        var profile_dir: ?[]const u8 = null;

        var i: usize = 0;
        while (i < parsed.argv.len) : (i += 1) {
            const arg = parsed.argv[i];
            if (mem.startsWith(u8, arg, "--remote-debugging-port=")) {
                const val = arg["--remote-debugging-port=".len..];
                cdp_port = std.fmt.parseInt(u16, val, 10) catch null;
            } else if (mem.startsWith(u8, arg, "--user-data-dir=")) {
                user_data_dir = arg["--user-data-dir=".len..];
            } else if (mem.eql(u8, arg, "--marionette")) {
                has_marionette = true;
            } else if (mem.eql(u8, arg, "--profile")) {
                // --profile <dir> (next arg is the directory)
                if (i + 1 < parsed.argv.len) {
                    i += 1;
                    profile_dir = parsed.argv[i];
                }
            }
        }

        // Chrome: has debugging port and user-data-dir
        if (cdp_port) |p| {
            if (user_data_dir) |udd| {
                const udd_owned = try allocator.dupe(u8, udd);
                errdefer allocator.free(udd_owned);
                const profile = std.fs.path.basename(udd_owned);
                try results.append(allocator, .{
                    .pid = @intCast(pid),
                    .port = p,
                    .profile = profile,
                    .user_data_dir = udd_owned,
                    .browser_type = .chrome,
                });
            }
        }

        // Firefox: has --marionette and --profile
        if (has_marionette) {
            if (profile_dir) |pdir| {
                const pdir_owned = try allocator.dupe(u8, pdir);
                errdefer allocator.free(pdir_owned);
                const profile = std.fs.path.basename(pdir_owned);

                // Read marionette port from user.js in profile dir
                const m_port = readMarionettePort(allocator, io, pdir_owned) catch null;
                if (m_port) |port| {
                    try results.append(allocator, .{
                        .pid = @intCast(pid),
                        .port = port,
                        .profile = profile,
                        .user_data_dir = pdir_owned,
                        .browser_type = .firefox,
                    });
                } else {
                    allocator.free(pdir_owned);
                }
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Read the marionette.port value from a Firefox profile's user.js.
/// Parses the line: user_pref("marionette.port", NNNN);
fn readMarionettePort(allocator: mem.Allocator, io: std.Io, profile_dir: []const u8) !?u16 {
    const prefs_path = try std.fmt.allocPrint(allocator, "{s}/user.js", .{profile_dir});
    defer allocator.free(prefs_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, prefs_path, allocator, .limited(1 << 16)) catch return null;
    defer allocator.free(content);

    // Look for: user_pref("marionette.port", NNNN);
    const needle = "\"marionette.port\",";
    const pos = mem.indexOf(u8, content, needle) orelse return null;
    const after = content[pos + needle.len ..];

    // Skip whitespace
    var start: usize = 0;
    while (start < after.len and (after[start] == ' ' or after[start] == '\t')) : (start += 1) {}

    // Read digits
    var end = start;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}

    if (end == start) return null;
    return std.fmt.parseInt(u16, after[start..end], 10) catch null;
}

/// Get all PIDs on the system.
fn listAllPids(allocator: mem.Allocator, io: std.Io) ![]posix.pid_t {
    if (comptime builtin.os.tag == .linux) return listAllPidsLinux(allocator, io);
    return listAllPidsMacOS(allocator);
}

fn listAllPidsLinux(allocator: mem.Allocator, io: std.Io) ![]posix.pid_t {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer dir.close(io);
    var pids: std.ArrayList(posix.pid_t) = .empty;
    errdefer pids.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        try pids.append(allocator, pid);
    }
    return pids.toOwnedSlice(allocator);
}

/// Read /proc/PID/cmdline (NUL-separated argv).
fn getProcArgsLinux(allocator: mem.Allocator, io: std.Io, pid: posix.pid_t) !ProcArgs {
    _ = io;
    // procfs reports st_size 0, so Dir.readFileAlloc returns nothing; read until EOF.
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/cmdline", .{pid}, 0);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try acc.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    const buf = try acc.toOwnedSlice(allocator);
    errdefer allocator.free(buf);
    if (buf.len == 0) return error.EmptyProcArgs;
    const argv = try splitCmdline(allocator, buf);
    return .{ .raw_buf = buf, .argv = argv };
}

/// Split a raw /proc/PID/cmdline buffer into argv entries (slices into `buf`).
///
/// /proc/PID/cmdline is normally NUL-separated, one entry per argv element.
/// Chrome is the exception: it rewrites its own argv in place to set process
/// titles, which collapses the whole command line into a single space-joined
/// string with no interior NULs. We split on NUL first (which preserves values
/// that legitimately contain spaces); if a resulting token is itself a mashed
/// "prog --flag --flag" blob, we re-split it on spaces so the flags we match on
/// are still recovered. A value containing a space cannot survive Chrome's
/// rewrite — that information is already gone before we read it.
fn splitCmdline(allocator: mem.Allocator, buf: []const u8) ![][]const u8 {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    var it = mem.splitScalar(u8, mem.trimEnd(u8, buf, "\x00"), 0);
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (mem.indexOf(u8, tok, " --") != null) {
            var sp = mem.splitScalar(u8, tok, ' ');
            while (sp.next()) |a| if (a.len > 0) try argv_list.append(allocator, a);
        } else {
            try argv_list.append(allocator, tok);
        }
    }
    return argv_list.toOwnedSlice(allocator);
}

fn listAllPidsMacOS(allocator: mem.Allocator) ![]posix.pid_t {
    // First call: get required buffer size
    const bytes_needed = proc_listpids(PROC_ALL_PIDS, 0, null, 0);
    if (bytes_needed <= 0) return error.ProcListPidsFailed;

    const count: usize = @intCast(@divTrunc(bytes_needed, @sizeOf(posix.pid_t)));
    // Allocate a bit extra in case new processes appear
    const buf_count = count + 64;
    const buf = try allocator.alloc(posix.pid_t, buf_count);
    errdefer allocator.free(buf);

    const buf_bytes: [*]u8 = @ptrCast(buf.ptr);
    const buf_size: c_int = @intCast(buf_count * @sizeOf(posix.pid_t));
    const actual_bytes = proc_listpids(PROC_ALL_PIDS, 0, buf_bytes, buf_size);
    if (actual_bytes <= 0) return error.ProcListPidsFailed;

    const actual_count: usize = @intCast(@divTrunc(actual_bytes, @sizeOf(posix.pid_t)));

    // Shrink to actual size
    if (actual_count < buf_count) {
        return allocator.realloc(buf, actual_count);
    }
    return buf;
}

/// Parsed process arguments from KERN_PROCARGS2.
const ProcArgs = struct {
    /// Raw buffer that argv slices point into. Caller must free.
    raw_buf: []u8,
    /// Argument strings (slices into raw_buf).
    argv: [][]const u8,
};

/// Read command-line arguments for a PID using sysctl(KERN_PROCARGS2).
///
/// The KERN_PROCARGS2 buffer layout is:
///   [4 bytes: argc as u32]
///   [exec_path as null-terminated string]
///   [padding: zero or more null bytes]
///   [argv[0] as null-terminated string]
///   [argv[1] as null-terminated string]
///   ...
///   [argv[argc-1] as null-terminated string]
fn getProcArgs(allocator: mem.Allocator, io: std.Io, pid: posix.pid_t) !ProcArgs {
    if (comptime builtin.os.tag == .linux) return getProcArgsLinux(allocator, io, pid);
    var mib = [4]c_int{ CTL_KERN, KERN_PROCARGS2, @intCast(pid), 0 };

    // First call to get size
    var size: usize = 0;
    const rc1 = std.c.sysctl(&mib, 3, null, &size, null, 0);
    if (rc1 != 0) return error.SysctlFailed;
    if (size == 0) return error.EmptyProcArgs;

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    // Second call to get data
    var actual_size = size;
    const rc2 = std.c.sysctl(&mib, 3, buf.ptr, &actual_size, null, 0);
    if (rc2 != 0) return error.SysctlFailed;

    const data = buf[0..actual_size];

    // Parse: first 4 bytes are argc
    if (data.len < 4) return error.InvalidProcArgs;
    const argc: u32 = @bitCast(data[0..4].*);

    // Skip past exec_path (null-terminated string after the 4-byte argc)
    var pos: usize = 4;

    // Find end of exec_path
    while (pos < data.len and data[pos] != 0) : (pos += 1) {}

    // Skip null padding between exec_path and argv[0]
    while (pos < data.len and data[pos] == 0) : (pos += 1) {}

    // Now parse argc null-terminated strings
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    var found: u32 = 0;
    while (found < argc and pos < data.len) {
        const start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        if (pos > start) {
            try argv_list.append(allocator, data[start..pos]);
        }
        pos += 1; // skip null terminator
        found += 1;
    }

    const argv = try argv_list.toOwnedSlice(allocator);

    return .{
        .raw_buf = buf,
        .argv = argv,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "DiscoveredProcess struct has expected fields" {
    const p = DiscoveredProcess{
        .pid = 1234,
        .port = 9322,
        .profile = "test",
        .user_data_dir = "/home/user/.hibrow/profiles/test",
    };
    try std.testing.expectEqual(@as(os.Pid, 1234), p.pid);
    try std.testing.expectEqual(@as(u16, 9322), p.port);
    try std.testing.expectEqualStrings("test", p.profile);
}

test "findChromeBrowsers returns a slice" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const procs = try findChromeBrowsers(allocator, threaded.io());
    defer freeDiscovered(allocator, procs);
    // We just verify it does not crash — may return 0 if no Chrome running
    _ = procs.len;
}

test "listAllPids returns non-empty list" {
    if (comptime builtin.os.tag != .macos) return;
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const pids = try listAllPids(allocator, threaded.io());
    defer allocator.free(pids);
    // There should always be at least a few processes
    try std.testing.expect(pids.len > 0);
}

test "getProcArgs reads own process args" {
    if (comptime builtin.os.tag != .macos) return;
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const my_pid = std.c.getpid();
    const parsed = try getProcArgs(allocator, threaded.io(), my_pid);
    defer allocator.free(parsed.raw_buf);
    defer allocator.free(parsed.argv);
    // Our own process should have at least one arg (the executable path)
    try std.testing.expect(parsed.argv.len > 0);
}

test "splitCmdline: canonical NUL-separated argv" {
    const allocator = std.testing.allocator;
    const buf = "/usr/bin/firefox\x00--marionette\x00--profile\x00/home/u/.hibrow/profiles/work\x00";
    const argv = try splitCmdline(allocator, buf);
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("--marionette", argv[1]);
    try std.testing.expectEqualStrings("--profile", argv[2]);
    try std.testing.expectEqualStrings("/home/u/.hibrow/profiles/work", argv[3]);
}

test "splitCmdline: Chrome space-mashed cmdline (no interior NULs)" {
    const allocator = std.testing.allocator;
    // Chrome rewrites argv into one space-joined blob with a single trailing NUL.
    const buf = "/opt/google/chrome/chrome --remote-debugging-port=9322 --user-data-dir=/home/u/.hibrow/profiles/work --headless=new\x00";
    const argv = try splitCmdline(allocator, buf);
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("--remote-debugging-port=9322", argv[1]);
    try std.testing.expectEqualStrings("--user-data-dir=/home/u/.hibrow/profiles/work", argv[2]);
    try std.testing.expectEqualStrings("--headless=new", argv[3]);
}

test "splitCmdline: NUL-separated value may contain a space" {
    const allocator = std.testing.allocator;
    // A single NUL-delimited arg whose value has a space must stay intact; it
    // has no " --" blob marker, so it is not re-split.
    const buf = "prog\x00--user-data-dir=/home/u/my profile\x00";
    const argv = try splitCmdline(allocator, buf);
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("--user-data-dir=/home/u/my profile", argv[1]);
}

test "freeDiscovered handles empty slice" {
    const allocator = std.testing.allocator;
    const empty = try allocator.alloc(DiscoveredProcess, 0);
    freeDiscovered(allocator, empty);
}
