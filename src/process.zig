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

/// A discovered Chrome process with its CDP port and profile info.
pub const DiscoveredProcess = struct {
    pid: posix.pid_t,
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
pub fn findChromeBrowsers(allocator: mem.Allocator) ![]DiscoveredProcess {
    if (comptime builtin.os.tag == .macos) {
        return findBrowsersMacOS(allocator);
    } else {
        // Linux: TODO — use /proc/PID/cmdline
        return &[_]DiscoveredProcess{};
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

fn findBrowsersMacOS(allocator: mem.Allocator) ![]DiscoveredProcess {
    // Step 1: Get list of all PIDs
    const pids = try listAllPids(allocator);
    defer allocator.free(pids);

    var results: std.ArrayList(DiscoveredProcess) = .{};
    errdefer {
        for (results.items) |p| allocator.free(p.user_data_dir);
        results.deinit(allocator);
    }

    // Step 2: For each PID, try to read its command-line args
    for (pids) |pid| {
        if (pid <= 0) continue;

        const parsed = getProcArgs(allocator, pid) catch continue;
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
                    .pid = pid,
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
                const m_port = readMarionettePort(allocator, pdir_owned) catch null;
                if (m_port) |port| {
                    try results.append(allocator, .{
                        .pid = pid,
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
fn readMarionettePort(allocator: mem.Allocator, profile_dir: []const u8) !?u16 {
    const prefs_path = try std.fmt.allocPrint(allocator, "{s}/user.js", .{profile_dir});
    defer allocator.free(prefs_path);

    const content = std.fs.cwd().readFileAlloc(allocator, prefs_path, 1 << 16) catch return null;
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
fn listAllPids(allocator: mem.Allocator) ![]posix.pid_t {
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
fn getProcArgs(allocator: mem.Allocator, pid: posix.pid_t) !ProcArgs {
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
    var argv_list: std.ArrayList([]const u8) = .{};
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const p = DiscoveredProcess{
        .pid = 1234,
        .port = 9322,
        .profile = "test",
        .user_data_dir = "/home/user/.hibrow/profiles/test",
    };
    try std.testing.expectEqual(@as(posix.pid_t, 1234), p.pid);
    try std.testing.expectEqual(@as(u16, 9322), p.port);
    try std.testing.expectEqualStrings("test", p.profile);
}

test "findChromeBrowsers returns a slice" {
    const allocator = std.testing.allocator;
    const procs = try findChromeBrowsers(allocator);
    defer freeDiscovered(allocator, procs);
    // We just verify it does not crash — may return 0 if no Chrome running
    _ = procs.len;
}

test "listAllPids returns non-empty list" {
    if (comptime builtin.os.tag != .macos) return;
    const allocator = std.testing.allocator;
    const pids = try listAllPids(allocator);
    defer allocator.free(pids);
    // There should always be at least a few processes
    try std.testing.expect(pids.len > 0);
}

test "getProcArgs reads own process args" {
    if (comptime builtin.os.tag != .macos) return;
    const allocator = std.testing.allocator;
    const my_pid = std.c.getpid();
    const parsed = try getProcArgs(allocator, my_pid);
    defer allocator.free(parsed.raw_buf);
    defer allocator.free(parsed.argv);
    // Our own process should have at least one arg (the executable path)
    try std.testing.expect(parsed.argv.len > 0);
}

test "freeDiscovered handles empty slice" {
    const allocator = std.testing.allocator;
    const empty = try allocator.alloc(DiscoveredProcess, 0);
    freeDiscovered(allocator, empty);
}
