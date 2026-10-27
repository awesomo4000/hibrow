//! Reproducer: double-deinit in WebSocket.readFrame when the peer closes.
//!
//!   zig test -lc --dep ws -Mroot=repro/readframe.zig -Mws=src/websocket.zig
//!
//! Each test hands readFrame one end of a socketpair, writes `prefix` bytes
//! (zero or a partial frame) from the other end, then closes it so the next
//! read() returns 0. Expected: error.ConnectionClosed. Actual (Debug):
//! SIGSEGV at 0xaaaaaaaaaaaaaaaa in mem.Allocator.free <- ArrayList.deinit
//! <- readFrame, matching the macOS crash report frame-for-frame.
const std = @import("std");
const ws = @import("ws");

extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

const Pair = struct {
    threaded: std.Io.Threaded,
    sock: ws.WebSocket,
    fd: c_int,

    /// Peer writes `bytes` then hangs up; returns the client side.
    fn init(self: *Pair, bytes: []const u8) !void {
        const gpa = std.testing.allocator;
        self.threaded = .init(gpa, .{});
        var sv: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sv));
        if (bytes.len > 0) _ = write(sv[1], bytes.ptr, bytes.len);
        _ = close(sv[1]);
        self.fd = sv[0];
        self.sock = ws.WebSocket.init(gpa, self.threaded.io());
        self.sock.stream = .{ .socket = .{ .handle = sv[0], .address = .{ .ip4 = .loopback(0) } } };
        self.sock.connected = true;
    }

    fn deinit(self: *Pair) void {
        self.sock.stream = null;
        self.sock.deinit();
        _ = close(self.fd);
        self.threaded.deinit();
    }
};

fn eofAfter(prefix: []const u8) !void {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var sv: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sv));
    defer _ = close(sv[0]);

    if (prefix.len > 0) _ = write(sv[1], prefix.ptr, prefix.len);
    _ = close(sv[1]); // peer goes away: Chrome closed the tab / quit

    var sock = ws.WebSocket.init(gpa, threaded.io());
    sock.stream = .{ .socket = .{ .handle = sv[0], .address = .{ .ip4 = .loopback(0) } } };
    sock.connected = true;

    try std.testing.expectError(error.ConnectionClosed, sock.readFrame());
    sock.stream = null; // fd closed by defer above
    sock.deinit();
}

test "peer closes before any frame bytes (idle cached CDP connection)" {
    try eofAfter("");
}

test "peer closes mid-frame (large base64 response cut off)" {
    // 0x81 = FIN|text, 0x7f = 64-bit length follows; claim 1 MiB, send 4 bytes.
    try eofAfter(&[_]u8{ 0x81, 0x7f, 0, 0, 0, 0, 0, 0x10, 0, 0, 'A', 'A', 'A', 'A' });
}

test "two frames delivered in one read: second must not be dropped" {
    // Chrome routinely coalesces an event + a response into one TCP segment.
    var p: Pair = undefined;
    try p.init(&[_]u8{ 0x81, 3, 'o', 'n', 'e', 0x81, 3, 't', 'w', 'o' });
    defer p.deinit();
    const a = try p.sock.readFrame();
    defer if (a.owned_payload) |b| std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("one", a.frame.payload);
    const b = try p.sock.readFrame();
    defer if (b.owned_payload) |x| std.testing.allocator.free(x);
    try std.testing.expectEqualStrings("two", b.frame.payload);
}

test "reserved opcode is an error, not a safety panic" {
    var p: Pair = undefined;
    try p.init(&[_]u8{ 0x83, 0 });
    defer p.deinit();
    try std.testing.expectError(error.InvalidOpcode, p.sock.readFrame());
}

test "64-bit length near maxInt is an error, not an overflow panic" {
    var p: Pair = undefined;
    try p.init(&[_]u8{ 0x81, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf0 });
    defer p.deinit();
    try std.testing.expectError(error.FrameTooLarge, p.sock.readFrame());
}
