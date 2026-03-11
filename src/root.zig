///! hibrow — public library API.
///!
///! This is the root module for embedding hibrow in other Zig programs.
///! Usage:
///!   const hibrow = @import("hibrow");
///!   var client = try hibrow.Client.connect(allocator);
///!   defer client.disconnect();
///!   const result = try client.eval("work", "document.title");

const std = @import("std");

// Re-export public modules
pub const protocol = @import("protocol.zig");
pub const gateway = @import("gateway.zig");
pub const browser = @import("browser.zig");
pub const tab = @import("tab.zig");
pub const cdp = @import("cdp.zig");
pub const websocket = @import("websocket.zig");

/// High-level client for communicating with the hibrow gateway.
/// This is the primary API for embedding hibrow in other Zig programs.
pub const Client = struct {
    allocator: std.mem.Allocator,
    gw: gateway.Client,

    /// Connect to the hibrow gateway (auto-starting it if needed).
    pub fn connect(allocator: std.mem.Allocator) !Client {
        const gw = try gateway.Client.connect(allocator);
        return .{ .allocator = allocator, .gw = gw };
    }

    /// Disconnect from the gateway.
    pub fn disconnect(self: *Client) void {
        self.gw.disconnect();
    }

    /// Evaluate JavaScript in the named profile's active tab.
    pub fn eval(self: *Client, profile: []const u8, expression: []const u8) !std.json.Value {
        _ = profile;
        _ = expression;
        // TODO: send browser.eval JSON-RPC request
        return self.gw.call("browser.eval", null);
    }

    /// Navigate the named profile's active tab to a URL.
    pub fn navigate(self: *Client, profile: []const u8, url: []const u8) !void {
        _ = self;
        _ = profile;
        _ = url;
        // TODO: send browser.navigate JSON-RPC request
    }

    /// List all running browsers.
    pub fn list(self: *Client) !std.json.Value {
        return self.gw.call("browser.list", null);
    }

    /// Launch a new browser with the given profile name.
    pub fn launch(self: *Client, profile: []const u8, options: browser.LaunchOptions) !std.json.Value {
        _ = profile;
        _ = options;
        // TODO: send browser.launch JSON-RPC request
        return self.gw.call("browser.launch", null);
    }
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
    _ = tab.TabRef;
    _ = tab.TabMap;
    _ = cdp.Target;
    _ = cdp.Connection;
    _ = websocket.WebSocket;
    _ = websocket.Opcode;
}

test "Client struct layout" {
    // Just verify the type compiles and has expected fields
    _ = @typeInfo(Client);
    _ = @hasField(Client, "allocator");
    _ = @hasField(Client, "gw");
}

test {
    // Pull in tests from all submodules
    _ = protocol;
    _ = gateway;
    _ = browser;
    _ = tab;
    _ = cdp;
    _ = websocket;
}
