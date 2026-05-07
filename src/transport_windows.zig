///! Windows named-pipe transport implementation. See `transport.zig` for the
///! public API; this module is only imported through that dispatcher.
///!
///! Pipe path convention: `\\.\pipe\hibrow-gateway`. The Server creates a new
///! pipe instance for every connection; clients open with `CreateFileW` and
///! retry on `ERROR_PIPE_BUSY`.
const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const LPCWSTR = windows.LPCWSTR;
const TRUE = windows.TRUE;
const FALSE = windows.FALSE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

// Constants not all re-exported by std.os.windows.
const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_READMODE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
const NMPWAIT_USE_DEFAULT_WAIT: DWORD = 0;
const NMPWAIT_WAIT_FOREVER: DWORD = 0xFFFFFFFF;
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;

// Pipe-specific error codes.
const ERROR_PIPE_BUSY: u16 = 231;
const ERROR_PIPE_CONNECTED: u16 = 535;
const ERROR_BROKEN_PIPE: u16 = 109;
const ERROR_NO_DATA: u16 = 232;

// Functions not declared in std.os.windows.kernel32.
extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;

const max_path_w = 256;

/// Convert a UTF-8 path to a stack-allocated null-terminated UTF-16 buffer.
fn utf8ToWtf16Z(buf: *[max_path_w]u16, path: []const u8) ![:0]const u16 {
    const len = try std.unicode.wtf8ToWtf16Le(buf[0 .. max_path_w - 1], path);
    buf[len] = 0;
    return buf[0..len :0];
}

pub const Stream = struct {
    handle: HANDLE,

    pub fn close(self: Stream) void {
        windows.CloseHandle(self.handle);
    }

    pub fn read(self: Stream, buf: []u8) !usize {
        return windows.ReadFile(self.handle, buf, null) catch |err| switch (err) {
            error.BrokenPipe => return 0, // remote closed → EOF
            else => return err,
        };
    }

    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const n = try windows.WriteFile(self.handle, bytes[index..], null);
            if (n == 0) return error.WriteFailed;
            index += n;
        }
    }
};

pub const Listener = struct {
    /// UTF-16 pipe path retained so we can spin up additional instances
    /// after each successful accept().
    name_buf: [max_path_w]u16,
    name_len: usize,
    /// Pre-created pipe instance waiting on the next ConnectNamedPipe.
    pending: HANDLE,
    closed: bool,

    pub fn accept(self: *Listener) !Stream {
        if (self.closed) return error.ListenerClosed;

        // ConnectNamedPipe blocks until a client opens the pipe (or the handle
        // is closed by shutdown — in which case it errors and we surface that).
        if (ConnectNamedPipe(self.pending, null) == FALSE) {
            const last = kernel32.GetLastError();
            // ERROR_PIPE_CONNECTED means a client connected between
            // CreateNamedPipeW and ConnectNamedPipe — still a success.
            if (@intFromEnum(last) != ERROR_PIPE_CONNECTED) {
                return error.AcceptFailed;
            }
        }

        const client_handle = self.pending;

        // Spin up the next instance so a future accept() has a handle ready.
        self.pending = try createPipeInstance(self.namePtr());
        return Stream{ .handle = client_handle };
    }

    pub fn deinit(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        // Closing the pending handle unblocks any in-flight ConnectNamedPipe.
        windows.CloseHandle(self.pending);
    }

    fn namePtr(self: *Listener) [:0]const u16 {
        return self.name_buf[0..self.name_len :0];
    }
};

fn createPipeInstance(name: [:0]const u16) !HANDLE {
    const handle = kernel32.CreateNamedPipeW(
        name.ptr,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        4096, // out buffer size
        4096, // in buffer size
        0, // default timeout (used only by WaitNamedPipe)
        null, // default security descriptor
    );
    if (handle == INVALID_HANDLE_VALUE) return error.CreateNamedPipeFailed;
    return handle;
}

pub fn listen(path: []const u8) !Listener {
    var listener: Listener = .{
        .name_buf = undefined,
        .name_len = 0,
        .pending = undefined,
        .closed = false,
    };
    const name = try utf8ToWtf16Z(&listener.name_buf, path);
    listener.name_len = name.len;
    listener.pending = try createPipeInstance(name);
    return listener;
}

pub fn connect(path: []const u8) !Stream {
    var name_buf: [max_path_w]u16 = undefined;
    const name = try utf8ToWtf16Z(&name_buf, path);

    // Retry up to ~5s if the pipe exists but all instances are busy.
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const handle = kernel32.CreateFileW(
            name.ptr,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (handle != INVALID_HANDLE_VALUE) {
            return Stream{ .handle = handle };
        }
        const last = @intFromEnum(kernel32.GetLastError());
        if (last == ERROR_PIPE_BUSY and attempts < 50) {
            _ = WaitNamedPipeW(name.ptr, 100);
            continue;
        }
        return error.ConnectionRefused;
    }
}
