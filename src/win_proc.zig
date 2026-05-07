///! Windows-only utilities: socket → PID lookup, and command-line extraction
///! by PID. Self-contained, depends only on std.os.windows and a couple of
///! extern declarations. Two reusable snippets:
///!
///!   1. listTcpListeners / getListeningPid  — Win32 lsof for IPv4 TCP.
///!      Uses iphlpapi GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER).
///!
///!   2. getProcessCommandLine                — full command line for any
///!      readable PID. Uses NtQueryInformationProcess with the Windows-8.1+
///!      ProcessCommandLineInformation class (info class 60). No PEB walk,
///!      no ReadProcessMemory.
///!
///! This file is intentionally not added to build.zig source_files: its body
///! references Windows-only types that won't compile on Unix targets. Import
///! it only behind a `builtin.os.tag == .windows` comptime branch.
const std = @import("std");
const mem = std.mem;
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const ULONG = windows.ULONG;
const BOOL = windows.BOOL;
const FALSE = windows.FALSE;

// ---------------------------------------------------------------------------
// 1) IPv4 TCP listeners → owning PID
// ---------------------------------------------------------------------------

/// One IPv4 TCP listener.
pub const Listener = struct {
    port: u16,
    pid: u32,
};

const AF_INET: ULONG = 2;
const TCP_TABLE_OWNER_PID_LISTENER: ULONG = 3;

extern "iphlpapi" fn GetExtendedTcpTable(
    pTcpTable: ?*anyopaque,
    pdwSize: *DWORD,
    bOrder: BOOL,
    ulAf: ULONG,
    TableClass: ULONG,
    Reserved: ULONG,
) callconv(.winapi) DWORD;

// MIB_TCPROW_OWNER_PID is six DWORDs:
//   State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid
const tcprow_stride = 24;
const off_local_port = 8;
const off_owning_pid = 20;

/// Enumerate all IPv4 TCP listeners with their owning PIDs.
pub fn listTcpListeners(allocator: mem.Allocator) ![]Listener {
    var size: DWORD = 0;
    _ = GetExtendedTcpTable(null, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (size == 0) return try allocator.alloc(Listener, 0);

    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    var actual = size;
    const rc = GetExtendedTcpTable(
        buf.ptr,
        &actual,
        FALSE,
        AF_INET,
        TCP_TABLE_OWNER_PID_LISTENER,
        0,
    );
    if (rc != 0) return error.GetExtendedTcpTableFailed;
    if (actual < 4) return try allocator.alloc(Listener, 0);

    const num_entries = std.mem.readInt(u32, buf[0..4], .little);
    const out = try allocator.alloc(Listener, num_entries);
    errdefer allocator.free(out);

    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        const off = 4 + i * tcprow_stride;
        if (off + tcprow_stride > actual) {
            // Truncated table; return what we parsed.
            return allocator.realloc(out, i);
        }
        // dwLocalPort: a USHORT in network byte order, stored in the low
        // half of a DWORD. Truncate to u16 then byteswap to host order.
        const dw_local_port = std.mem.readInt(u32, buf[off + off_local_port ..][0..4], .little);
        const port_be: u16 = @truncate(dw_local_port);
        out[i] = .{
            .port = @byteSwap(port_be),
            .pid = std.mem.readInt(u32, buf[off + off_owning_pid ..][0..4], .little),
        };
    }
    return out;
}

/// Return the PID of the process listening on `port` over IPv4 TCP, or null
/// if no process is listening.
pub fn getListeningPid(allocator: mem.Allocator, port: u16) !?u32 {
    const listeners = try listTcpListeners(allocator);
    defer allocator.free(listeners);
    for (listeners) |l| {
        if (l.port == port) return l.pid;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 2) PID → command line (Windows 8.1+)
// ---------------------------------------------------------------------------

const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
const ProcessCommandLineInformation: ULONG = 60;
const STATUS_SUCCESS: i32 = 0;

const UNICODE_STRING = extern struct {
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]u16,
};

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

extern "ntdll" fn NtQueryInformationProcess(
    ProcessHandle: HANDLE,
    ProcessInformationClass: ULONG,
    ProcessInformation: ?*anyopaque,
    ProcessInformationLength: ULONG,
    ReturnLength: ?*ULONG,
) callconv(.winapi) i32;

/// Read the full command line of a running process. The returned UTF-8
/// string includes the executable path as argv[0] (Windows passes the whole
/// command line as a single string, not pre-split). Returns null if the
/// process can't be opened (gone, ACL-denied, etc.).
pub fn getProcessCommandLine(allocator: mem.Allocator, pid: u32) !?[]u8 {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) orelse return null;
    defer windows.CloseHandle(handle);

    // First call: ask how many bytes we need. The kernel returns
    // STATUS_INFO_LENGTH_MISMATCH but writes the required size into `needed`.
    var needed: ULONG = 0;
    _ = NtQueryInformationProcess(handle, ProcessCommandLineInformation, null, 0, &needed);
    if (needed == 0) return null;

    const buf = try allocator.alloc(u8, needed);
    defer allocator.free(buf);

    var got: ULONG = needed;
    const status = NtQueryInformationProcess(
        handle,
        ProcessCommandLineInformation,
        @ptrCast(buf.ptr),
        needed,
        &got,
    );
    if (status != STATUS_SUCCESS) return null;
    if (got < @sizeOf(UNICODE_STRING)) return null;

    // The kernel writes a UNICODE_STRING header at the start of the buffer;
    // its Buffer field points into the same buffer at the wide-char payload.
    const us: *align(1) const UNICODE_STRING = @ptrCast(buf.ptr);
    const wide_len = us.Length / 2;
    if (wide_len == 0) return null;
    const wide_ptr = us.Buffer orelse return null;
    const wide = wide_ptr[0..wide_len];

    return try std.unicode.wtf16LeToWtf8Alloc(allocator, wide);
}
