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
    browser: []const u8,
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

/// A CDP client connection to a single target (page/tab).
pub const Connection = struct {
    allocator: mem.Allocator,
    /// Next message ID.
    next_id: u64 = 1,
    // TODO: WebSocket connection state

    pub fn init(allocator: mem.Allocator) Connection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Connection) void {
        _ = self;
        // TODO: close WebSocket
    }

    /// Connect to a target by its webSocketDebuggerUrl.
    pub fn connect(self: *Connection, ws_url: []const u8) !void {
        _ = self;
        _ = ws_url;
        // TODO: parse URL, WebSocket handshake
    }

    /// Send a CDP command and wait for the response.
    pub fn send(self: *Connection, method: []const u8, params: ?json.Value) !json.Value {
        _ = self;
        _ = method;
        _ = params;
        // TODO: encode JSON, send over WebSocket, wait for matching ID
        return .null;
    }

    /// Evaluate JavaScript in the connected target.
    pub fn eval(self: *Connection, expression: []const u8) !EvalResult {
        _ = self;
        _ = expression;
        // TODO: send Runtime.evaluate command
        return .{};
    }

    /// Navigate the connected target to a URL.
    pub fn navigate(self: *Connection, url: []const u8) !void {
        _ = self;
        _ = url;
        // TODO: send Page.navigate command
    }
};

// ---------------------------------------------------------------------------
// HTTP Discovery
// ---------------------------------------------------------------------------

/// Discover targets by hitting http://127.0.0.1:{port}/json.
pub fn discoverTargets(allocator: mem.Allocator, port: u16) ![]Target {
    _ = allocator;
    _ = port;
    // TODO: HTTP GET, parse JSON array of targets
    return &[_]Target{};
}

/// Get browser version info from http://127.0.0.1:{port}/json/version.
pub fn getVersion(allocator: mem.Allocator, port: u16) !VersionInfo {
    _ = allocator;
    _ = port;
    // TODO: HTTP GET, parse JSON
    return error.NotImplemented;
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
