///! Minimal WebSocket client implementation (RFC 6455).
///!
///! Supports text frames only (sufficient for CDP JSON messages over localhost).
///! Features: HTTP upgrade handshake, frame encode/decode, client-side masking,
///! ping/pong. No compression (not needed for localhost CDP).
///!
///! Built on std.net.Stream.
const std = @import("std");
const mem = std.mem;
const net = std.net;

/// WebSocket opcodes (RFC 6455 §5.2).
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// A decoded WebSocket frame.
pub const Frame = struct {
    fin: bool = true,
    opcode: Opcode,
    payload: []const u8,
};

/// WebSocket connection state.
pub const WebSocket = struct {
    allocator: mem.Allocator,
    stream: ?net.Stream = null,
    connected: bool = false,

    pub fn init(allocator: mem.Allocator) WebSocket {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WebSocket) void {
        self.close();
    }

    /// Perform HTTP upgrade handshake and establish WebSocket connection.
    pub fn connect(self: *WebSocket, host: []const u8, port: u16, path: []const u8) !void {
        _ = self;
        _ = host;
        _ = port;
        _ = path;
        // TODO: TCP connect, send HTTP upgrade request, validate 101 response
    }

    /// Send a text frame (masked, as required for clients).
    pub fn sendText(self: *WebSocket, payload: []const u8) !void {
        _ = self;
        _ = payload;
        // TODO: encode frame with masking, write to stream
    }

    /// Read the next frame from the connection.
    pub fn readFrame(self: *WebSocket) !Frame {
        _ = self;
        // TODO: read frame header, decode payload, handle masking
        return error.NotConnected;
    }

    /// Send a close frame and shut down the connection.
    pub fn close(self: *WebSocket) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        self.connected = false;
    }

    /// Send a pong frame in response to a ping.
    pub fn sendPong(self: *WebSocket, payload: []const u8) !void {
        _ = self;
        _ = payload;
        // TODO: encode pong frame, write
    }
};

/// Generate a random 4-byte masking key.
pub fn generateMaskingKey() [4]u8 {
    var key: [4]u8 = undefined;
    std.crypto.random.bytes(&key);
    return key;
}

/// Apply XOR masking to payload data (RFC 6455 §5.3).
pub fn applyMask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}

/// Generate the Sec-WebSocket-Accept value from a client key (RFC 6455 §4.2.2).
pub fn computeAcceptKey(client_key: []const u8) ![28]u8 {
    _ = client_key;
    // TODO: SHA-1(client_key ++ magic_guid), base64 encode
    return [_]u8{0} ** 28;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Opcode values match RFC 6455" {
    try std.testing.expectEqual(@as(u4, 0x1), @intFromEnum(Opcode.text));
    try std.testing.expectEqual(@as(u4, 0x2), @intFromEnum(Opcode.binary));
    try std.testing.expectEqual(@as(u4, 0x8), @intFromEnum(Opcode.close));
    try std.testing.expectEqual(@as(u4, 0x9), @intFromEnum(Opcode.ping));
    try std.testing.expectEqual(@as(u4, 0xA), @intFromEnum(Opcode.pong));
}

test "applyMask is its own inverse" {
    var data = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    const original = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    applyMask(&data, mask);
    // After masking, data should differ from original
    try std.testing.expect(!mem.eql(u8, &data, &original));

    // Apply mask again to reverse
    applyMask(&data, mask);
    try std.testing.expect(mem.eql(u8, &data, &original));
}

test "WebSocket init and deinit" {
    const allocator = std.testing.allocator;
    var ws = WebSocket.init(allocator);
    defer ws.deinit();
    try std.testing.expect(!ws.connected);
    try std.testing.expect(ws.stream == null);
}

test "generateMaskingKey returns 4 bytes" {
    const key = generateMaskingKey();
    try std.testing.expectEqual(@as(usize, 4), key.len);
}
