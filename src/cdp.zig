///! Chrome DevTools Protocol (CDP) client.
///!
///! Two-phase communication:
///! 1. HTTP GET to http://localhost:{port}/json for target discovery
///! 2. WebSocket connection to a target's webSocketDebuggerUrl for commands
///!
///! All CDP messages are JSON with incrementing integer IDs.
const std = @import("std");
const mem = std.mem;
const json = std.json;
const websocket = @import("websocket.zig");

/// A CDP target (tab/page) as returned by /json endpoint.
pub const Target = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    @"type": []const u8,
    webSocketDebuggerUrl: ?[]const u8 = null,
};

/// CDP version info from /json/version.
pub const VersionInfo = struct {
    browser: []const u8 = "",
    protocol_version: []const u8 = "",
    user_agent: []const u8 = "",
    v8_version: []const u8 = "",
    webkit_version: []const u8 = "",
    webSocketDebuggerUrl: ?[]const u8 = null,
};

/// CDP command result.
pub const EvalResult = struct {
    value: json.Value = .null,
    exception: ?[]const u8 = null,
};

/// Owns parsed CDP response data. Fields in the result reference this memory.
pub const CdpResult = struct {
    parsed: json.Parsed(json.Value),
    result: json.Value,

    pub fn deinit(self: *CdpResult) void {
        self.parsed.deinit();
    }
};

/// Parsed WebSocket URL components.
pub const WsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a ws:// URL into host, port, path components.
/// The returned slices borrow from the input url.
pub fn parseWsUrl(url: []const u8) !WsUrl {
    const scheme = "ws://";
    if (!mem.startsWith(u8, url, scheme)) return error.InvalidUrl;
    const after_scheme = url[scheme.len..];

    // Find "/" separating host:port from path
    const slash_pos = mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidUrl;
    const host_port = after_scheme[0..slash_pos];
    const path = after_scheme[slash_pos..];

    // Split host:port
    const colon_pos = mem.indexOfScalar(u8, host_port, ':') orelse return error.InvalidUrl;
    const host = host_port[0..colon_pos];
    if (host.len == 0) return error.InvalidUrl;
    const port = std.fmt.parseInt(u16, host_port[colon_pos + 1 ..], 10) catch return error.InvalidUrl;

    return .{ .host = host, .port = port, .path = path };
}

// ---------------------------------------------------------------------------
// HTTP Discovery
// ---------------------------------------------------------------------------

/// Discover targets by hitting http://127.0.0.1:{port}/json.
/// Caller owns the returned slice and all strings within. Free with freeTargets().
pub fn discoverTargets(allocator: mem.Allocator, port: u16) ![]Target {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json", .{port});
    const body = try httpGet(allocator, url);
    defer allocator.free(body);

    // Parse JSON array
    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidResponse;
    const arr = parsed.value.array;

    var targets: std.ArrayList(Target) = .{};
    defer targets.deinit(allocator);

    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const id = obj.get("id") orelse continue;
        if (id != .string) continue;
        const title_val = obj.get("title") orelse continue;
        if (title_val != .string) continue;
        const url_val = obj.get("url") orelse continue;
        if (url_val != .string) continue;
        const type_val = obj.get("type") orelse continue;
        if (type_val != .string) continue;

        const ws_url = if (obj.get("webSocketDebuggerUrl")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;
        errdefer if (ws_url) |w| allocator.free(w);

        try targets.append(allocator, .{
            .id = try allocator.dupe(u8, id.string),
            .title = try allocator.dupe(u8, title_val.string),
            .url = try allocator.dupe(u8, url_val.string),
            .@"type" = try allocator.dupe(u8, type_val.string),
            .webSocketDebuggerUrl = ws_url,
        });
    }

    return try targets.toOwnedSlice(allocator);
}

/// Free a targets slice returned by discoverTargets().
pub fn freeTargets(allocator: mem.Allocator, targets: []Target) void {
    for (targets) |t| {
        allocator.free(t.id);
        allocator.free(t.title);
        allocator.free(t.url);
        allocator.free(t.@"type");
        if (t.webSocketDebuggerUrl) |ws| allocator.free(ws);
    }
    allocator.free(targets);
}

/// Get browser version info from http://127.0.0.1:{port}/json/version.
/// Caller owns all strings in the returned struct. Free with freeVersionInfo().
pub fn getVersion(allocator: mem.Allocator, port: u16) !VersionInfo {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/version", .{port});
    const body = try httpGet(allocator, url);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;

    return .{
        .browser = try dupeJsonString(allocator, obj, "Browser"),
        .protocol_version = try dupeJsonString(allocator, obj, "Protocol-Version"),
        .user_agent = try dupeJsonString(allocator, obj, "User-Agent"),
        .v8_version = try dupeJsonString(allocator, obj, "V8-Version"),
        .webkit_version = try dupeJsonString(allocator, obj, "WebKit-Version"),
        .webSocketDebuggerUrl = if (obj.get("webSocketDebuggerUrl")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null,
    };
}

/// Free a VersionInfo returned by getVersion().
pub fn freeVersionInfo(allocator: mem.Allocator, info: VersionInfo) void {
    if (info.browser.len > 0) allocator.free(info.browser);
    if (info.protocol_version.len > 0) allocator.free(info.protocol_version);
    if (info.user_agent.len > 0) allocator.free(info.user_agent);
    if (info.v8_version.len > 0) allocator.free(info.v8_version);
    if (info.webkit_version.len > 0) allocator.free(info.webkit_version);
    if (info.webSocketDebuggerUrl) |ws| allocator.free(ws);
}

// ---------------------------------------------------------------------------
// CDP Connection — WebSocket commands
// ---------------------------------------------------------------------------

/// A CDP client connection to a single target (page/tab).
pub const Connection = struct {
    allocator: mem.Allocator,
    ws: websocket.WebSocket,
    /// Next message ID (CDP uses incrementing integers).
    next_id: u64 = 1,

    pub fn init(allocator: mem.Allocator) Connection {
        return .{
            .allocator = allocator,
            .ws = websocket.WebSocket.init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.ws.deinit();
    }

    /// Connect to a target by its webSocketDebuggerUrl.
    pub fn connect(self: *Connection, ws_url: []const u8) !void {
        const parsed = try parseWsUrl(ws_url);
        try self.ws.connect(parsed.host, parsed.port, parsed.path);
    }

    /// Send a CDP command and wait for the matching response.
    /// Returns a CdpResult that owns the parsed response. Caller must deinit.
    pub fn send(self: *Connection, method: []const u8, params: ?json.Value) !CdpResult {
        const id = self.next_id;
        self.next_id += 1;

        // Build CDP message
        const msg_json = try buildCdpMessage(self.allocator, id, method, params);
        defer self.allocator.free(msg_json);

        // Send over WebSocket
        try self.ws.sendText(msg_json);

        // Read frames until we get a response with matching id
        while (true) {
            const read_result = try self.ws.readMessage();
            defer if (read_result.owned_payload) |p| self.allocator.free(p);

            if (read_result.frame.opcode == .close) return error.ConnectionClosed;
            if (read_result.frame.opcode != .text) continue;

            const parsed = json.parseFromSlice(
                json.Value,
                self.allocator,
                read_result.frame.payload,
                .{},
            ) catch continue; // Skip unparseable messages

            // Check if this is our response (has matching id)
            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |id_val| {
                    if (id_val == .integer and @as(u64, @intCast(id_val.integer)) == id) {
                        // Check for CDP error
                        if (parsed.value.object.get("error")) |_| {
                            return .{
                                .parsed = parsed,
                                .result = parsed.value,
                            };
                        }
                        // Success — return the result field
                        const result = parsed.value.object.get("result") orelse .null;
                        return .{
                            .parsed = parsed,
                            .result = result,
                        };
                    }
                }
            }
            // Not our response (probably an event) — discard and keep reading
            parsed.deinit();
        }
    }

    /// Evaluate JavaScript in the connected target.
    pub fn eval(self: *Connection, expression: []const u8) !EvalResult {
        // Build params: {"expression": ..., "returnByValue": true}
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();
        try params_obj.put("expression", .{ .string = expression });
        try params_obj.put("returnByValue", .{ .bool = true });

        var cdp_result = try self.send("Runtime.evaluate", .{ .object = params_obj });
        defer cdp_result.deinit();

        // CDP returns {"result": {"result": {"type": "...", "value": ...}, "exceptionDetails": {...}}}
        if (cdp_result.result == .object) {
            const result_obj = cdp_result.result.object;

            // Check for exception
            if (result_obj.get("exceptionDetails")) |exception| {
                if (exception == .object) {
                    if (exception.object.get("text")) |text| {
                        if (text == .string) {
                            return .{
                                .exception = try self.allocator.dupe(u8, text.string),
                            };
                        }
                    }
                }
                return .{ .exception = try self.allocator.dupe(u8, "Unknown exception") };
            }

            // Extract result value
            if (result_obj.get("result")) |inner_result| {
                if (inner_result == .object) {
                    if (inner_result.object.get("value")) |val| {
                        // Clone the value so it outlives the parsed response
                        return .{ .value = try cloneJsonValue(self.allocator, val) };
                    }
                }
            }
        }

        return .{};
    }

    /// Navigate the connected target to a URL.
    pub fn navigate(self: *Connection, url: []const u8) !void {
        var params_obj = json.ObjectMap.init(self.allocator);
        defer params_obj.deinit();
        try params_obj.put("url", .{ .string = url });

        var cdp_result = try self.send("Page.navigate", .{ .object = params_obj });
        defer cdp_result.deinit();
    }

    /// Get the current URL of the connected target.
    pub fn getUrl(self: *Connection) ![]u8 {
        var cdp_result = try self.send("Runtime.evaluate", blk: {
            var params_obj = json.ObjectMap.init(self.allocator);
            try params_obj.put("expression", .{ .string = "window.location.href" });
            try params_obj.put("returnByValue", .{ .bool = true });
            break :blk .{ .object = params_obj };
        });
        defer cdp_result.deinit();

        if (cdp_result.result == .object) {
            if (cdp_result.result.object.get("result")) |inner| {
                if (inner == .object) {
                    if (inner.object.get("value")) |val| {
                        if (val == .string) {
                            return try self.allocator.dupe(u8, val.string);
                        }
                    }
                }
            }
        }
        return error.InvalidResponse;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build a CDP JSON message string.
fn buildCdpMessage(allocator: mem.Allocator, id: u64, method: []const u8, params: ?json.Value) ![]u8 {
    // Build as json.Value manually for correct serialization
    var msg_obj = json.ObjectMap.init(allocator);
    defer msg_obj.deinit();
    try msg_obj.put("id", .{ .integer = @intCast(id) });
    try msg_obj.put("method", .{ .string = method });
    if (params) |p| {
        try msg_obj.put("params", p);
    }

    return try json.Stringify.valueAlloc(allocator, json.Value{ .object = msg_obj }, .{});
}

/// Deep clone a json.Value into owned memory.
fn cloneJsonValue(allocator: mem.Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = json.Array.init(allocator);
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                try new_obj.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// HTTP GET a URL and return the body as an allocated string.
fn httpGet(allocator: mem.Allocator, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &body_writer.writer,
    });

    if (result.status != .ok) return error.HttpError;
    return try body_writer.toOwnedSlice();
}

/// Extract a string value from a JSON object, duping it into owned memory.
/// Returns empty string if the key is missing or not a string.
fn dupeJsonString(allocator: mem.Allocator, obj: json.ObjectMap, key: []const u8) ![]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return try allocator.dupe(u8, val.string);
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Target struct has expected fields" {
    const t = Target{
        .id = "ABC123",
        .title = "Example",
        .url = "https://example.com",
        .@"type" = "page",
        .webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/ABC123",
    };
    try std.testing.expectEqualStrings("ABC123", t.id);
    try std.testing.expectEqualStrings("page", t.@"type");
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/ABC123", t.webSocketDebuggerUrl.?);
}

test "Connection initializes with id 1" {
    const allocator = std.testing.allocator;
    var conn = Connection.init(allocator);
    defer conn.deinit();
    try std.testing.expectEqual(@as(u64, 1), conn.next_id);
}

test "EvalResult defaults to null value" {
    const result = EvalResult{};
    try std.testing.expect(result.value == .null);
    try std.testing.expect(result.exception == null);
}

test "parseWsUrl extracts components" {
    const result = try parseWsUrl("ws://127.0.0.1:9222/devtools/page/ABC123");
    try std.testing.expectEqualStrings("127.0.0.1", result.host);
    try std.testing.expectEqual(@as(u16, 9222), result.port);
    try std.testing.expectEqualStrings("/devtools/page/ABC123", result.path);
}

test "parseWsUrl with different port" {
    const result = try parseWsUrl("ws://localhost:12345/path");
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 12345), result.port);
    try std.testing.expectEqualStrings("/path", result.path);
}

test "parseWsUrl rejects missing scheme" {
    try std.testing.expectError(error.InvalidUrl, parseWsUrl("http://127.0.0.1:9222/"));
}

test "parseWsUrl rejects missing port" {
    try std.testing.expectError(error.InvalidUrl, parseWsUrl("ws://127.0.0.1/path"));
}

test "parseWsUrl rejects missing path" {
    try std.testing.expectError(error.InvalidUrl, parseWsUrl("ws://127.0.0.1:9222"));
}

test "parseWsUrl rejects empty host" {
    try std.testing.expectError(error.InvalidUrl, parseWsUrl("ws://:9222/path"));
}

test "buildCdpMessage produces valid JSON" {
    const allocator = std.testing.allocator;
    const msg = try buildCdpMessage(allocator, 1, "Runtime.evaluate", null);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("Runtime.evaluate", obj.get("method").?.string);
}

test "buildCdpMessage with params" {
    const allocator = std.testing.allocator;

    var params = json.ObjectMap.init(allocator);
    defer params.deinit();
    try params.put("expression", .{ .string = "1+1" });

    const msg = try buildCdpMessage(allocator, 5, "Runtime.evaluate", .{ .object = params });
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 5), obj.get("id").?.integer);
    const msg_params = obj.get("params").?.object;
    try std.testing.expectEqualStrings("1+1", msg_params.get("expression").?.string);
}

test "cloneJsonValue deep clones string" {
    const allocator = std.testing.allocator;
    const original: json.Value = .{ .string = "hello" };
    const cloned = try cloneJsonValue(allocator, original);

    // cloned string should be equal but independent
    try std.testing.expectEqualStrings("hello", cloned.string);
    // The original and cloned point to different memory
    try std.testing.expect(original.string.ptr != cloned.string.ptr);
    allocator.free(cloned.string);
}

test "cloneJsonValue deep clones primitives" {
    const allocator = std.testing.allocator;

    const null_clone = try cloneJsonValue(allocator, .null);
    try std.testing.expect(null_clone == .null);

    const bool_clone = try cloneJsonValue(allocator, .{ .bool = true });
    try std.testing.expect(bool_clone.bool == true);

    const int_clone = try cloneJsonValue(allocator, .{ .integer = 42 });
    try std.testing.expectEqual(@as(i64, 42), int_clone.integer);
}

test "CdpResult struct layout" {
    // Verify the type compiles and has expected fields
    _ = @typeInfo(CdpResult);
    _ = @hasField(CdpResult, "parsed");
    _ = @hasField(CdpResult, "result");
}
