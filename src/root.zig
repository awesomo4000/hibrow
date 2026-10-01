///! hibrow — public library API.
///!
///! This is the root module for embedding hibrow in other Zig programs.
///! Usage:
///!   const hibrow = @import("hibrow");
///!   var client = try hibrow.Client.connect(allocator);
///!   defer client.disconnect();
///!   const result = try client.eval("work", "document.title");

const std = @import("std");
const json = std.json;
const mem = std.mem;

// Re-export public modules
pub const protocol = @import("protocol.zig");
pub const gateway = @import("gateway.zig");
pub const browser = @import("browser.zig");
pub const process = @import("process.zig");
pub const tab = @import("tab.zig");
pub const cdp = @import("cdp.zig");
pub const websocket = @import("websocket.zig");
pub const marionette = @import("marionette.zig");
pub const grab = @import("grab.zig");
pub const push = @import("push.zig");

/// High-level client for communicating with the hibrow gateway.
/// This is the primary API for embedding hibrow in other Zig programs.
///
/// All methods that return `ParsedResponse` require the caller to call
/// `.deinit()` when done to free parsed JSON memory.
pub const Client = struct {
    allocator: mem.Allocator,
    gw: gateway.Client,

    /// Connect to the hibrow gateway (auto-starting it if needed).
    pub fn connect(allocator: mem.Allocator, io: std.Io) !Client {
        const gw = try gateway.Client.connect(allocator, io);
        return .{ .allocator = allocator, .gw = gw };
    }

    /// Disconnect from the gateway.
    pub fn disconnect(self: *Client) void {
        self.gw.disconnect();
    }

    /// List all running browsers.
    pub fn list(self: *Client) !gateway.ParsedResponse {
        return self.gw.call("browser.list", null);
    }

    /// Get info about a specific browser by profile name.
    pub fn get(self: *Client, profile: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        return self.gw.call("browser.get", .{ .object = params });
    }

    /// Launch a new browser with the given profile name.
    pub fn launch(self: *Client, profile: []const u8, opts: LaunchOpts) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        if (opts.proxy) |proxy| {
            try params.put(self.allocator, "proxy", .{ .string = proxy });
        }
        if (opts.proxy_dns) {
            try params.put(self.allocator, "proxy_dns", .{ .bool = true });
        }
        if (opts.headless) {
            try params.put(self.allocator, "headless", .{ .bool = true });
        }
        if (opts.browser_type != .chrome) {
            try params.put(self.allocator, "browser_type", .{ .string = opts.browser_type.toString() });
        }
        return self.gw.call("browser.launch", .{ .object = params });
    }

    /// Evaluate JavaScript in the named profile's active tab.
    pub fn eval(self: *Client, profile: []const u8, expression: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        try params.put(self.allocator, "expression", .{ .string = expression });
        return self.gw.call("browser.eval", .{ .object = params });
    }

    /// Navigate the named profile's active tab to a URL.
    pub fn navigate(self: *Client, profile: []const u8, url: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        try params.put(self.allocator, "url", .{ .string = url });
        return self.gw.call("browser.navigate", .{ .object = params });
    }

    /// Take a screenshot of the named profile's browser. Returns base64 PNG.
    pub fn screenshot(self: *Client, profile: []const u8, tab_idx: ?i64) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        if (tab_idx) |t| try params.put(self.allocator, "tab", .{ .integer = t });
        return self.gw.call("browser.screenshot", .{ .object = params });
    }

    /// Kill (gracefully close) the named profile's browser.
    /// The profile directory is preserved for next launch.
    pub fn kill(self: *Client, profile: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        return self.gw.call("browser.kill", .{ .object = params });
    }

    /// Get the current URL of the named profile's active tab.
    pub fn getUrl(self: *Client, profile: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        return self.gw.call("browser.url", .{ .object = params });
    }

    /// List tabs for a profile.
    pub fn tabList(self: *Client, profile: []const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        return self.gw.call("tab.list", .{ .object = params });
    }

    /// Open a new tab in the named profile's browser.
    pub fn tabNew(self: *Client, profile: []const u8, tab_url: ?[]const u8) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        if (tab_url) |u| {
            try params.put(self.allocator, "url", .{ .string = u });
        }
        return self.gw.call("tab.new", .{ .object = params });
    }

    /// Close a tab by index in the named profile's browser.
    pub fn tabClose(self: *Client, profile: []const u8, tab_index: u32) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        try params.put(self.allocator, "tab", .{ .integer = @intCast(tab_index) });
        return self.gw.call("tab.close", .{ .object = params });
    }

    /// Switch to (activate) a tab by index in the named profile's browser.
    pub fn tabSwitch(self: *Client, profile: []const u8, tab_index: u32) !gateway.ParsedResponse {
        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "profile", .{ .string = profile });
        try params.put(self.allocator, "tab", .{ .integer = @intCast(tab_index) });
        return self.gw.call("tab.switch", .{ .object = params });
    }

    /// Get gateway daemon status.
    pub fn gatewayStatus(self: *Client) !gateway.ParsedResponse {
        return self.gw.call("gateway.status", null);
    }

    /// Shut down the gateway daemon.
    pub fn gatewayShutdown(self: *Client) !gateway.ParsedResponse {
        return self.gw.call("gateway.shutdown", null);
    }
};

/// Options for launching a browser (simplified from browser.LaunchOptions).
pub const LaunchOpts = struct {
    proxy: ?[]const u8 = null,
    proxy_dns: bool = false,
    headless: bool = false,
    browser_type: browser.BrowserType = .chrome,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "public API re-exports are accessible" {
    // Verify that all submodules are importable through root
    _ = protocol.ErrorCode.parse_error;
    _ = gateway.Client;
    _ = gateway.Server;
    _ = browser.Browser;
    _ = browser.LaunchOptions;
    _ = process.DiscoveredProcess;
    _ = tab.TabRef;
    _ = tab.TabMap;
    _ = cdp.Target;
    _ = cdp.Connection;
    _ = websocket.WebSocket;
    _ = websocket.Opcode;
    _ = websocket.ReadResult;
}

test "Client struct layout" {
    // Just verify the type compiles and has expected fields
    _ = @typeInfo(Client);
    _ = @hasField(Client, "allocator");
    _ = @hasField(Client, "gw");
}

test "LaunchOpts defaults" {
    const opts = LaunchOpts{};
    try std.testing.expect(opts.proxy == null);
    try std.testing.expect(!opts.proxy_dns);
}

test {
    // Pull in tests from all submodules
    _ = protocol;
    _ = gateway;
    _ = browser;
    _ = process;
    _ = tab;
    _ = cdp;
    _ = websocket;
}
