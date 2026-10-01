///! Marionette protocol client for Firefox.
///!
///! Marionette uses length-prefixed JSON over TCP:
///!   → 85:[0,1,"WebDriver:NewSession",{"capabilities":{}}]
///!   ← 234:[1,1,null,{"sessionId":"abc","capabilities":{...}}]
///!
///! Wire format: {length}:{json_array}
///! Request:  [0, id, "CommandName", {params}]   (type 0 = incoming)
///! Response: [1, id, null, {result}]             (success)
///! Response: [1, id, {error}, null]              (error)
///!
///! Firefox sends the handshake unprompted on TCP connect:
///!   48:{"marionetteProtocol":3,"applicationType":"gecko"}
const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;

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

/// Marionette handshake data sent by Firefox on connect.
pub const Handshake = struct {
    protocol: u16,
    application_type: []const u8,
};

/// Result of a Marionette command.
pub const MarionetteResult = struct {
    parsed: json.Parsed(json.Value),
    result: json.Value,
    err: ?[]const u8 = null,

    pub fn deinit(self: *MarionetteResult) void {
        self.parsed.deinit();
    }
};

/// Eval result matching cdp.EvalResult interface.
pub const EvalResult = struct {
    value: json.Value = .null,
    exception: ?[]const u8 = null,
};

/// Marionette TCP connection to Firefox.
pub const Connection = struct {
    allocator: mem.Allocator,
    io: std.Io,
    stream: ?Stream = null,
    next_id: u32 = 1,
    session_id: ?[]const u8 = null,

    pub fn init(allocator: mem.Allocator, io: std.Io) Connection {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Connection) void {
        if (self.session_id) |sid| self.allocator.free(sid);
        if (self.stream) |s| s.close(self.io);
    }

    /// Connect to Firefox Marionette on the given port.
    /// Reads the handshake and creates a session.
    pub fn connect(self: *Connection, port: u16) !void {
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        self.stream = try addr.connect(self.io, .{ .mode = .stream });

        // Read handshake (Firefox sends it unprompted)
        _ = try self.readHandshake();

        // Create session
        try self.newSession();
    }

    /// Read the Marionette handshake.
    fn readHandshake(self: *Connection) !Handshake {
        const msg = try self.readLengthPrefixed();
        defer self.allocator.free(msg);

        const parsed = try json.parseFromSlice(json.Value, self.allocator, msg, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidHandshake;
        const obj = parsed.value.object;

        const proto_val = obj.get("marionetteProtocol") orelse return error.InvalidHandshake;
        if (proto_val != .integer) return error.InvalidHandshake;

        const app_val = obj.get("applicationType") orelse return error.InvalidHandshake;
        if (app_val != .string) return error.InvalidHandshake;
        if (!mem.eql(u8, app_val.string, "gecko")) return error.InvalidHandshake;

        return .{
            .protocol = @intCast(proto_val.integer),
            .application_type = "gecko",
        };
    }

    /// Create a new Marionette session.
    fn newSession(self: *Connection) !void {
        var result = try self.send("WebDriver:NewSession", .null);
        defer result.deinit();

        // Extract sessionId from result
        if (result.result == .object) {
            if (result.result.object.get("sessionId")) |sid| {
                if (sid == .string) {
                    if (self.session_id) |old| self.allocator.free(old);
                    self.session_id = try self.allocator.dupe(u8, sid.string);
                    return;
                }
            }
        }
        return error.SessionCreateFailed;
    }

    /// Send a Marionette command and wait for the response.
    pub fn send(self: *Connection, method: []const u8, params: json.Value) !MarionetteResult {
        const s = self.stream orelse return error.NotConnected;
        const id = self.next_id;
        self.next_id += 1;

        // Build: [0, id, "method", params]
        const params_json = try json.Stringify.valueAlloc(self.allocator, params, .{});
        defer self.allocator.free(params_json);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "[0,{d},\"{s}\",{s}]",
            .{ id, method, params_json },
        );
        defer self.allocator.free(payload);

        // Length-prefix and send
        const msg = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ payload.len, payload });
        defer self.allocator.free(msg);

        try streamWriteAll(s, msg);

        // Read response
        const resp_data = try self.readLengthPrefixed();
        defer self.allocator.free(resp_data);

        // Parse: [1, id, error_or_null, result_or_null]
        const parsed = try json.parseFromSlice(json.Value, self.allocator, resp_data, .{});

        if (parsed.value != .array) {
            parsed.deinit();
            return error.InvalidResponse;
        }
        const arr = parsed.value.array;
        if (arr.items.len != 4) {
            parsed.deinit();
            return error.InvalidResponse;
        }

        // arr[0] = 1 (outgoing), arr[1] = id, arr[2] = error, arr[3] = result
        const resp_id = arr.items[1];
        if (resp_id != .integer or @as(u32, @intCast(resp_id.integer)) != id) {
            parsed.deinit();
            return error.ResponseIdMismatch;
        }

        const err_val = arr.items[2];
        const result_val = arr.items[3];

        if (err_val != .null) {
            // Error response
            return .{
                .parsed = parsed,
                .result = err_val,
                .err = if (err_val == .object)
                    if (err_val.object.get("error")) |e|
                        if (e == .string) e.string else null
                    else
                        null
                else
                    null,
            };
        }

        return .{
            .parsed = parsed,
            .result = result_val,
        };
    }

    /// Evaluate JavaScript in the current context.
    /// The expression is auto-wrapped with `return (...)` since Marionette's
    /// ExecuteScript runs the script as a function body.
    pub fn eval(self: *Connection, expression: []const u8) !EvalResult {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);

        // Use indirect eval (0,eval)() so multi-statement code works.
        // Indirect eval runs in global scope, avoiding strict-mode restrictions.
        // JSON-encode the expression to safely embed it as a string literal.
        const expr_json = try json.Stringify.valueAlloc(self.allocator, json.Value{ .string = expression }, .{});
        defer self.allocator.free(expr_json);

        const script = try std.fmt.allocPrint(self.allocator, "return (0,eval)({s})", .{expr_json});
        defer self.allocator.free(script);

        try params.put(self.allocator, "script", .{ .string = script });
        var args_arr = json.Array.init(self.allocator);
        defer args_arr.deinit();
        try params.put(self.allocator, "args", .{ .array = args_arr });

        var result = try self.send("WebDriver:ExecuteScript", .{ .object = params });
        defer result.deinit();

        if (result.err) |e| {
            return .{ .exception = try self.allocator.dupe(u8, e) };
        }

        // Marionette returns {"value": <result>}
        if (result.result == .object) {
            if (result.result.object.get("value")) |val| {
                return .{ .value = try cloneJsonValue(self.allocator, val) };
            }
        }

        return .{};
    }

    /// Navigate to a URL.
    pub fn navigate(self: *Connection, url: []const u8) !void {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "url", .{ .string = url });

        var result = try self.send("WebDriver:Navigate", .{ .object = params });
        defer result.deinit();

        if (result.err) |_| return error.NavigateFailed;
    }

    /// Get the current URL.
    pub fn getCurrentUrl(self: *Connection) ![]const u8 {
        var result = try self.send("WebDriver:GetCurrentURL", .null);
        defer result.deinit();

        if (result.result == .object) {
            if (result.result.object.get("value")) |val| {
                if (val == .string) {
                    return try self.allocator.dupe(u8, val.string);
                }
            }
        }
        return error.NoUrl;
    }

    /// Get the page title.
    pub fn getTitle(self: *Connection) ![]const u8 {
        var result = try self.send("WebDriver:GetTitle", .null);
        defer result.deinit();

        if (result.result == .object) {
            if (result.result.object.get("value")) |val| {
                if (val == .string) {
                    return try self.allocator.dupe(u8, val.string);
                }
            }
        }
        return error.NoTitle;
    }

    /// Ask Firefox to quit cleanly via Marionette:Quit.
    pub fn quit(self: *Connection) !void {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        var flags = json.Array.init(self.allocator);
        defer flags.deinit();
        try flags.append(.{ .string = "eForceQuit" });
        try params.put(self.allocator, "flags", .{ .array = flags });

        // Firefox closes the connection after quitting, so ignore read errors.
        _ = self.send("Marionette:Quit", .{ .object = params }) catch {};
    }

    /// Take a screenshot. Returns base64-encoded PNG data.
    /// Attempts full-page first; if Firefox fails (page too tall for canvas),
    /// falls back to viewport-only screenshot.
    pub fn takeScreenshot(self: *Connection) ![]const u8 {
        // Try full-page screenshot first
        {
            var params: json.ObjectMap = .empty;
            defer params.deinit(self.allocator);
            try params.put(self.allocator, "full", .{ .bool = true });

            var result = try self.send("WebDriver:TakeScreenshot", .{ .object = params });
            defer result.deinit();

            if (result.err == null) {
                if (result.result == .object) {
                    if (result.result.object.get("value")) |val| {
                        if (val == .string) return try self.allocator.dupe(u8, val.string);
                    }
                }
            }
            // Full-page failed (likely page too tall for Firefox canvas limit ~30000px),
            // fall through to viewport-only attempt.
        }

        // Fallback: viewport-only screenshot
        var result = try self.send("WebDriver:TakeScreenshot", .null);
        defer result.deinit();

        if (result.err) |_| return error.CommandFailed;

        if (result.result == .object) {
            if (result.result.object.get("value")) |val| {
                if (val == .string) return try self.allocator.dupe(u8, val.string);
            }
        }
        return error.InvalidResponse;
    }

    /// Get list of window handles (tabs).
    pub fn getWindowHandles(self: *Connection) ![][]const u8 {
        var result = try self.send("WebDriver:GetWindowHandles", .null);
        defer result.deinit();

        if (result.err) |_| return error.CommandFailed;

        // Result is an array of handle strings
        if (result.result != .array) return error.InvalidResponse;
        const arr = result.result.array;

        var handles: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (handles.items) |h| self.allocator.free(h);
            handles.deinit(self.allocator);
        }

        for (arr.items) |item| {
            if (item == .string) {
                try handles.append(self.allocator, try self.allocator.dupe(u8, item.string));
            }
        }

        return try handles.toOwnedSlice(self.allocator);
    }

    /// Get the current window handle.
    pub fn getWindowHandle(self: *Connection) ![]const u8 {
        var result = try self.send("WebDriver:GetWindowHandle", .null);
        defer result.deinit();

        if (result.err) |_| return error.CommandFailed;
        if (result.result == .object) {
            if (result.result.object.get("value")) |val| {
                if (val == .string) return try self.allocator.dupe(u8, val.string);
            }
        }
        if (result.result == .string) return try self.allocator.dupe(u8, result.result.string);
        return error.InvalidResponse;
    }

    /// Switch to a window/tab by handle.
    pub fn switchToWindow(self: *Connection, handle: []const u8) !void {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "handle", .{ .string = handle });

        var result = try self.send("WebDriver:SwitchToWindow", .{ .object = params });
        defer result.deinit();

        if (result.err) |_| return error.CommandFailed;
    }

    /// Open a new tab/window. Returns the new handle.
    pub fn newWindow(self: *Connection, window_type: []const u8) ![]const u8 {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "type", .{ .string = window_type });

        var result = try self.send("WebDriver:NewWindow", .{ .object = params });
        defer result.deinit();

        if (result.err) |_| return error.CommandFailed;

        // Returns {"handle": "...", "type": "tab"|"window"}
        if (result.result == .object) {
            if (result.result.object.get("handle")) |val| {
                if (val == .string) return try self.allocator.dupe(u8, val.string);
            }
        }
        return error.InvalidResponse;
    }

    /// Close the current window/tab.
    pub fn closeWindow(self: *Connection) !void {
        var result = try self.send("WebDriver:CloseWindow", .null);
        defer result.deinit();
        // Ignore errors — if it was the last window, connection drops
    }

    // -----------------------------------------------------------------------
    // Wire protocol helpers
    // -----------------------------------------------------------------------

    /// Read a length-prefixed message: "{digits}:{payload}"
    /// Caller owns the returned payload slice.
    fn readLengthPrefixed(self: *Connection) ![]u8 {
        const s = self.stream orelse return error.NotConnected;

        // Read digits until ':'
        var length: usize = 0;
        var buf: [1]u8 = undefined;
        while (true) {
            const n = try streamRead(s, &buf);
            if (n == 0) return error.ConnectionClosed;
            const ch = buf[0];
            if (ch == ':') break;
            if (ch >= '0' and ch <= '9') {
                length = length * 10 + (ch - '0');
            } else {
                return error.InvalidFraming;
            }
        }

        if (length == 0) return error.EmptyMessage;

        // Read exactly `length` bytes
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);

        var total: usize = 0;
        while (total < length) {
            const n = try streamRead(s, payload[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        return payload;
    }
};

/// Deep-clone a json.Value so it outlives its parsed source.
fn cloneJsonValue(allocator: mem.Allocator, val: json.Value) !json.Value {
    switch (val) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key, value);
            }
            return .{ .object = new_obj };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Connection struct initializes" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var conn = Connection.init(allocator, threaded.io());
    defer conn.deinit();
    try std.testing.expect(conn.stream == null);
    try std.testing.expect(conn.session_id == null);
    try std.testing.expectEqual(@as(u32, 1), conn.next_id);
}

test "cloneJsonValue clones primitives" {
    const allocator = std.testing.allocator;

    const null_val = try cloneJsonValue(allocator, .null);
    try std.testing.expect(null_val == .null);

    const bool_val = try cloneJsonValue(allocator, .{ .bool = true });
    try std.testing.expect(bool_val == .bool);
    try std.testing.expect(bool_val.bool == true);

    const int_val = try cloneJsonValue(allocator, .{ .integer = 42 });
    try std.testing.expect(int_val == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);

    const str_val = try cloneJsonValue(allocator, .{ .string = "hello" });
    defer allocator.free(str_val.string);
    try std.testing.expectEqualStrings("hello", str_val.string);
}
