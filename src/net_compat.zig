///! Cross-platform socket I/O helpers for working around stdlib quirks.
///!
///! `std.net.Stream.read` on Windows (zig 0.15.2) calls `ReadFile` on the
///! socket handle. That fails with `ERROR_INVALID_PARAMETER` (87) on the
///! overlapped sockets returned by `tcpConnectToHost` /
///! `tcpConnectToAddress`. `recv()` works the same way as on Unix and
///! handles overlapped sockets correctly, so we use it directly there.
///!
///! Drop-in replacement for `stream.read(buffer)`. Returns 0 on EOF.
const std = @import("std");
const builtin = @import("builtin");
const net = std.net;

pub fn streamRead(stream: net.Stream, buffer: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const len: c_int = @intCast(@min(buffer.len, std.math.maxInt(c_int)));
        const n = ws2.recv(@ptrCast(stream.handle), buffer.ptr, len, 0);
        if (n == ws2.SOCKET_ERROR) {
            const err = ws2.WSAGetLastError();
            return switch (err) {
                .WSAESHUTDOWN, .WSAECONNRESET, .WSAECONNABORTED => 0,
                else => error.SocketReadFailed,
            };
        }
        return @intCast(n);
    }
    return stream.read(buffer);
}
