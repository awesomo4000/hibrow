///! Minimal WebSocket client implementation (RFC 6455).
///!
///! Supports text frames only (sufficient for CDP JSON messages over localhost).
///! Features: HTTP upgrade handshake, frame encode/decode, client-side masking,
///! ping/pong. No compression (not needed for localhost CDP).
///!
///! Frame encode/decode are pure functions (no I/O) for easy testing.
///! The WebSocket struct wraps them with stream I/O for real connections.
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const crypto = std.crypto;

/// The 0.16 network stream type.
const Stream = std.Io.net.Stream;

/// Raw blocking read from the stream's socket fd (fds from the Io backend are
/// blocking, so raw posix I/O matches the pre-0.16 Stream.read semantics).
fn streamRead(stream: Stream, buf: []u8) !usize {
    return posix.read(stream.socket.handle, buf);
}

/// Write all bytes to the stream's socket fd, looping over partial writes.
fn streamWriteAll(stream: Stream, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = std.c.write(stream.socket.handle, bytes[i..].ptr, bytes.len - i);
        if (rc <= 0) return error.WriteFailed;
        i += @intCast(rc);
    }
}

/// Resolve a host + port and open a blocking TCP stream. Handles the local
/// CDP cases: a numeric IP, or "localhost" mapped to the loopback address.
fn tcpConnect(io: std.Io, host: []const u8, port: u16) !Stream {
    var addr = std.Io.net.IpAddress.parse(host, port) catch blk: {
        if (mem.eql(u8, host, "localhost")) {
            break :blk std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        }
        return error.UnknownHostName;
    };
    return addr.connect(io, .{ .mode = .stream });
}

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

/// Result from readFrame/readMessage. Caller must free owned_payload if non-null.
pub const ReadResult = struct {
    frame: Frame,
    owned_payload: ?[]u8,
};

/// Result of decoding a frame from a byte buffer.
pub const DecodeResult = struct {
    frame: Frame,
    bytes_consumed: usize,
};

/// RFC 6455 magic GUID for Sec-WebSocket-Accept computation.
const ws_magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---------------------------------------------------------------------------
// Pure functions — no I/O, fully testable
// ---------------------------------------------------------------------------

/// Generate a random 4-byte masking key.
pub fn generateMaskingKey() [4]u8 {
    var key: [4]u8 = undefined;
    std.c.arc4random_buf(&key, key.len);
    return key;
}

/// Apply XOR masking to payload data (RFC 6455 §5.3).
/// Masking is its own inverse: apply twice to recover original.
pub fn applyMask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}

/// Compute Sec-WebSocket-Accept from a client key (RFC 6455 §4.2.2).
/// Returns 28-byte base64-encoded string.
pub fn computeAcceptKey(client_key: []const u8) [28]u8 {
    // SHA-1(client_key ++ magic_guid)
    var hasher = crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(ws_magic_guid);
    const digest = hasher.finalResult();

    // Base64 encode the 20-byte digest → 28 chars
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

/// Generate a random 16-byte nonce, base64-encoded to 24 chars.
/// Used as Sec-WebSocket-Key in the upgrade handshake.
pub fn generateClientKey() [24]u8 {
    var nonce: [16]u8 = undefined;
    std.c.arc4random_buf(&nonce, nonce.len);
    var result: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &nonce);
    return result;
}

/// Encode a WebSocket frame into a caller-provided buffer.
/// Client frames are always masked. Returns the slice of buf that was written.
pub fn encodeFrame(buf: []u8, opcode: Opcode, payload: []const u8, mask: bool) ![]u8 {
    const max_header = 2 + 8 + 4; // header + extended len + mask key
    if (buf.len < max_header + payload.len) return error.BufferTooSmall;

    var pos: usize = 0;

    // Byte 0: FIN + opcode
    buf[pos] = 0x80 | @as(u8, @backingInt(opcode));
    pos += 1;

    // Byte 1: mask bit + payload length
    const mask_bit: u8 = if (mask) 0x80 else 0;
    if (payload.len < 126) {
        buf[pos] = mask_bit | @as(u8, @intCast(payload.len));
        pos += 1;
    } else if (payload.len <= 65535) {
        buf[pos] = mask_bit | 126;
        pos += 1;
        mem.writeInt(u16, buf[pos..][0..2], @intCast(payload.len), .big);
        pos += 2;
    } else {
        buf[pos] = mask_bit | 127;
        pos += 1;
        mem.writeInt(u64, buf[pos..][0..8], @intCast(payload.len), .big);
        pos += 8;
    }

    // Masking key + masked payload
    if (mask) {
        const mask_key = generateMaskingKey();
        @memcpy(buf[pos .. pos + 4], &mask_key);
        pos += 4;
        @memcpy(buf[pos .. pos + payload.len], payload);
        applyMask(buf[pos .. pos + payload.len], mask_key);
        pos += payload.len;
    } else {
        @memcpy(buf[pos .. pos + payload.len], payload);
        pos += payload.len;
    }

    return buf[0..pos];
}

/// Encode a frame into an allocated buffer. Caller owns the returned slice.
pub fn encodeFrameAlloc(allocator: mem.Allocator, opcode: Opcode, payload: []const u8, mask: bool) ![]u8 {
    const max_header = 2 + 8 + 4;
    const buf = try allocator.alloc(u8, max_header + payload.len);
    errdefer allocator.free(buf);
    const frame_bytes = try encodeFrame(buf, opcode, payload, mask);
    // Shrink to actual size
    if (frame_bytes.len < buf.len) {
        // Can't resize in-place easily, just return the full buffer
        // with the actual length tracked by the caller
        return frame_bytes;
    }
    return frame_bytes;
}

/// Upper bound on a single frame's payload. Full-page screenshots and `grab`
/// chunks are the largest CDP messages; anything past this is a corrupt or
/// hostile length field, not a real message.
pub const max_payload_len: usize = 256 * 1024 * 1024;

pub const DecodeError = error{ Incomplete, InvalidOpcode, FrameTooLarge };

const Header = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    mask_key: [4]u8,
    payload_start: usize,
    payload_len: usize,
};

/// Parse and validate a frame header. Returns error.Incomplete until the whole
/// frame (header + payload) is present in `data`.
fn parseHeader(data: []const u8) DecodeError!Header {
    if (data.len < 2) return error.Incomplete;

    const fin = (data[0] & 0x80) != 0;
    // Reserved opcodes (0x3-0x7, 0xB-0xF) must fail the connection (RFC 6455
    // §5.2); @enumFromInt on them is a safety panic in Debug/ReleaseSafe.
    const opcode = std.enums.fromInt(Opcode, @as(u4, @truncate(data[0]))) orelse
        return error.InvalidOpcode;

    const masked = (data[1] & 0x80) != 0;
    const len7: u7 = @truncate(data[1]);
    var pos: usize = 2;

    var payload_len: usize = undefined;
    if (len7 < 126) {
        payload_len = len7;
    } else if (len7 == 126) {
        if (data.len < pos + 2) return error.Incomplete;
        payload_len = mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    } else {
        if (data.len < pos + 8) return error.Incomplete;
        const len64 = mem.readInt(u64, data[pos..][0..8], .big);
        if (len64 > max_payload_len) return error.FrameTooLarge;
        payload_len = @intCast(len64);
        pos += 8;
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (data.len < pos + 4) return error.Incomplete;
        @memcpy(&mask_key, data[pos .. pos + 4]);
        pos += 4;
    }

    if (data.len - pos < payload_len) return error.Incomplete;

    return .{
        .fin = fin,
        .opcode = opcode,
        .masked = masked,
        .mask_key = mask_key,
        .payload_start = pos,
        .payload_len = payload_len,
    };
}

/// Decode a WebSocket frame from a byte buffer.
/// Returns the decoded frame and number of bytes consumed.
/// The frame payload points into the input buffer (still masked, if it was).
pub fn decodeFrame(data: []const u8) DecodeError!DecodeResult {
    const h = try parseHeader(data);
    return .{
        .frame = .{
            .fin = h.fin,
            .opcode = h.opcode,
            .payload = data[h.payload_start .. h.payload_start + h.payload_len],
        },
        .bytes_consumed = h.payload_start + h.payload_len,
    };
}

/// Decode a frame, unmasking the payload into an allocated buffer if needed.
/// Caller owns the returned payload memory.
pub fn decodeFrameAlloc(allocator: mem.Allocator, data: []const u8) !struct { frame: Frame, bytes_consumed: usize, owned_payload: ?[]u8 } {
    const h = try parseHeader(data);
    const raw = data[h.payload_start .. h.payload_start + h.payload_len];
    const consumed = h.payload_start + h.payload_len;

    if (h.masked) {
        const payload = try allocator.dupe(u8, raw);
        applyMask(payload, h.mask_key);
        return .{
            .frame = .{ .fin = h.fin, .opcode = h.opcode, .payload = payload },
            .bytes_consumed = consumed,
            .owned_payload = payload,
        };
    }
    return .{
        .frame = .{ .fin = h.fin, .opcode = h.opcode, .payload = raw },
        .bytes_consumed = consumed,
        .owned_payload = null,
    };
}

// ---------------------------------------------------------------------------
// WebSocket connection — wraps pure functions with stream I/O
// ---------------------------------------------------------------------------

/// WebSocket connection state.
pub const WebSocket = struct {
    allocator: mem.Allocator,
    io: std.Io,
    stream: ?Stream = null,
    connected: bool = false,
    /// Bytes read from the socket but not yet consumed as a frame. Persisting
    /// this across readFrame calls is what keeps coalesced frames (an event
    /// and a response in one TCP segment) from being dropped.
    rbuf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: mem.Allocator, io: std.Io) WebSocket {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *WebSocket) void {
        self.close();
        self.rbuf.deinit(self.allocator);
    }

    /// Perform HTTP upgrade handshake and establish WebSocket connection.
    pub fn connect(self: *WebSocket, host: []const u8, port: u16, path: []const u8) !void {
        // TCP connect
        self.stream = try tcpConnect(self.io, host, port);
        errdefer {
            if (self.stream) |s| s.close(self.io);
            self.stream = null;
        }

        const stream = self.stream.?;

        // Generate client key
        const client_key = generateClientKey();

        // Build and send HTTP upgrade request
        var req_buf: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &req_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{ path, host, port, &client_key },
        );
        try streamWriteAll(stream, request);

        // Read HTTP response headers
        var resp_buf: [4096]u8 = undefined;
        var resp_len: usize = 0;
        while (resp_len < resp_buf.len) {
            const n = try streamRead(stream, resp_buf[resp_len..]);
            if (n == 0) return error.ConnectionClosed;
            resp_len += n;
            // Check for end of headers
            if (mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n") != null) break;
        }
        const response = resp_buf[0..resp_len];

        // Verify status line contains 101
        const status_end = mem.indexOf(u8, response, "\r\n") orelse return error.InvalidResponse;
        const status_line = response[0..status_end];
        if (mem.indexOf(u8, status_line, "101") == null) return error.UpgradeFailed;

        // Verify Sec-WebSocket-Accept
        const expected_accept = computeAcceptKey(&client_key);
        if (mem.indexOf(u8, response, &expected_accept) == null) return error.InvalidAcceptKey;

        self.connected = true;
    }

    /// Send a text frame (masked, as required for WebSocket clients).
    pub fn sendText(self: *WebSocket, payload: []const u8) !void {
        try self.writeFrame(.text, payload);
    }

    /// Send a pong frame in response to a ping.
    pub fn sendPong(self: *WebSocket, payload: []const u8) !void {
        try self.writeFrame(.pong, payload);
    }

    /// Read the next frame from the connection.
    /// The returned payload is always heap-owned: caller frees owned_payload.
    pub fn readFrame(self: *WebSocket) !ReadResult {
        const stream = self.stream orelse return error.NotConnected;

        while (true) {
            // Frame may already be buffered from a previous read.
            if (parseHeader(self.rbuf.items)) |h| {
                const end = h.payload_start + h.payload_len;
                const payload = try self.allocator.dupe(u8, self.rbuf.items[h.payload_start..end]);
                if (h.masked) applyMask(payload, h.mask_key);
                // Drop the consumed frame, keep any trailing bytes for next call.
                const rest = self.rbuf.items.len - end;
                mem.copyForwards(u8, self.rbuf.items[0..rest], self.rbuf.items[end..]);
                self.rbuf.shrinkRetainingCapacity(rest);
                return .{
                    .frame = .{ .fin = h.fin, .opcode = h.opcode, .payload = payload },
                    .owned_payload = payload,
                };
            } else |err| switch (err) {
                error.Incomplete => {},
                else => return err,
            }

            var read_buf: [8192]u8 = undefined;
            const n = try streamRead(stream, &read_buf);
            if (n == 0) return error.ConnectionClosed;
            try self.rbuf.appendSlice(self.allocator, read_buf[0..n]);
        }
    }

    /// Read the next message, automatically handling control frames.
    /// Responds to pings with pongs. Returns on text/binary/close frames.
    /// Caller must free owned_payload if non-null.
    pub fn readMessage(self: *WebSocket) !ReadResult {
        while (true) {
            const result = try self.readFrame();
            switch (result.frame.opcode) {
                .ping => {
                    // Auto-respond with pong
                    self.sendPong(result.frame.payload) catch {};
                    if (result.owned_payload) |p| self.allocator.free(p);
                    continue;
                },
                .pong => {
                    // Ignore unsolicited pongs
                    if (result.owned_payload) |p| self.allocator.free(p);
                    continue;
                },
                .close => {
                    self.connected = false;
                    return result;
                },
                else => return result,
            }
        }
    }

    /// Send a close frame and shut down the connection.
    pub fn close(self: *WebSocket) void {
        if (self.stream) |stream| {
            // Try to send close frame (best-effort)
            if (self.connected) {
                var close_buf: [14]u8 = undefined; // 2 header + 4 mask + up to 8 payload
                const close_frame = encodeFrame(&close_buf, .close, &.{}, true) catch null;
                if (close_frame) |frame| {
                    streamWriteAll(stream, frame) catch {};
                }
            }
            stream.close(self.io);
            self.stream = null;
        }
        self.connected = false;
        self.rbuf.clearRetainingCapacity();
    }

    // Internal helper: encode and send a frame with masking.
    fn writeFrame(self: *WebSocket, opcode: Opcode, payload: []const u8) !void {
        const stream = self.stream orelse return error.NotConnected;
        if (!self.connected) return error.NotConnected;

        // Allocate buffer for frame
        const max_header = 2 + 8 + 4;
        const buf = try self.allocator.alloc(u8, max_header + payload.len);
        defer self.allocator.free(buf);

        const frame_bytes = try encodeFrame(buf, opcode, payload, true);
        try streamWriteAll(stream, frame_bytes);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Opcode values match RFC 6455" {
    try std.testing.expectEqual(@as(u4, 0x1), @backingInt(Opcode.text));
    try std.testing.expectEqual(@as(u4, 0x2), @backingInt(Opcode.binary));
    try std.testing.expectEqual(@as(u4, 0x8), @backingInt(Opcode.close));
    try std.testing.expectEqual(@as(u4, 0x9), @backingInt(Opcode.ping));
    try std.testing.expectEqual(@as(u4, 0xA), @backingInt(Opcode.pong));
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
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var ws = WebSocket.init(allocator, threaded.io());
    defer ws.deinit();
    try std.testing.expect(!ws.connected);
    try std.testing.expect(ws.stream == null);
}

test "generateMaskingKey returns 4 bytes" {
    const key = generateMaskingKey();
    try std.testing.expectEqual(@as(usize, 4), key.len);
}

test "computeAcceptKey matches RFC 6455 example" {
    // RFC 6455 Section 4.2.2 test vector:
    // Client key: "dGhlIHNhbXBsZSBub25jZQ=="
    // Expected accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = computeAcceptKey(client_key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "generateClientKey produces 24-char base64" {
    const key = generateClientKey();
    try std.testing.expectEqual(@as(usize, 24), key.len);
    // Verify all chars are valid base64
    for (key) |c| {
        try std.testing.expect(
            (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '+' or c == '/' or c == '=',
        );
    }
}

test "encodeFrame short unmasked text" {
    var buf: [256]u8 = undefined;
    const payload = "Hello";
    const frame_bytes = try encodeFrame(&buf, .text, payload, false);

    // FIN=1, opcode=text(1) → 0x81
    try std.testing.expectEqual(@as(u8, 0x81), frame_bytes[0]);
    // No mask bit, length=5
    try std.testing.expectEqual(@as(u8, 5), frame_bytes[1]);
    // Payload follows directly
    try std.testing.expectEqualStrings("Hello", frame_bytes[2..7]);
    try std.testing.expectEqual(@as(usize, 7), frame_bytes.len);
}

test "encodeFrame short masked text" {
    var buf: [256]u8 = undefined;
    const payload = "Hello";
    const frame_bytes = try encodeFrame(&buf, .text, payload, true);

    // FIN=1, opcode=text(1) → 0x81
    try std.testing.expectEqual(@as(u8, 0x81), frame_bytes[0]);
    // Mask bit set, length=5 → 0x85
    try std.testing.expectEqual(@as(u8, 0x85), frame_bytes[1]);
    // 4 bytes mask key + 5 bytes masked payload = 11 total after header
    try std.testing.expectEqual(@as(usize, 2 + 4 + 5), frame_bytes.len);

    // Verify we can unmask to get original payload
    const mask_key: [4]u8 = frame_bytes[2..6].*;
    var unmasked: [5]u8 = undefined;
    @memcpy(&unmasked, frame_bytes[6..11]);
    applyMask(&unmasked, mask_key);
    try std.testing.expectEqualStrings("Hello", &unmasked);
}

test "encodeFrame medium payload uses 2-byte extended length" {
    var buf: [70000]u8 = undefined;
    // 200 bytes of payload (>= 126, < 65536)
    const payload_buf: [200]u8 = @splat('x');
    const payload = &payload_buf;
    const frame_bytes = try encodeFrame(&buf, .text, payload, false);

    try std.testing.expectEqual(@as(u8, 0x81), frame_bytes[0]);
    // Length field = 126 (indicates 2-byte extended)
    try std.testing.expectEqual(@as(u8, 126), frame_bytes[1]);
    // Extended length in big-endian
    const ext_len = mem.readInt(u16, frame_bytes[2..4], .big);
    try std.testing.expectEqual(@as(u16, 200), ext_len);
    // Total: 2 header + 2 extended + 200 payload
    try std.testing.expectEqual(@as(usize, 204), frame_bytes.len);
}

test "decodeFrame unmasked text" {
    // Build a simple unmasked text frame: 0x81, 0x05, "Hello"
    const frame_data = [_]u8{ 0x81, 0x05 } ++ "Hello".*;
    const result = try decodeFrame(&frame_data);
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
    try std.testing.expectEqual(@as(usize, 7), result.bytes_consumed);
}

test "decodeFrame masked text" {
    const allocator = std.testing.allocator;
    // Build a masked frame manually
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var masked_payload = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    applyMask(&masked_payload, mask);

    var frame_data: [11]u8 = undefined;
    frame_data[0] = 0x81; // FIN + text
    frame_data[1] = 0x85; // masked + len 5
    @memcpy(frame_data[2..6], &mask);
    @memcpy(frame_data[6..11], &masked_payload);

    const result = try decodeFrameAlloc(allocator, &frame_data);
    defer if (result.owned_payload) |p| allocator.free(p);

    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
}

test "decodeFrame returns Incomplete for truncated data" {
    const short = [_]u8{0x81}; // Only 1 byte, need at least 2
    try std.testing.expectError(error.Incomplete, decodeFrame(&short));
}

test "frame encode then decode round-trip" {
    const allocator = std.testing.allocator;
    const payload = "Hello, WebSocket!";

    // Encode masked
    var buf: [256]u8 = undefined;
    const encoded = try encodeFrame(&buf, .text, payload, true);

    // Decode with allocation (handles unmasking)
    const result = try decodeFrameAlloc(allocator, encoded);
    defer if (result.owned_payload) |p| allocator.free(p);

    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings(payload, result.frame.payload);
}

test "frame encode then decode round-trip unmasked" {
    var buf: [256]u8 = undefined;
    const payload = "No mask needed";
    const encoded = try encodeFrame(&buf, .text, payload, false);
    const result = try decodeFrame(encoded);

    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings(payload, result.frame.payload);
}

test "encodeFrame ping frame" {
    var buf: [256]u8 = undefined;
    const frame_bytes = try encodeFrame(&buf, .ping, &.{}, false);
    try std.testing.expectEqual(@as(u8, 0x89), frame_bytes[0]); // FIN + ping
    try std.testing.expectEqual(@as(u8, 0), frame_bytes[1]); // no mask, len 0
    try std.testing.expectEqual(@as(usize, 2), frame_bytes.len);
}

test "encodeFrame close frame" {
    var buf: [256]u8 = undefined;
    const frame_bytes = try encodeFrame(&buf, .close, &.{}, true);
    try std.testing.expectEqual(@as(u8, 0x88), frame_bytes[0]); // FIN + close
    try std.testing.expectEqual(@as(u8, 0x80), frame_bytes[1]); // masked, len 0
    // 4 bytes mask key, no payload
    try std.testing.expectEqual(@as(usize, 6), frame_bytes.len);
}

// --- readFrame over a real socket: peer close, coalescing, hostile headers ---

const test_c = struct {
    extern "c" fn socketpair(domain: c_int, sock_type: c_int, protocol: c_int, sv: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
};

const TestPair = struct {
    threaded: std.Io.Threaded,
    sock: WebSocket,
    fd: c_int,

    /// Peer writes `bytes` then hangs up; returns the client side.
    fn init(self: *TestPair, bytes: []const u8) !void {
        const gpa = std.testing.allocator;
        self.threaded = .init(gpa, .{});
        var sv: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), test_c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sv));
        if (bytes.len > 0) _ = test_c.write(sv[1], bytes.ptr, bytes.len);
        _ = test_c.close(sv[1]);
        self.fd = sv[0];
        self.sock = WebSocket.init(gpa, self.threaded.io());
        self.sock.stream = .{ .socket = .{ .handle = sv[0], .address = .{ .ip4 = .loopback(0) } } };
        self.sock.connected = true;
    }

    fn deinit(self: *TestPair) void {
        self.sock.stream = null;
        self.sock.deinit();
        _ = test_c.close(self.fd);
        self.threaded.deinit();
    }
};

fn testEofAfter(prefix: []const u8) !void {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var sv: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), test_c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sv));
    defer _ = test_c.close(sv[0]);

    if (prefix.len > 0) _ = test_c.write(sv[1], prefix.ptr, prefix.len);
    _ = test_c.close(sv[1]); // peer goes away: Chrome closed the tab / quit

    var sock = WebSocket.init(gpa, threaded.io());
    sock.stream = .{ .socket = .{ .handle = sv[0], .address = .{ .ip4 = .loopback(0) } } };
    sock.connected = true;

    try std.testing.expectError(error.ConnectionClosed, sock.readFrame());
    sock.stream = null; // fd closed by defer above
    sock.deinit();
}

test "peer closes before any frame bytes (idle cached CDP connection)" {
    try testEofAfter("");
}

test "peer closes mid-frame (large base64 response cut off)" {
    // 0x81 = FIN|text, 0x7f = 64-bit length follows; claim 1 MiB, send 4 bytes.
    try testEofAfter(&[_]u8{ 0x81, 0x7f, 0, 0, 0, 0, 0, 0x10, 0, 0, 'A', 'A', 'A', 'A' });
}

test "two frames delivered in one read: second must not be dropped" {
    // Chrome routinely coalesces an event + a response into one TCP segment.
    var p: TestPair = undefined;
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
    var p: TestPair = undefined;
    try p.init(&[_]u8{ 0x83, 0 });
    defer p.deinit();
    try std.testing.expectError(error.InvalidOpcode, p.sock.readFrame());
}

test "64-bit length near maxInt is an error, not an overflow panic" {
    var p: TestPair = undefined;
    try p.init(&[_]u8{ 0x81, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf0 });
    defer p.deinit();
    try std.testing.expectError(error.FrameTooLarge, p.sock.readFrame());
}
