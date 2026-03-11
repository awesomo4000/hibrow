///! Gateway daemon (server) and gateway client.
///!
///! The gateway is a single-instance daemon that listens on a Unix domain socket,
///! accepts JSON-RPC 2.0 requests from clients, and routes them to browser instances
///! via CDP. It serializes CDP access per-browser (CDP is not thread-safe for
///! concurrent clients).
///!
///! Socket path: /tmp/hibrow-{uid}/gateway.sock
///! PID file:    /tmp/hibrow-{uid}/gateway.pid
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const protocol = @import("protocol.zig");

/// Default socket directory pattern.
const socket_dir_prefix = "/tmp/hibrow-";

/// Socket filename within the per-user directory.
const socket_filename = "gateway.sock";

/// PID filename within the per-user directory.
const pid_filename = "gateway.pid";

// ---------------------------------------------------------------------------
// Gateway Client
// ---------------------------------------------------------------------------

/// Client for communicating with the gateway daemon over a Unix socket.
pub const Client = struct {
    allocator: mem.Allocator,
    // TODO: socket connection state

    pub fn connect(allocator: mem.Allocator) !Client {
        // TODO: resolve socket path, connect, retry with auto-start
        return .{ .allocator = allocator };
    }

    pub fn disconnect(self: *Client) void {
        _ = self;
        // TODO: close socket
    }

    /// Send a JSON-RPC request and wait for the response.
    pub fn call(self: *Client, method: []const u8, params: ?std.json.Value) !std.json.Value {
        _ = self;
        _ = method;
        _ = params;
        // TODO: encode request, send, read response, decode
        return .null;
    }
};

// ---------------------------------------------------------------------------
// Gateway Server
// ---------------------------------------------------------------------------

/// The gateway daemon server.
pub const Server = struct {
    allocator: mem.Allocator,
    // TODO: listener socket, browser registry, command queues

    pub fn init(allocator: mem.Allocator) Server {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
        // TODO: cleanup
    }

    /// Start listening and serving requests.
    pub fn serve(self: *Server) !void {
        _ = self;
        // TODO: bind socket, accept loop, handle requests
    }

    /// Graceful shutdown.
    pub fn shutdown(self: *Server) void {
        _ = self;
        // TODO: signal shutdown, cleanup socket file
    }
};

// ---------------------------------------------------------------------------
// Path Helpers
// ---------------------------------------------------------------------------

/// Get the socket directory path for the current user.
pub fn getSocketDir(allocator: mem.Allocator) ![]u8 {
    const uid = std.posix.getuid();
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ socket_dir_prefix, uid });
}

/// Get the full socket path.
pub fn getSocketPath(allocator: mem.Allocator) ![]u8 {
    const uid = std.posix.getuid();
    return std.fmt.allocPrint(allocator, "{s}{d}/{s}", .{ socket_dir_prefix, uid, socket_filename });
}

// ---------------------------------------------------------------------------
// Auto-start
// ---------------------------------------------------------------------------

/// Try to start the gateway daemon in the background.
/// Fork, setsid, close stdio, exec gateway server mode.
pub fn autoStartDaemon(allocator: mem.Allocator) !void {
    _ = allocator;
    // TODO: fork + setsid + exec
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "socket path constants are sensible" {
    try std.testing.expectEqualStrings("gateway.sock", socket_filename);
    try std.testing.expectEqualStrings("gateway.pid", pid_filename);
    try std.testing.expectEqualStrings("/tmp/hibrow-", socket_dir_prefix);
}

test "Client struct is default-constructible for testing" {
    const allocator = std.testing.allocator;
    var client = Client{ .allocator = allocator };
    client.disconnect();
}

test "Server struct is initializable" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    server.deinit();
}
