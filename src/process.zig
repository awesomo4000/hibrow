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

/// A discovered Chrome process with its CDP port and profile info.
pub const DiscoveredProcess = struct {
    pid: posix.pid_t,
    /// CDP debugging port (from --remote-debugging-port=N).
    port: u16,
    /// Profile name (basename of --user-data-dir path).
    profile: []const u8,
    /// Full --user-data-dir path.
    user_data_dir: []const u8,
};

/// Find all Chrome processes with --remote-debugging-port in their args.
/// Caller owns the returned slice and all strings within it.
/// Free with freeDiscovered().
pub fn findChromeBrowsers(allocator: mem.Allocator) ![]DiscoveredProcess {
    if (comptime builtin.os.tag == .macos) {
        return findChromeBrowsersMacOS(allocator);
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

fn findChromeBrowsersMacOS(allocator: mem.Allocator) ![]DiscoveredProcess {
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

        // Look for --remote-debugging-port= in the argv
        var port: ?u16 = null;
        var user_data_dir: ?[]const u8 = null;

        for (parsed.argv) |arg| {
            if (mem.startsWith(u8, arg, "--remote-debugging-port=")) {
                const val = arg["--remote-debugging-port=".len..];
                port = std.fmt.parseInt(u16, val, 10) catch null;
            } else if (mem.startsWith(u8, arg, "--user-data-dir=")) {
                user_data_dir = arg["--user-data-dir=".len..];
            }
        }

        // Only include processes that have a debugging port
        if (port) |p| {
            if (user_data_dir) |udd| {
                // Dupe the user_data_dir string so it outlives parsed.raw_buf
                const udd_owned = try allocator.dupe(u8, udd);
                errdefer allocator.free(udd_owned);

                // Profile name = basename of user-data-dir
                const profile = std.fs.path.basename(udd_owned);

                try results.append(allocator, .{
                    .pid = pid,
                    .port = p,
                    .profile = profile,
                    .user_data_dir = udd_owned,
                });
            }
        }
    }

    return try results.toOwnedSlice(allocator);
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
