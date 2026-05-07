///! Platform-abstracted IPC transport for the gateway.
///!
///! Unix:    Unix domain sockets at /tmp/hibrow-{uid}/gateway.sock
///! Windows: Named pipes at \\.\pipe\hibrow-gateway
///!
///! Both expose the same `Stream` (close/read/writeAll), `Listener`
///! (accept/deinit), `connect`, and `listen` so callers stay platform-free.
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("transport_windows.zig"),
    else => @import("transport_unix.zig"),
};

pub const Stream = impl.Stream;
pub const Listener = impl.Listener;
pub const connect = impl.connect;
pub const listen = impl.listen;
