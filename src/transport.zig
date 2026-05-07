///! Platform-abstracted IPC transport for the gateway.
///!
///! Today this is a thin wrapper over `std.net` Unix domain sockets. The
///! Windows path will swap to named pipes (`\\.\pipe\hibrow-gateway`) — call
///! sites should depend on this module, not on `std.net.Stream` directly.
const std = @import("std");

/// A connected, bidirectional, byte-oriented stream.
pub const Stream = std.net.Stream;

/// A server-side listener. Accept new connections in a loop.
pub const Listener = struct {
    inner: std.net.Server,

    /// Accept the next inbound connection. Blocks until one arrives or the
    /// listener is closed (in which case this returns an error).
    pub fn accept(self: *Listener) !Stream {
        const conn = try self.inner.accept();
        return conn.stream;
    }

    /// Close the listener. Unblocks any in-progress accept().
    pub fn deinit(self: *Listener) void {
        self.inner.deinit();
    }
};

/// Connect to a gateway listening at `path`.
pub fn connect(path: []const u8) !Stream {
    return std.net.connectUnixSocket(path);
}

/// Begin listening at `path`. Removes any stale socket file first is the
/// caller's responsibility.
pub fn listen(path: []const u8) !Listener {
    const addr = try std.net.Address.initUnix(path);
    const inner = try addr.listen(.{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    return .{ .inner = inner };
}
