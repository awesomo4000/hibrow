///! Windows-specific browser discovery and executable lookup.
///!
///! This file is the single home for the heavy Win32 code, so the rest of the
///! codebase stays platform-neutral. Every public function is reached only from
///! a `builtin.os.tag == .windows` branch elsewhere (pruned at compile time on
///! other platforms) and dispatches to a `*Windows` implementation only inside
///! an `if (is_windows)`, so the Win32 externs below are never analyzed or
///! linked on macOS/Linux even though the module is imported there.
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const process = @import("process.zig");

const is_windows = builtin.os.tag == .windows;
const w = std.os.windows;

/// Find the Chrome/Chromium executable via the App Paths registry key.
/// Returns an allocated absolute path, or null if not installed.
pub fn findChrome(allocator: mem.Allocator) !?[]u8 {
    if (is_windows) return appPathsLookup(allocator, "chrome.exe");
    return null;
}

/// Find the Firefox executable via the App Paths registry key.
pub fn findFirefox(allocator: mem.Allocator) !?[]u8 {
    if (is_windows) return appPathsLookup(allocator, "firefox.exe");
    return null;
}

/// Discover running browsers by reading each process's command line and
/// matching --remote-debugging-port / --marionette, mirroring the POSIX scan.
/// Caller owns the slice; free with process.freeDiscovered().
pub fn findBrowsers(allocator: mem.Allocator, io: std.Io) ![]process.DiscoveredProcess {
    if (is_windows) return findBrowsersWindows(allocator, io);
    return &[_]process.DiscoveredProcess{};
}

// ---------------------------------------------------------------------------
// Win32 bindings (referenced only from the is_windows paths above)
// ---------------------------------------------------------------------------

const TH32CS_SNAPPROCESS: w.DWORD = 0x00000002;
const PROCESS_QUERY_LIMITED_INFORMATION: w.DWORD = 0x1000;
const PROCESS_VM_READ: w.DWORD = 0x0010;
const RRF_RT_REG_SZ: w.DWORD = 0x00000002;

const PROCESSENTRY32W = extern struct {
    dwSize: w.DWORD,
    cntUsage: w.DWORD,
    th32ProcessID: w.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: w.DWORD,
    cntThreads: w.DWORD,
    th32ParentProcessID: w.DWORD,
    pcPriClassBase: w.LONG,
    dwFlags: w.DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: w.DWORD, th32ProcessID: w.DWORD) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: w.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
extern "kernel32" fn Process32NextW(hSnapshot: w.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
extern "kernel32" fn OpenProcess(dwDesiredAccess: w.DWORD, bInheritHandle: c_int, dwProcessId: w.DWORD) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn ReadProcessMemory(hProcess: w.HANDLE, lpBaseAddress: ?*const anyopaque, lpBuffer: [*]u8, nSize: usize, lpNumberOfBytesRead: *usize) callconv(.winapi) c_int;
extern "advapi32" fn RegGetValueW(hkey: w.HKEY, lpSubKey: ?[*:0]const u16, lpValue: ?[*:0]const u16, dwFlags: w.DWORD, pdwType: ?*w.DWORD, pvData: ?*anyopaque, pcbData: ?*w.DWORD) callconv(.winapi) w.LONG;

// ---------------------------------------------------------------------------
// App Paths lookup
// ---------------------------------------------------------------------------

fn appPathsLookup(allocator: mem.Allocator, exe: []const u8) !?[]u8 {
    const ascii = try std.fmt.allocPrint(
        allocator,
        "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\{s}",
        .{exe},
    );
    defer allocator.free(ascii);

    var subkey: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&subkey, ascii) catch return null;
    if (n >= subkey.len) return null;
    subkey[n] = 0;
    const subkey_z: [*:0]const u16 = @ptrCast(&subkey);

    for ([_]w.HKEY{ w.HKEY_CURRENT_USER, w.HKEY_LOCAL_MACHINE }) |root| {
        var data: [w.PATH_MAX_WIDE]u16 = undefined;
        var cb: w.DWORD = @intCast(data.len * @sizeOf(u16));
        const rc = RegGetValueW(root, subkey_z, null, RRF_RT_REG_SZ, null, @ptrCast(&data), &cb);
        if (rc == 0) { // ERROR_SUCCESS
            const wchars = cb / @sizeOf(u16);
            const end = if (wchars > 0 and data[wchars - 1] == 0) wchars - 1 else wchars;
            return std.unicode.utf16LeToUtf8Alloc(allocator, data[0..end]) catch return null;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Process discovery
// ---------------------------------------------------------------------------

fn findBrowsersWindows(allocator: mem.Allocator, io: std.Io) ![]process.DiscoveredProcess {
    var results: std.ArrayList(process.DiscoveredProcess) = .empty;
    errdefer {
        for (results.items) |p| allocator.free(p.user_data_dir);
        results.deinit(allocator);
    }

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == w.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
    defer w.CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    var ok = Process32FirstW(snap, &entry);
    while (ok != 0) : (ok = Process32NextW(snap, &entry)) {
        const exe = exeNameUtf16(&entry.szExeFile);
        if (!utf16EqlAsciiIgnoreCase(exe, "chrome.exe") and
            !utf16EqlAsciiIgnoreCase(exe, "firefox.exe")) continue;

        // Reading the command line can fail for processes we can't open (e.g.
        // sandboxed renderers); skip those — the main process carries the flags.
        const cmd = readCommandLine(allocator, entry.th32ProcessID) catch continue;
        defer allocator.free(cmd);
        matchBrowser(allocator, io, &results, entry.th32ProcessID, cmd) catch continue;
    }

    return results.toOwnedSlice(allocator);
}

/// Parse a UTF-8 command line and append any browser it describes.
fn matchBrowser(
    allocator: mem.Allocator,
    io: std.Io,
    results: *std.ArrayList(process.DiscoveredProcess),
    pid: w.DWORD,
    cmd: []const u8,
) !void {
    // Chrome: --remote-debugging-port=NNNN and --user-data-dir=DIR
    if (flagValue(cmd, "--remote-debugging-port=")) |port_str| {
        if (flagValue(cmd, "--user-data-dir=")) |udd| {
            const port = std.fmt.parseInt(u16, port_str, 10) catch return;
            const udd_owned = try allocator.dupe(u8, udd);
            errdefer allocator.free(udd_owned);
            try results.append(allocator, .{
                .pid = @intCast(pid),
                .port = port,
                .profile = std.fs.path.basename(udd_owned),
                .user_data_dir = udd_owned,
                .browser_type = .chrome,
            });
            return;
        }
    }

    // Firefox: --marionette and --profile DIR; port lives in DIR\user.js
    if (mem.indexOf(u8, cmd, "--marionette") != null) {
        if (tokenAfter(cmd, "--profile")) |pdir| {
            const pdir_owned = try allocator.dupe(u8, pdir);
            errdefer allocator.free(pdir_owned);
            const m_port = process.readMarionettePort(allocator, io, pdir_owned) catch null;
            if (m_port) |port| {
                try results.append(allocator, .{
                    .pid = @intCast(pid),
                    .port = port,
                    .profile = std.fs.path.basename(pdir_owned),
                    .user_data_dir = pdir_owned,
                    .browser_type = .firefox,
                });
            } else {
                allocator.free(pdir_owned);
            }
        }
    }
}

/// Read a process's command line via its PEB. Returns a UTF-8 string.
fn readCommandLine(allocator: mem.Allocator, pid: w.DWORD) ![]u8 {
    const hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, 0, pid) orelse
        return error.OpenProcessFailed;
    defer w.CloseHandle(hProc);

    var pbi: w.PROCESS.BASIC_INFORMATION = undefined;
    const st = w.ntdll.NtQueryInformationProcess(hProc, .BasicInformation, &pbi, @sizeOf(@TypeOf(pbi)), null);
    if (st != .SUCCESS) return error.QueryProcessFailed;

    var peb: w.PEB = undefined;
    try readMemory(hProc, @intFromPtr(pbi.PebBaseAddress), mem.asBytes(&peb));

    var params: w.RTL_USER_PROCESS_PARAMETERS = undefined;
    try readMemory(hProc, @intFromPtr(peb.ProcessParameters), mem.asBytes(&params));

    const len_bytes: usize = params.CommandLine.Length;
    const buffer = params.CommandLine.Buffer orelse return error.NoCommandLine;
    if (len_bytes == 0) return error.NoCommandLine;

    const wbuf = try allocator.alloc(u16, len_bytes / @sizeOf(u16));
    defer allocator.free(wbuf);
    try readMemory(hProc, @intFromPtr(buffer), mem.sliceAsBytes(wbuf));

    return std.unicode.utf16LeToUtf8Alloc(allocator, wbuf);
}

fn readMemory(hProc: w.HANDLE, addr: usize, out: []u8) !void {
    var read: usize = 0;
    if (ReadProcessMemory(hProc, @ptrFromInt(addr), out.ptr, out.len, &read) == 0)
        return error.ReadMemoryFailed;
    if (read != out.len) return error.ShortRead;
}

// ---------------------------------------------------------------------------
// Small parsing helpers
// ---------------------------------------------------------------------------

/// The szExeFile field is a NUL-terminated UTF-16 string in a fixed array.
fn exeNameUtf16(field: []const u16) []const u16 {
    const n = mem.indexOfScalar(u16, field, 0) orelse field.len;
    return field[0..n];
}

fn utf16EqlAsciiIgnoreCase(a: []const u16, ascii: []const u8) bool {
    if (a.len != ascii.len) return false;
    for (a, ascii) |wc, ac| {
        if (wc > 0x7f) return false;
        if (std.ascii.toLower(@intCast(wc)) != std.ascii.toLower(ac)) return false;
    }
    return true;
}

/// Read a single command-line token starting at `s`: a double-quoted run, or
/// bytes up to the next space. Returns the token without surrounding quotes.
fn readToken(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '"') {
        const end = mem.indexOfScalar(u8, s[1..], '"') orelse return s[1..];
        return s[1 .. 1 + end];
    }
    const end = mem.indexOfScalar(u8, s, ' ') orelse return s;
    return s[0..end];
}

/// Value of a `--flag=` option: the token immediately after the '='.
fn flagValue(cmd: []const u8, prefix: []const u8) ?[]const u8 {
    const idx = mem.indexOf(u8, cmd, prefix) orelse return null;
    return readToken(cmd[idx + prefix.len ..]);
}

/// Token following a space-separated `flag` (e.g. `--profile DIR`).
fn tokenAfter(cmd: []const u8, flag: []const u8) ?[]const u8 {
    const idx = mem.indexOf(u8, cmd, flag) orelse return null;
    var rest = cmd[idx + flag.len ..];
    var i: usize = 0;
    while (i < rest.len and rest[i] == ' ') : (i += 1) {}
    rest = rest[i..];
    if (rest.len == 0) return null;
    return readToken(rest);
}

test "flagValue extracts =value and quoted value" {
    try std.testing.expectEqualStrings("9322", flagValue("x --remote-debugging-port=9322 y", "--remote-debugging-port=").?);
    try std.testing.expectEqualStrings("C:\\a b\\c", flagValue("--user-data-dir=\"C:\\a b\\c\" --x", "--user-data-dir=").?);
    try std.testing.expect(flagValue("nothing here", "--user-data-dir=") == null);
}

test "tokenAfter reads space-separated and quoted tokens" {
    try std.testing.expectEqualStrings("C:\\p", tokenAfter("--marionette --profile C:\\p --x", "--profile").?);
    try std.testing.expectEqualStrings("C:\\a b", tokenAfter("--profile \"C:\\a b\" --x", "--profile").?);
}

test "utf16EqlAsciiIgnoreCase" {
    const chrome = std.unicode.utf8ToUtf16LeStringLiteral("CHROME.exe");
    try std.testing.expect(utf16EqlAsciiIgnoreCase(chrome, "chrome.exe"));
    const other = std.unicode.utf8ToUtf16LeStringLiteral("msedge.exe");
    try std.testing.expect(!utf16EqlAsciiIgnoreCase(other, "chrome.exe"));
}
