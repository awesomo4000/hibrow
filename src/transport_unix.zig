///! Unix-domain-socket transport implementation. See `transport.zig` for the
///! public API; this module is only imported through that dispatcher.
const std = @import("std");

pub const Stream = std.net.Stream;

pub const Listener = struct {
    inner: std.net.Server,

    pub fn accept(self: *Listener) !Stream {
        const conn = try self.inner.accept();
        return conn.stream;
    }

    pub fn deinit(self: *Listener) void {
        self.inner.deinit();
    }
};

pub fn connect(path: []const u8) !Stream {
    return std.net.connectUnixSocket(path);
}

pub fn listen(path: []const u8) !Listener {
    const addr = try std.net.Address.initUnix(path);
    const inner = try addr.listen(.{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    return .{ .inner = inner };
}
