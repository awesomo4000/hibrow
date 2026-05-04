///! Gateway daemon (server) and gateway client.
///!
///! The gateway is a single-instance daemon that listens on a Unix domain socket,
///! accepts JSON-RPC 2.0 requests from clients, and routes them to browser instances
///! via CDP. It serializes CDP access per-browser (CDP is not thread-safe for
///! concurrent clients).
///!
///! Socket path: /tmp/hibrow-{uid}/gateway.sock
///! PID file:    /tmp/hibrow-{uid}/gateway.pid
///!
///! Wire format: line-delimited JSON-RPC 2.0 (each message ends with '\n').
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const json = std.json;
const protocol = @import("protocol.zig");
const browser_mod = @import("browser.zig");
const cdp = @import("cdp.zig");
const marionette_mod = @import("marionette.zig");

/// Default socket directory pattern.
const socket_dir_prefix = "/tmp/hibrow-";

/// Socket filename within the per-user directory.
const socket_filename = "gateway.sock";

/// PID filename within the per-user directory.
const pid_filename = "gateway.pid";

/// Maximum line length for JSON-RPC messages.
const max_line_len = 1 << 20; // 1 MiB

/// Read buffer size for socket I/O.
const read_buf_size = 8192;

// ---------------------------------------------------------------------------
// Gateway Client
// ---------------------------------------------------------------------------

/// Client for communicating with the gateway daemon over a Unix socket.
pub const Client = struct {
    allocator: mem.Allocator,
    stream: std.net.Stream,
    /// Monotonically increasing request ID.
    next_id: u64 = 1,

    /// Connect to the gateway daemon. Tries the socket directly, and if
    /// connection fails, attempts to auto-start the daemon and retry.
    pub fn connect(allocator: mem.Allocator) !Client {
        return connectImpl(allocator, true);
    }

    /// Connect to the gateway daemon without auto-starting it.
    /// Returns error.ConnectionRefused if the daemon is not running.
    pub fn connectNoAutoStart(allocator: mem.Allocator) !Client {
        return connectImpl(allocator, false);
    }

    fn connectImpl(allocator: mem.Allocator, auto_start: bool) !Client {
        const socket_path = try getSocketPath(allocator);
        defer allocator.free(socket_path);

        // First attempt
        if (connectToSocket(socket_path)) |stream| {
            return .{ .allocator = allocator, .stream = stream };
        } else |_| {}

        if (!auto_start) return error.ConnectionRefused;

        // Auto-start daemon and retry
        try autoStartDaemon(allocator);

        // Poll for the socket to appear (up to 5 seconds)
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            if (connectToSocket(socket_path)) |stream| {
                return .{ .allocator = allocator, .stream = stream };
            } else |_| {}
        }

        return error.GatewayStartFailed;
    }

    /// Disconnect from the gateway.
    pub fn disconnect(self: *Client) void {
        self.stream.close();
    }

    /// Send a JSON-RPC request and wait for the response.
    /// Returns the parsed "result" field from the response.
    /// Caller owns the returned ParsedResponse and must deinit it.
    pub fn call(self: *Client, method: []const u8, params: ?json.Value) !ParsedResponse {
        const id = self.next_id;
        self.next_id += 1;

        // Encode request
        const req = protocol.Request{
            .method = method,
            .params = params,
            .id = .{ .integer = @intCast(id) },
        };
        const req_bytes = try req.encode(self.allocator);
        defer self.allocator.free(req_bytes);

        // Send
        try self.stream.writeAll(req_bytes);

        // Read response line
        const line = try readLine(self.allocator, self.stream);
        errdefer self.allocator.free(line);

        // Parse the response
        var parsed = try protocol.parseMessage(self.allocator, line);
        self.allocator.free(line);

        // Check for error response
        const val = parsed.value();
        if (val == .object) {
            if (val.object.get("error")) |err_val| {
                // Return the error info wrapped in ParsedResponse
                return .{ .parsed = parsed, .result = err_val, .is_error = true };
            }
            if (val.object.get("result")) |result_val| {
                return .{ .parsed = parsed, .result = result_val, .is_error = false };
            }
        }

        return .{ .parsed = parsed, .result = .null, .is_error = false };
    }
};

/// Owns the parsed response memory. The `result` field borrows from it.
pub const ParsedResponse = struct {
    parsed: protocol.ParsedMessage,
    result: json.Value,
    is_error: bool,

    pub fn deinit(self: *ParsedResponse) void {
        self.parsed.deinit();
    }
};

// ---------------------------------------------------------------------------
// Gateway Server
// ---------------------------------------------------------------------------

/// A cached CDP connection to a profile's browser page.
const ProfileConn = struct {
    port: u16,
    conn: cdp.Connection, // owns the WebSocket + next_id
};

/// The gateway daemon server. Listens on a Unix domain socket and dispatches
/// JSON-RPC requests to browser management handlers.
pub const Server = struct {
    allocator: mem.Allocator,
    listener: ?std.net.Server = null,
    socket_path: ?[]u8 = null,
    running: bool = false,
    /// Cached CDP connections keyed by profile name (owned strings).
    connections: std.StringHashMap(ProfileConn),

    pub fn init(allocator: mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(ProfileConn).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        // Close all cached CDP connections
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.conn.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();

        if (self.listener) |*l| l.deinit();
        if (self.socket_path) |p| {
            // Remove socket file on cleanup
            std.fs.deleteFileAbsolute(p) catch {};
            self.allocator.free(p);
        }
    }

    /// Start listening and serving requests. Blocks until shutdown() is called.
    pub fn serve(self: *Server) !void {
        const sock_path = try getSocketPath(self.allocator);
        self.socket_path = sock_path;

        // Ensure socket directory exists
        const sock_dir = try getSocketDir(self.allocator);
        defer self.allocator.free(sock_dir);
        std.fs.cwd().makePath(sock_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Remove stale socket file if it exists
        std.fs.deleteFileAbsolute(sock_path) catch {};

        // Write PID file
        try writePidFile(self.allocator, sock_dir);

        // Bind and listen
        const addr = try std.net.Address.initUnix(sock_path);
        self.listener = try addr.listen(.{
            .kernel_backlog = 128,
            .reuse_address = true,
        });
        self.running = true;

        // Accept loop
        while (self.running) {
            const connection = self.listener.?.accept() catch |err| {
                if (!self.running) break;
                // Log and continue on transient errors
                std.debug.print("accept error: {any}\n", .{err});
                continue;
            };
            // Handle each connection synchronously (simple, correct).
            // CDP is not thread-safe per-browser anyway, so serial is fine.
            self.handleConnection(connection.stream);
        }
    }

    /// Graceful shutdown.
    pub fn shutdown(self: *Server) void {
        self.running = false;
        // Close the listener to unblock accept()
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    /// Handle a single client connection: read request, dispatch, write response.
    fn handleConnection(self: *Server, stream: std.net.Stream) void {
        defer stream.close();

        const line = readLine(self.allocator, stream) catch return;
        defer self.allocator.free(line);
        if (line.len == 0) return;

        // Parse JSON
        var parsed = protocol.parseMessage(self.allocator, line) catch {
            sendErrorResponse(self.allocator, stream, .null, .parse_error, "Parse error") catch {};
            return;
        };
        defer parsed.deinit();

        // Extract request
        const req = protocol.extractRequest(parsed.value()) catch {
            sendErrorResponse(self.allocator, stream, .null, .invalid_request, "Invalid request") catch {};
            return;
        };

        // Dispatch to handler
        const response_bytes = self.dispatch(req) catch |err| {
            sendErrorResponse(self.allocator, stream, req.id, .internal_error, @errorName(err)) catch {};
            return;
        };
        defer self.allocator.free(response_bytes);

        stream.writeAll(response_bytes) catch {};
    }

    /// Dispatch a JSON-RPC request to the appropriate handler.
    /// Returns encoded response bytes (caller owns).
    fn dispatch(self: *Server, req: protocol.Request) ![]u8 {
        const MethodHandler = *const fn (*Server, json.Value, ?json.Value) anyerror![]u8;
        const methods = std.StaticStringMap(MethodHandler).initComptime(.{
            .{ "gateway.status", wrapNoParams(handleGatewayStatus) },
            .{ "gateway.shutdown", wrapNoParams(handleGatewayShutdown) },
            .{ "browser.list", wrapNoParams(handleBrowserList) },
            .{ "browser.launch", wrapWithParams(handleBrowserLaunch) },
            .{ "browser.eval", wrapWithParams(handleBrowserEval) },
            .{ "browser.navigate", wrapWithParams(handleBrowserNavigate) },
            .{ "browser.get", wrapWithParams(handleBrowserGet) },
            .{ "browser.kill", wrapWithParams(handleBrowserKill) },
            .{ "browser.url", wrapWithParams(handleBrowserUrl) },
            .{ "tab.list", wrapWithParams(handleTabList) },
            .{ "tab.new", wrapWithParams(handleTabNew) },
            .{ "tab.close", wrapWithParams(handleTabClose) },
            .{ "tab.switch", wrapWithParams(handleTabSwitch) },
        });

        if (methods.get(req.method)) |handler| {
            return handler(self, req.id, req.params);
        }
        const resp = protocol.makeErrorResponse(req.id, .method_not_found, "Method not found");
        return resp.encode(self.allocator);
    }

    /// Adapter: wrap a handler that only takes (self, id) to accept (self, id, params).
    fn wrapNoParams(comptime func: fn (*Server, json.Value) anyerror![]u8) *const fn (*Server, json.Value, ?json.Value) anyerror![]u8 {
        return &struct {
            fn call(self: *Server, id: json.Value, _: ?json.Value) anyerror![]u8 {
                return func(self, id);
            }
        }.call;
    }

    /// Adapter: wrap a handler that takes (self, id, params) — identity, for type uniformity.
    fn wrapWithParams(comptime func: fn (*Server, json.Value, ?json.Value) anyerror![]u8) *const fn (*Server, json.Value, ?json.Value) anyerror![]u8 {
        return &struct {
            fn call(self: *Server, id: json.Value, params: ?json.Value) anyerror![]u8 {
                return func(self, id, params);
            }
        }.call;
    }

    // -----------------------------------------------------------------------
    // Response helpers — eliminate the encode boilerplate
    // -----------------------------------------------------------------------

    fn ok(self: *Server, id: json.Value, result: json.Value) ![]u8 {
        const resp = protocol.makeResponse(id, result);
        return resp.encode(self.allocator);
    }

    fn fail(self: *Server, id: json.Value, code: protocol.ErrorCode, message: []const u8) []u8 {
        const resp = protocol.makeErrorResponse(id, code, message);
        return resp.encode(self.allocator) catch &.{};
    }

    /// Get a cached CDP connection for a profile, or create one if not cached.
    /// Returns a pointer to the cached Connection, or null if browser not found.
    fn getConnection(self: *Server, profile: []const u8) ?*cdp.Connection {
        // Check cache first
        if (self.connections.getPtr(profile)) |pc| {
            return &pc.conn;
        }

        // Not cached — look up port via process scan
        const resolved_port = browser_mod.lookupPort(self.allocator, profile) catch null orelse
            return null;

        // Discover targets via HTTP
        const targets = cdp.discoverTargets(self.allocator, resolved_port) catch return null;
        defer cdp.freeTargets(self.allocator, targets);

        const ws_url = findPageTarget(targets) orelse return null;

        // Connect WebSocket
        var conn = cdp.Connection.init(self.allocator);
        conn.connect(ws_url) catch {
            conn.deinit();
            return null;
        };

        // Store in cache — we need to dupe the profile key
        const key = self.allocator.dupe(u8, profile) catch {
            conn.deinit();
            return null;
        };

        self.connections.put(key, .{
            .port = resolved_port,
            .conn = conn,
        }) catch {
            self.allocator.free(key);
            conn.deinit();
            return null;
        };

        return &self.connections.getPtr(profile).?.conn;
    }

    /// Evict a cached connection for a profile, closing the WebSocket.
    fn evictConnection(self: *Server, profile: []const u8) void {
        if (self.connections.fetchRemove(profile)) |kv| {
            var pc = kv.value;
            pc.conn.deinit();
            self.allocator.free(kv.key);
        }
    }

    /// Serialize a Browser struct to a JSON object value.
    fn browserToJson(self: *Server, b: browser_mod.Browser) !json.ObjectMap {
        var obj = json.ObjectMap.init(self.allocator);
        try obj.put("profile", .{ .string = b.profile });
        try obj.put("port", .{ .integer = @intCast(b.port) });
        var pids_arr = json.Array.init(self.allocator);
        for (b.pids) |pid| {
            try pids_arr.append(.{ .integer = @intCast(pid) });
        }
        try obj.put("pids", .{ .array = pids_arr });
        const display_dir = try collapseTilde(self.allocator, b.profile_dir);
        try obj.put("profile_dir", .{ .string = display_dir });
        try obj.put("browser_type", .{ .string = b.browser_type.toString() });
        return obj;
    }

    // -----------------------------------------------------------------------
    // Method handlers
    // -----------------------------------------------------------------------

    fn handleGatewayStatus(self: *Server, id: json.Value) ![]u8 {
        return self.ok(id, .{ .string = "running" });
    }

    fn handleGatewayShutdown(self: *Server, id: json.Value) ![]u8 {
        const encoded = try self.ok(id, .{ .string = "shutting_down" });

        // Close all cached CDP connections before shutting down
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.conn.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.clearRetainingCapacity();

        // Shut down after encoding the response so the client gets the reply.
        self.running = false;
        if (self.listener) |*l| { l.deinit(); self.listener = null; }
        if (self.socket_path) |p| std.fs.deleteFileAbsolute(p) catch {};

        return encoded;
    }

    fn handleBrowserList(self: *Server, id: json.Value) ![]u8 {
        const browsers = browser_mod.discover(self.allocator) catch
            return self.fail(id, .internal_error, "Discovery failed");
        defer browser_mod.freeBrowsers(self.allocator, browsers);

        var arr = json.Array.init(self.allocator);
        defer arr.deinit();
        for (browsers) |b| {
            const obj = try self.browserToJson(b);
            try arr.append(.{ .object = obj });
        }

        return self.ok(id, .{ .array = arr });
    }

    fn handleBrowserLaunch(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        // Parse browser type (default: chrome)
        const browser_type = if (extractStringParam(params, "browser_type")) |bt_str|
            browser_mod.BrowserType.fromString(bt_str) orelse
                return self.fail(id, .invalid_params, "Invalid browser_type")
        else
            browser_mod.BrowserType.chrome;

        // Already running? Check via process scan.
        const existing_info = try findBrowserInfo(self.allocator, profile);

        if (existing_info) |ei| {
            const ep = ei.port;
            var obj = json.ObjectMap.init(self.allocator);
            defer obj.deinit();
            try obj.put("profile", .{ .string = profile });
            try obj.put("port", .{ .integer = @intCast(ep) });
            try obj.put("already_running", .{ .bool = true });
            try obj.put("browser_type", .{ .string = browser_type.toString() });
            return self.ok(id, .{ .object = obj });
        }

        const b = browser_mod.launch(self.allocator, .{
            .profile = profile,
            .proxy = extractStringParam(params, "proxy"),
            .proxy_dns = extractBoolParam(params, "proxy_dns") orelse false,
            .browser_type = browser_type,
        }) catch |err|
            return self.fail(id, .browser_launch_failed, @errorName(err));
        defer self.allocator.free(b.profile);

        var obj = try self.browserToJson(b);
        defer obj.deinit();
        return self.ok(id, .{ .object = obj });
    }

    fn handleBrowserEval(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const expression = extractStringParam(params, "expression") orelse
            return self.fail(id, .invalid_params, "Missing 'expression' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const eval_result = conn.eval(expression) catch
                    return self.fail(id, .cdp_error, "Eval failed");
                if (eval_result.exception) |exc| {
                    defer self.allocator.free(exc);
                    return self.fail(id, .cdp_error, exc);
                }
                return self.ok(id, eval_result.value);
            },
            .chrome => {
                const conn = self.getConnection(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                const eval_result = conn.eval(expression) catch {
                    self.evictConnection(profile);
                    return self.fail(id, .cdp_error, "Eval failed");
                };
                if (eval_result.exception) |exc| {
                    defer self.allocator.free(exc);
                    return self.fail(id, .cdp_error, exc);
                }
                return self.ok(id, eval_result.value);
            },
        }
    }

    fn handleBrowserNavigate(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const url = extractStringParam(params, "url") orelse
            return self.fail(id, .invalid_params, "Missing 'url' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                conn.navigate(url) catch
                    return self.fail(id, .cdp_error, "Navigate failed");
            },
            .chrome => {
                const conn = self.getConnection(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                conn.navigate(url) catch {
                    self.evictConnection(profile);
                    return self.fail(id, .cdp_error, "Navigate failed");
                };
            },
        }

        var obj = json.ObjectMap.init(self.allocator);
        defer obj.deinit();
        try obj.put("status", .{ .string = "navigated" });
        try obj.put("url", .{ .string = url });
        return self.ok(id, .{ .object = obj });
    }

    fn handleBrowserGet(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const browsers = browser_mod.discover(self.allocator) catch
            return self.fail(id, .internal_error, "Discovery failed");
        defer browser_mod.freeBrowsers(self.allocator, browsers);

        for (browsers) |b| {
            if (mem.eql(u8, b.profile, profile)) {
                var obj = try self.browserToJson(b);
                defer obj.deinit();
                return self.ok(id, .{ .object = obj });
            }
        }

        return self.fail(id, .browser_not_found, "Browser not found");
    }

    fn handleBrowserKill(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                conn.quit() catch {};
            },
            .chrome => {
                // Get browser-level WebSocket URL from /json/version
                const version = cdp.getVersion(self.allocator, info.port) catch
                    return self.fail(id, .cdp_error, "Could not reach browser");
                defer cdp.freeVersionInfo(self.allocator, version);

                const browser_ws = version.webSocketDebuggerUrl orelse
                    return self.fail(id, .cdp_error, "No browser WebSocket URL");

                var conn = cdp.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(browser_ws) catch
                    return self.fail(id, .cdp_error, "WebSocket connection failed");

                conn.closeBrowser() catch
                    return self.fail(id, .cdp_error, "Browser.close failed");
            },
        }

        // Evict cached page connection for this profile
        self.evictConnection(profile);

        return self.ok(id, .{ .string = "killed" });
    }

    fn handleBrowserUrl(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const url_str = conn.getCurrentUrl() catch
                    return self.fail(id, .cdp_error, "Could not get URL");
                defer self.allocator.free(url_str);
                return self.ok(id, .{ .string = url_str });
            },
            .chrome => {
                const conn = self.getConnection(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                const url_str = conn.getUrl() catch {
                    self.evictConnection(profile);
                    return self.fail(id, .cdp_error, "Could not get URL");
                };
                defer self.allocator.free(url_str);
                return self.ok(id, .{ .string = url_str });
            },
        }
    }

    // -----------------------------------------------------------------------
    // Tab management handlers
    // -----------------------------------------------------------------------

    /// Helper: get page-type targets for a profile.
    /// Returns the browser port and the filtered page targets (caller owns).
    const PageTargetsResult = struct {
        port: u16,
        targets: []cdp.Target,
    };

    fn getPageTargets(self: *Server, profile: []const u8) !?PageTargetsResult {
        const port = (try findBrowserInfo(self.allocator, profile) orelse return null).port;

        const all_targets = cdp.discoverTargets(self.allocator, port) catch return null;
        defer cdp.freeTargets(self.allocator, all_targets);

        // Filter to page-type targets, duping them into owned memory
        var pages: std.ArrayList(cdp.Target) = .{};
        errdefer {
            for (pages.items) |t| {
                self.allocator.free(t.id);
                self.allocator.free(t.title);
                self.allocator.free(t.url);
                self.allocator.free(t.@"type");
                if (t.webSocketDebuggerUrl) |ws| self.allocator.free(ws);
            }
            pages.deinit(self.allocator);
        }

        for (all_targets) |t| {
            if (mem.eql(u8, t.@"type", "page")) {
                const ws_url = if (t.webSocketDebuggerUrl) |ws|
                    try self.allocator.dupe(u8, ws)
                else
                    null;
                errdefer if (ws_url) |w| self.allocator.free(w);

                try pages.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, t.id),
                    .title = try self.allocator.dupe(u8, t.title),
                    .url = try self.allocator.dupe(u8, t.url),
                    .@"type" = try self.allocator.dupe(u8, t.@"type"),
                    .webSocketDebuggerUrl = ws_url,
                });
            }
        }

        return .{
            .port = port,
            .targets = try pages.toOwnedSlice(self.allocator),
        };
    }

    fn handleTabList(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");

                const handles = conn.getWindowHandles() catch
                    return self.fail(id, .cdp_error, "Could not list windows");
                defer {
                    for (handles) |h| self.allocator.free(h);
                    self.allocator.free(handles);
                }

                // For each handle, switch to it, get title+url
                var arr = json.Array.init(self.allocator);
                defer arr.deinit();
                for (handles, 0..) |handle, i| {
                    conn.switchToWindow(handle) catch continue;
                    const title = conn.getTitle() catch try self.allocator.dupe(u8, "");
                    const url = conn.getCurrentUrl() catch try self.allocator.dupe(u8, "");

                    var obj = json.ObjectMap.init(self.allocator);
                    try obj.put("index", .{ .integer = @intCast(i) });
                    try obj.put("title", .{ .string = title });
                    try obj.put("url", .{ .string = url });
                    try arr.append(.{ .object = obj });
                }
                return self.ok(id, .{ .array = arr });
            },
            .chrome => {
                const result = try self.getPageTargets(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                defer cdp.freeTargets(self.allocator, result.targets);

                var arr = json.Array.init(self.allocator);
                defer arr.deinit();
                for (result.targets, 0..) |t, i| {
                    var obj = json.ObjectMap.init(self.allocator);
                    try obj.put("index", .{ .integer = @intCast(i) });
                    try obj.put("title", .{ .string = t.title });
                    try obj.put("url", .{ .string = t.url });
                    try arr.append(.{ .object = obj });
                }
                return self.ok(id, .{ .array = arr });
            },
        }
    }

    fn handleTabNew(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        const url = extractStringParam(params, "url");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");

                const handle = conn.newWindow("tab") catch
                    return self.fail(id, .cdp_error, "Could not create tab");
                defer self.allocator.free(handle);

                // Switch to new tab and navigate if URL provided
                conn.switchToWindow(handle) catch {};
                if (url) |u| conn.navigate(u) catch {};

                self.evictConnection(profile);
                var obj = json.ObjectMap.init(self.allocator);
                defer obj.deinit();
                try obj.put("status", .{ .string = "created" });
                try obj.put("url", .{ .string = url orelse "about:blank" });
                return self.ok(id, .{ .object = obj });
            },
            .chrome => {
                const new_target = cdp.createTarget(self.allocator, info.port, url) catch
                    return self.fail(id, .cdp_error, "Could not create tab");
                defer {
                    self.allocator.free(new_target.id);
                    self.allocator.free(new_target.title);
                    self.allocator.free(new_target.url);
                    self.allocator.free(new_target.@"type");
                    if (new_target.webSocketDebuggerUrl) |ws| self.allocator.free(ws);
                }

                self.evictConnection(profile);
                var obj = json.ObjectMap.init(self.allocator);
                defer obj.deinit();
                try obj.put("status", .{ .string = "created" });
                try obj.put("url", .{ .string = new_target.url });
                return self.ok(id, .{ .object = obj });
            },
        }
    }

    fn handleTabClose(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const tab_idx = extractIntParam(params, "tab") orelse
            return self.fail(id, .invalid_params, "Missing 'tab' parameter");
        if (tab_idx < 0) return self.fail(id, .invalid_params, "Tab index must be non-negative");
        const idx: usize = @intCast(tab_idx);

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");

                const handles = conn.getWindowHandles() catch
                    return self.fail(id, .cdp_error, "Could not list windows");
                defer {
                    for (handles) |h| self.allocator.free(h);
                    self.allocator.free(handles);
                }

                if (idx >= handles.len)
                    return self.fail(id, .invalid_params, "Tab index out of bounds");

                conn.switchToWindow(handles[idx]) catch
                    return self.fail(id, .cdp_error, "Could not switch to tab");
                conn.closeWindow() catch
                    return self.fail(id, .cdp_error, "Could not close tab");

                self.evictConnection(profile);
                return self.ok(id, .{ .string = "closed" });
            },
            .chrome => {
                const result = try self.getPageTargets(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                defer cdp.freeTargets(self.allocator, result.targets);

                if (idx >= result.targets.len)
                    return self.fail(id, .invalid_params, "Tab index out of bounds");

                cdp.closeTarget(self.allocator, result.port, result.targets[idx].id) catch
                    return self.fail(id, .cdp_error, "Could not close tab");

                self.evictConnection(profile);
                return self.ok(id, .{ .string = "closed" });
            },
        }
    }

    fn handleTabSwitch(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const tab_idx = extractIntParam(params, "tab") orelse
            return self.fail(id, .invalid_params, "Missing 'tab' parameter");
        if (tab_idx < 0) return self.fail(id, .invalid_params, "Tab index must be non-negative");
        const idx: usize = @intCast(tab_idx);

        const info = try findBrowserInfo(self.allocator, profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");

                const handles = conn.getWindowHandles() catch
                    return self.fail(id, .cdp_error, "Could not list windows");
                defer {
                    for (handles) |h| self.allocator.free(h);
                    self.allocator.free(handles);
                }

                if (idx >= handles.len)
                    return self.fail(id, .invalid_params, "Tab index out of bounds");

                conn.switchToWindow(handles[idx]) catch
                    return self.fail(id, .cdp_error, "Could not switch tab");

                self.evictConnection(profile);
                return self.ok(id, .{ .string = "switched" });
            },
            .chrome => {
                const result = try self.getPageTargets(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                defer cdp.freeTargets(self.allocator, result.targets);

                if (idx >= result.targets.len)
                    return self.fail(id, .invalid_params, "Tab index out of bounds");

                cdp.activateTarget(self.allocator, result.port, result.targets[idx].id) catch
                    return self.fail(id, .cdp_error, "Could not activate tab");

                self.evictConnection(profile);
                return self.ok(id, .{ .string = "switched" });
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Path Helpers
// ---------------------------------------------------------------------------

/// Get the socket directory path for the current user.
pub fn getSocketDir(allocator: mem.Allocator) ![]u8 {
    const uid = posix.getuid();
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ socket_dir_prefix, uid });
}

/// Get the full socket path.
pub fn getSocketPath(allocator: mem.Allocator) ![]u8 {
    const uid = posix.getuid();
    return std.fmt.allocPrint(allocator, "{s}{d}/{s}", .{ socket_dir_prefix, uid, socket_filename });
}

/// Get the PID file path.
pub fn getPidFilePath(allocator: mem.Allocator) ![]u8 {
    const uid = posix.getuid();
    return std.fmt.allocPrint(allocator, "{s}{d}/{s}", .{ socket_dir_prefix, uid, pid_filename });
}

// ---------------------------------------------------------------------------
// Auto-start
// ---------------------------------------------------------------------------

/// Try to start the gateway daemon in the background.
/// Forks, child calls setsid, closes stdio, execs gateway in server mode.
pub fn autoStartDaemon(allocator: mem.Allocator) !void {
    // Get path to our own executable
    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);

    // Spawn the daemon process
    var child = std.process.Child.init(&.{ self_path, "gateway", "serve" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    // New process group so it survives our exit
    child.pgid = 0;

    try child.spawn();
    // Don't wait — let the daemon run independently
}

// ---------------------------------------------------------------------------
// Socket helpers
// ---------------------------------------------------------------------------

/// Connect to an existing Unix domain socket.
fn connectToSocket(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path);
}

/// Read a newline-delimited line from a stream.
/// Returns allocated slice (caller owns). Does not include the newline.
fn readLine(allocator: mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    var read_buf: [read_buf_size]u8 = undefined;
    while (buf.items.len < max_line_len) {
        const n = try stream.read(&read_buf);
        if (n == 0) break; // EOF

        // Look for newline in what we just read
        if (mem.indexOfScalar(u8, read_buf[0..n], '\n')) |nl_pos| {
            // Found newline — append up to it
            try buf.appendSlice(allocator, read_buf[0..nl_pos]);
            break;
        }
        try buf.appendSlice(allocator, read_buf[0..n]);
    }

    return try buf.toOwnedSlice(allocator);
}

/// Send a JSON-RPC error response directly to a stream.
fn sendErrorResponse(
    allocator: mem.Allocator,
    stream: std.net.Stream,
    id: json.Value,
    code: protocol.ErrorCode,
    message: []const u8,
) !void {
    const resp = protocol.makeErrorResponse(id, code, message);
    const bytes = try resp.encode(allocator);
    defer allocator.free(bytes);
    try stream.writeAll(bytes);
}

/// Write a PID file into the socket directory.
fn writePidFile(allocator: mem.Allocator, sock_dir: []const u8) !void {
    const pid_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sock_dir, pid_filename });
    defer allocator.free(pid_path);

    const file = try std.fs.cwd().createFile(pid_path, .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.print("{d}\n", .{std.c.getpid()});
    try writer.interface.flush();
}

// ---------------------------------------------------------------------------
// Browser lookup helpers
// ---------------------------------------------------------------------------

/// Extract a string parameter from JSON-RPC params.
fn extractStringParam(params: ?json.Value, key: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p == .null) return null;
    if (p != .object) return null;
    const val = p.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// Extract a bool parameter from JSON-RPC params.
fn extractBoolParam(params: ?json.Value, key: []const u8) ?bool {
    const p = params orelse return null;
    if (p == .null) return null;
    if (p != .object) return null;
    const val = p.object.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

/// Extract an integer parameter from JSON-RPC params.
fn extractIntParam(params: ?json.Value, key: []const u8) ?i64 {
    const p = params orelse return null;
    if (p == .null) return null;
    if (p != .object) return null;
    const val = p.object.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

/// Find a browser's CDP port by scanning running processes for the given profile.
const BrowserInfo = struct {
    port: u16,
    browser_type: browser_mod.BrowserType,
};

fn findBrowserInfo(allocator: mem.Allocator, profile: []const u8) !?BrowserInfo {
    const browsers = try browser_mod.discover(allocator);
    defer browser_mod.freeBrowsers(allocator, browsers);

    for (browsers) |b| {
        if (mem.eql(u8, b.profile, profile)) {
            return .{ .port = b.port, .browser_type = b.browser_type };
        }
    }
    return null;
}

/// Replace the user's home directory prefix with "~" for display.
/// Returns an allocated string if replacement was made, or a dupe of the input.
fn collapseTilde(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return try allocator.dupe(u8, path);
    if (mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        return try std.fmt.allocPrint(allocator, "~{s}", .{rest});
    }
    return try allocator.dupe(u8, path);
}

/// Find the first "page" type target with a webSocketDebuggerUrl.
fn findPageTarget(targets: []const cdp.Target) ?[]const u8 {
    for (targets) |t| {
        if (mem.eql(u8, t.@"type", "page")) {
            if (t.webSocketDebuggerUrl) |ws_url| return ws_url;
        }
    }
    // Fall back to any target with a WS URL
    for (targets) |t| {
        if (t.webSocketDebuggerUrl) |ws_url| return ws_url;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "socket path constants are sensible" {
    try std.testing.expectEqualStrings("gateway.sock", socket_filename);
    try std.testing.expectEqualStrings("gateway.pid", pid_filename);
    try std.testing.expectEqualStrings("/tmp/hibrow-", socket_dir_prefix);
}

test "getSocketDir contains uid" {
    const allocator = std.testing.allocator;
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    try std.testing.expect(mem.startsWith(u8, dir, "/tmp/hibrow-"));
}

test "getSocketPath contains socket filename" {
    const allocator = std.testing.allocator;
    const path = try getSocketPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(mem.endsWith(u8, path, "/gateway.sock"));
    try std.testing.expect(mem.startsWith(u8, path, "/tmp/hibrow-"));
}

test "getPidFilePath contains pid filename" {
    const allocator = std.testing.allocator;
    const path = try getPidFilePath(allocator);
    defer allocator.free(path);
    try std.testing.expect(mem.endsWith(u8, path, "/gateway.pid"));
}

test "extractStringParam extracts from object" {
    const allocator = std.testing.allocator;
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("profile", .{ .string = "work" });
    try obj.put("count", .{ .integer = 5 });

    const params: json.Value = .{ .object = obj };
    try std.testing.expectEqualStrings("work", extractStringParam(params, "profile").?);
    try std.testing.expect(extractStringParam(params, "count") == null); // integer, not string
    try std.testing.expect(extractStringParam(params, "missing") == null);
}

test "extractStringParam handles null and absent params" {
    try std.testing.expect(extractStringParam(null, "key") == null);
    try std.testing.expect(extractStringParam(.null, "key") == null);
}

test "extractBoolParam extracts from object" {
    const allocator = std.testing.allocator;
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("proxy_dns", .{ .bool = true });
    try obj.put("name", .{ .string = "test" });

    const params: json.Value = .{ .object = obj };
    try std.testing.expectEqual(@as(?bool, true), extractBoolParam(params, "proxy_dns"));
    try std.testing.expect(extractBoolParam(params, "name") == null); // string, not bool
    try std.testing.expect(extractBoolParam(params, "missing") == null);
}

test "findPageTarget finds page type first" {
    const targets = [_]cdp.Target{
        .{
            .id = "bg1",
            .title = "Background",
            .url = "chrome-extension://abc",
            .@"type" = "background_page",
            .webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/bg1",
        },
        .{
            .id = "page1",
            .title = "Example",
            .url = "https://example.com",
            .@"type" = "page",
            .webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/page1",
        },
    };
    const result = findPageTarget(&targets);
    try std.testing.expect(result != null);
    try std.testing.expect(mem.indexOf(u8, result.?, "page1") != null);
}

test "findPageTarget falls back to any target with ws url" {
    const targets = [_]cdp.Target{
        .{
            .id = "worker1",
            .title = "Worker",
            .url = "chrome://worker",
            .@"type" = "service_worker",
            .webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/worker1",
        },
    };
    const result = findPageTarget(&targets);
    try std.testing.expect(result != null);
}

test "findPageTarget returns null for empty list" {
    const targets = [_]cdp.Target{};
    try std.testing.expect(findPageTarget(&targets) == null);
}

test "findPageTarget returns null when no ws urls" {
    const targets = [_]cdp.Target{
        .{
            .id = "page1",
            .title = "No WS",
            .url = "https://example.com",
            .@"type" = "page",
            .webSocketDebuggerUrl = null,
        },
    };
    try std.testing.expect(findPageTarget(&targets) == null);
}

test "Server initializes and deinitializes cleanly" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    // Verify connection cache is empty
    try std.testing.expectEqual(@as(u32, 0), server.connections.count());
    server.deinit();
}

test "Server evictConnection on empty cache is safe" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();
    // Should not crash or leak
    server.evictConnection("nonexistent");
}

test "readLine reads up to newline" {
    // Use a socket pair (Stream methods require socket fds on some platforms)
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;

    const read_stream = std.net.Stream{ .handle = fds[0] };
    const write_fd = fds[1];

    // Write test data with newline
    const test_data = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}\n";
    _ = try posix.write(write_fd, test_data);
    posix.close(write_fd);

    const allocator = std.testing.allocator;
    const line = try readLine(allocator, read_stream);
    defer allocator.free(line);
    defer read_stream.close();

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}", line);
}

test "readLine handles EOF without newline" {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;

    const read_stream = std.net.Stream{ .handle = fds[0] };
    const write_fd = fds[1];

    // Write data without newline, then close
    _ = try posix.write(write_fd, "partial data");
    posix.close(write_fd);

    const allocator = std.testing.allocator;
    const line = try readLine(allocator, read_stream);
    defer allocator.free(line);
    defer read_stream.close();

    try std.testing.expectEqualStrings("partial data", line);
}

test "Unix socket round-trip" {
    const allocator = std.testing.allocator;

    // Use a unique socket path to avoid collisions between parallel test runs
    var path_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "/tmp/hibrow-test-{d}.sock", .{std.c.getpid()});

    // Clean up any stale socket
    std.fs.deleteFileAbsolute(sock_path) catch {};

    // Create server
    const addr = try std.net.Address.initUnix(sock_path);
    var server = try addr.listen(.{ .reuse_address = true });
    defer {
        server.deinit();
        std.fs.deleteFileAbsolute(sock_path) catch {};
    }

    // Connect client (in same thread since we can use non-blocking approach)
    var client_stream = try std.net.connectUnixSocket(sock_path);
    defer client_stream.close();

    // Accept on server
    const conn = try server.accept();
    defer conn.stream.close();

    // Client sends a request
    const req = protocol.Request{
        .method = "gateway.status",
        .id = .{ .integer = 1 },
    };
    const req_bytes = try req.encode(allocator);
    defer allocator.free(req_bytes);
    try client_stream.writeAll(req_bytes);

    // Server reads the request
    const server_stream = conn.stream;
    const line = try readLine(allocator, server_stream);
    defer allocator.free(line);

    // Verify the request was received correctly
    var parsed = try protocol.parseMessage(allocator, line);
    defer parsed.deinit();
    const decoded = try protocol.extractRequest(parsed.value());
    try std.testing.expectEqualStrings("gateway.status", decoded.method);
    try std.testing.expectEqual(@as(i64, 1), decoded.id.integer);

    // Server sends a response
    const resp = protocol.makeResponse(decoded.id, .{ .string = "ok" });
    const resp_bytes = try resp.encode(allocator);
    defer allocator.free(resp_bytes);
    try conn.stream.writeAll(resp_bytes);

    // Client reads the response
    const resp_line = try readLine(allocator, client_stream);
    defer allocator.free(resp_line);

    var resp_parsed = try protocol.parseMessage(allocator, resp_line);
    defer resp_parsed.deinit();
    const resp_obj = resp_parsed.value().object;
    try std.testing.expectEqualStrings("ok", resp_obj.get("result").?.string);
}

test "Server dispatch returns method_not_found for unknown method" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    const req = protocol.Request{
        .method = "unknown.method",
        .id = .{ .integer = 1 },
    };

    const response_bytes = try server.dispatch(req);
    defer allocator.free(response_bytes);

    // Parse the response and verify it's a method_not_found error
    var parsed = try protocol.parseMessage(allocator, response_bytes);
    defer parsed.deinit();
    const obj = parsed.value().object;
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Method not found", err_obj.get("message").?.string);
}

test "Server dispatch handles gateway.status" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    const req = protocol.Request{
        .method = "gateway.status",
        .id = .{ .integer = 1 },
    };

    const response_bytes = try server.dispatch(req);
    defer allocator.free(response_bytes);

    var parsed = try protocol.parseMessage(allocator, response_bytes);
    defer parsed.deinit();
    const obj = parsed.value().object;
    try std.testing.expectEqualStrings("running", obj.get("result").?.string);
}

test "Server dispatch handles gateway.shutdown" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    try std.testing.expect(server.running == false);

    const req = protocol.Request{
        .method = "gateway.shutdown",
        .id = .{ .integer = 1 },
    };

    const response_bytes = try server.dispatch(req);
    defer allocator.free(response_bytes);

    var parsed = try protocol.parseMessage(allocator, response_bytes);
    defer parsed.deinit();
    const obj = parsed.value().object;
    try std.testing.expectEqualStrings("shutting_down", obj.get("result").?.string);
}

test "sendErrorResponse produces valid response" {
    const allocator = std.testing.allocator;

    // Use a Unix socket pair (Stream uses sendmsg, which requires sockets)
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;

    const write_stream = std.net.Stream{ .handle = fds[1] };
    const read_fd = fds[0];

    try sendErrorResponse(allocator, write_stream, .{ .integer = 42 }, .parse_error, "bad json");
    posix.close(fds[1]);

    // Read from the socket
    var read_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try posix.read(read_fd, read_buf[total..]);
        if (n == 0) break;
        total += n;
    }
    posix.close(read_fd);

    // Parse and verify
    var parsed = try protocol.parseMessage(allocator, read_buf[0..total]);
    defer parsed.deinit();
    const obj = parsed.value().object;
    try std.testing.expectEqual(@as(i64, 42), obj.get("id").?.integer);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("bad json", err_obj.get("message").?.string);
}

test "Client struct layout" {
    _ = @typeInfo(Client);
    _ = @hasField(Client, "allocator");
    _ = @hasField(Client, "stream");
    _ = @hasField(Client, "next_id");
}

test "ParsedResponse struct layout" {
    _ = @typeInfo(ParsedResponse);
    _ = @hasField(ParsedResponse, "parsed");
    _ = @hasField(ParsedResponse, "result");
    _ = @hasField(ParsedResponse, "is_error");
}

test "extractIntParam extracts from object" {
    const allocator = std.testing.allocator;
    var obj = json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("tab", .{ .integer = 3 });
    try obj.put("name", .{ .string = "test" });

    const params: json.Value = .{ .object = obj };
    try std.testing.expectEqual(@as(?i64, 3), extractIntParam(params, "tab"));
    try std.testing.expect(extractIntParam(params, "name") == null); // string, not integer
    try std.testing.expect(extractIntParam(params, "missing") == null);
}

test "extractIntParam handles null and absent params" {
    try std.testing.expect(extractIntParam(null, "key") == null);
    try std.testing.expect(extractIntParam(.null, "key") == null);
}

test "Server dispatch handles new methods without crashing" {
    // Verify the dispatch table includes the new methods (they will fail with
    // browser_not_found since no browser is running, but they should not crash)
    const allocator = std.testing.allocator;
    var server = Server.init(allocator);
    defer server.deinit();

    // browser.url — needs profile param
    {
        var params_obj = json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("profile", .{ .string = "nonexistent" });
        const req = protocol.Request{
            .method = "browser.url",
            .params = .{ .object = params_obj },
            .id = .{ .integer = 10 },
        };
        const response_bytes = try server.dispatch(req);
        defer allocator.free(response_bytes);
        // Should get an error (browser not found), not a crash
        var parsed = try protocol.parseMessage(allocator, response_bytes);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expect(obj.get("error") != null);
    }

    // tab.list — needs profile param
    {
        var params_obj = json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("profile", .{ .string = "nonexistent" });
        const req = protocol.Request{
            .method = "tab.list",
            .params = .{ .object = params_obj },
            .id = .{ .integer = 11 },
        };
        const response_bytes = try server.dispatch(req);
        defer allocator.free(response_bytes);
        var parsed = try protocol.parseMessage(allocator, response_bytes);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expect(obj.get("error") != null);
    }

    // tab.new — needs profile param
    {
        var params_obj = json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("profile", .{ .string = "nonexistent" });
        const req = protocol.Request{
            .method = "tab.new",
            .params = .{ .object = params_obj },
            .id = .{ .integer = 12 },
        };
        const response_bytes = try server.dispatch(req);
        defer allocator.free(response_bytes);
        var parsed = try protocol.parseMessage(allocator, response_bytes);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expect(obj.get("error") != null);
    }

    // tab.close — needs profile + tab params
    {
        var params_obj = json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("profile", .{ .string = "nonexistent" });
        try params_obj.put("tab", .{ .integer = 0 });
        const req = protocol.Request{
            .method = "tab.close",
            .params = .{ .object = params_obj },
            .id = .{ .integer = 13 },
        };
        const response_bytes = try server.dispatch(req);
        defer allocator.free(response_bytes);
        var parsed = try protocol.parseMessage(allocator, response_bytes);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expect(obj.get("error") != null);
    }

    // tab.switch — needs profile + tab params
    {
        var params_obj = json.ObjectMap.init(allocator);
        defer params_obj.deinit();
        try params_obj.put("profile", .{ .string = "nonexistent" });
        try params_obj.put("tab", .{ .integer = 0 });
        const req = protocol.Request{
            .method = "tab.switch",
            .params = .{ .object = params_obj },
            .id = .{ .integer = 14 },
        };
        const response_bytes = try server.dispatch(req);
        defer allocator.free(response_bytes);
        var parsed = try protocol.parseMessage(allocator, response_bytes);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expect(obj.get("error") != null);
    }
}

test "collapseTilde replaces home prefix with ~" {
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse return;

    // Path under home
    const input = try std.fmt.allocPrint(allocator, "{s}/.hibrow/profiles/test", .{home});
    defer allocator.free(input);
    const result = try collapseTilde(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("~/.hibrow/profiles/test", result);

    // Path not under home
    const other = try collapseTilde(allocator, "/tmp/something");
    defer allocator.free(other);
    try std.testing.expectEqualStrings("/tmp/something", other);

    // Empty path
    const empty = try collapseTilde(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}
