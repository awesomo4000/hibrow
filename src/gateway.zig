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
const builtin = @import("builtin");
const mem = std.mem;
const posix = std.posix;
const json = std.json;
const protocol = @import("protocol.zig");
const browser_mod = @import("browser.zig");
const cdp = @import("cdp.zig");
const marionette_mod = @import("marionette.zig");
const os = @import("os.zig");
const build_info = @import("build_info");

/// This binary's build fingerprint (a hash of its source, computed in build.zig). The
/// daemon and CLI are the same binary, so a rebuild or upgrade changes this value. Used
/// to warn when a running gateway differs from the binary now on disk.
pub const build_id = build_info.build_id;

/// Print a one-line note to stderr when the running gateway was built from a
/// different hibrow binary than this CLI. Warn-only by design: the gateway keeps
/// running (and keeps its browsers) — the user decides whether to restart it. The
/// note goes to stderr so it never contaminates command output an agent parses.
fn warnVersionSkew(daemon_build: []const u8) void {
    _ = daemon_build;
    std.debug.print(
        "note: the running hibrow gateway was built from a different hibrow binary than this " ++
        "CLI (it predates a rebuild or upgrade). It keeps serving its old behavior until " ++
        "restarted. Run 'hibrow gateway stop' to load the current version; your browsers " ++
        "stay open.\n",
        .{},
    );
}

/// Socket filename within the per-user directory.
const socket_filename = "gateway.sock";

/// PID filename within the per-user directory.
const pid_filename = "gateway.pid";

/// Singleton lock filename within the per-user directory.
const lock_filename = "gateway.lock";

/// Read buffer size for socket I/O.
const read_buf_size = 8192;

/// The network stream type.
const Stream = std.Io.net.Stream;

/// Wrap an existing (blocking) socket fd as a Stream. Used only by the POSIX
/// socketpair tests below.
fn streamFromFd(fd: posix.fd_t) Stream {
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } };
}

/// Blocking read from the stream's socket (see os.sockRead).
fn streamRead(io: std.Io, stream: Stream, buf: []u8) !usize {
    return os.sockRead(io, stream, buf);
}

/// Write all bytes to the stream's socket (see os.sockWriteAll).
fn streamWriteAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    return os.sockWriteAll(io, stream, bytes);
}

/// Sleep for the given number of milliseconds. Kept as a thin re-export so
/// existing callers (and `hibrow.gateway.sleepMs`) keep working.
pub fn sleepMs(ms: u64) void {
    os.sleepMs(ms);
}

// ---------------------------------------------------------------------------
// Gateway Client
// ---------------------------------------------------------------------------

/// Client for communicating with the gateway daemon over a Unix socket.
pub const Client = struct {
    allocator: mem.Allocator,
    io: std.Io,
    stream: Stream,
    /// Monotonically increasing request ID.
    next_id: u64 = 1,
    /// Set once a version-skew warning has been printed, so a process that makes
    /// several calls warns at most once.
    warned: bool = false,

    /// Connect to the gateway daemon. Tries the socket directly, and if
    /// connection fails, attempts to auto-start the daemon and retry.
    pub fn connect(allocator: mem.Allocator, io: std.Io) !Client {
        return connectImpl(allocator, io, true);
    }

    /// Connect to the gateway daemon without auto-starting it.
    /// Returns error.ConnectionRefused if the daemon is not running.
    pub fn connectNoAutoStart(allocator: mem.Allocator, io: std.Io) !Client {
        return connectImpl(allocator, io, false);
    }

    fn connectImpl(allocator: mem.Allocator, io: std.Io, auto_start: bool) !Client {
        const socket_path = try getSocketPath(allocator);
        defer allocator.free(socket_path);

        // First attempt
        if (connectToSocket(io, socket_path)) |stream| {
            return .{ .allocator = allocator, .io = io, .stream = stream };
        } else |_| {}

        if (!auto_start) return error.ConnectionRefused;

        // Auto-start daemon and retry
        try autoStartDaemon(io);

        // Poll for the socket to appear (up to 5 seconds).
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            sleepMs(100);
            if (connectToSocket(io, socket_path)) |stream| {
                return .{ .allocator = allocator, .io = io, .stream = stream };
            } else |_| {}
            // Re-attempt auto-start roughly every second: our first fork may have
            // lost a race to a daemon that was shutting down (its singleton lock
            // briefly held) and then exited on WouldBlock, so no socket appears.
            // Once the lock frees, a later fork becomes the daemon.
            if (attempts % 10 == 9) autoStartDaemon(io) catch {};
        }

        return error.GatewayStartFailed;
    }

    /// Disconnect from the gateway.
    pub fn disconnect(self: *Client) void {
        self.stream.close(self.io);
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
        try streamWriteAll(self.io, self.stream, req_bytes);

        // Read response line
        const line = try readLine(self.allocator, self.io, self.stream);
        errdefer self.allocator.free(line);

        // Parse the response
        var parsed = try protocol.parseMessage(self.allocator, line);
        self.allocator.free(line);

        // Check for error response
        const val = parsed.value();
        if (val == .object) {
            if (!self.warned) {
                if (val.object.get("gw")) |gw_val| {
                    if (gw_val == .string and gw_val.string.len > 0 and
                        !mem.eql(u8, gw_val.string, build_id))
                    {
                        self.warned = true;
                        warnVersionSkew(gw_val.string);
                    }
                }
            }
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
    io: std.Io,
    listener: ?std.Io.net.Server = null,
    socket_path: ?[]u8 = null,
    /// Exclusive lock held for the daemon's lifetime; released on close/exit so a
    /// dead daemon never blocks the next. Its path is kept to free on deinit.
    lock_file: ?std.Io.File = null,
    lock_path: ?[]u8 = null,
    running: bool = false,
    /// Cached CDP connections keyed by profile name (owned strings).
    connections: std.StringHashMap(ProfileConn),
    /// Cached profile→(port, browser_type) resolutions keyed by profile name
    /// (owned strings). Avoids re-scanning the process table on every command;
    /// the scan is the dominant per-command cost. Validity is checked cheaply
    /// before each use (see resolveBrowser) and the entry is dropped if the
    /// browser is gone, so a restart self-heals without a visible failure.
    resolutions: std.StringHashMap(BrowserInfo),

    pub fn init(allocator: mem.Allocator, io: std.Io) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .connections = std.StringHashMap(ProfileConn).init(allocator),
            .resolutions = std.StringHashMap(BrowserInfo).init(allocator),
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

        // Free resolution cache keys
        var rit = self.resolutions.keyIterator();
        while (rit.next()) |key| self.allocator.free(key.*);
        self.resolutions.deinit();

        if (self.listener) |*l| l.deinit(self.io);
        if (self.socket_path) |p| {
            // Remove socket file on cleanup
            std.Io.Dir.deleteFileAbsolute(self.io, p) catch {};
            self.allocator.free(p);
        }
        // Release the singleton lock (closing the file drops the lock). Leave the
        // lock file in place — deleting it could race a daemon that just opened it.
        if (self.lock_file) |*f| f.close(self.io);
        if (self.lock_path) |p| self.allocator.free(p);
    }

    /// Start listening and serving requests. Blocks until shutdown() is called.
    pub fn serve(self: *Server) !void {
        // Keep the socket path local until we actually own the lock. If we do NOT
        // own it (another daemon is running), self.socket_path must stay null, or
        // deinit would delete the live owner's socket file and wedge it.
        const sock_path = try getSocketPath(self.allocator);
        errdefer if (self.socket_path == null) self.allocator.free(sock_path);

        // Ensure socket directory exists
        const sock_dir = try getSocketDir(self.allocator);
        defer self.allocator.free(sock_dir);
        std.Io.Dir.cwd().createDirPath(self.io, sock_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Acquire the singleton lock before touching the socket. Exactly one daemon
        // can hold this exclusive advisory lock; it is released when this process
        // closes the file or exits (even on a crash), so a dead daemon never blocks
        // the next one. If another daemon holds it, we are not the owner — return
        // without unlinking its socket, which is how orphaned daemons used to happen.
        const lock_path = try getLockPath(self.allocator);
        self.lock_path = lock_path;
        self.lock_file = std.Io.Dir.createFileAbsolute(self.io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.GatewayAlreadyRunning,
            else => return err,
        };

        // We own the singleton now; take ownership of the socket path so cleanup
        // deletes it, and remove any stale file (a prior daemon's leftover) — which
        // cannot steal a live daemon's socket, since no other daemon holds the lock.
        self.socket_path = sock_path;
        std.Io.Dir.deleteFileAbsolute(self.io, sock_path) catch {};

        // Write PID file
        try writePidFile(self.allocator, self.io, sock_dir);

        // Bind and listen
        const addr = try std.Io.net.UnixAddress.init(sock_path);
        self.listener = try addr.listen(self.io, .{
            .kernel_backlog = 128,
        });
        self.running = true;

        // Accept loop
        while (self.running) {
            const stream = self.listener.?.accept(self.io) catch |err| {
                if (!self.running) break;
                // Log and continue on transient errors
                std.debug.print("accept error: {any}\n", .{err});
                continue;
            };
            // Handle each connection synchronously (simple, correct).
            // CDP is not thread-safe per-browser anyway, so serial is fine.
            self.handleConnection(stream);
        }
    }

    /// Graceful shutdown.
    pub fn shutdown(self: *Server) void {
        self.running = false;
        // Close the listener to unblock accept()
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
    }

    /// Handle a single client connection: read request, dispatch, write response.
    fn handleConnection(self: *Server, stream: Stream) void {
        defer stream.close(self.io);

        const line = readLine(self.allocator, self.io, stream) catch return;
        defer self.allocator.free(line);
        if (line.len == 0) return;

        // Parse JSON
        var parsed = protocol.parseMessage(self.allocator, line) catch {
            sendErrorResponse(self.allocator, self.io, stream, .null, .parse_error, "Parse error") catch {};
            return;
        };
        defer parsed.deinit();

        // Extract request
        const req = protocol.extractRequest(parsed.value()) catch {
            sendErrorResponse(self.allocator, self.io, stream, .null, .invalid_request, "Invalid request") catch {};
            return;
        };

        // Dispatch to handler
        const response_bytes = self.dispatch(req) catch |err| {
            sendErrorResponse(self.allocator, self.io, stream, req.id, .internal_error, @errorName(err)) catch {};
            return;
        };
        defer self.allocator.free(response_bytes);

        streamWriteAll(self.io, stream, response_bytes) catch {};
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
            .{ "browser.frames", wrapWithParams(handleBrowserFrames) },
            .{ "browser.click", wrapWithParams(handleBrowserClick) },
            .{ "browser.wait", wrapWithParams(handleBrowserWait) },
            .{ "browser.navigate", wrapWithParams(handleBrowserNavigate) },
            .{ "browser.get", wrapWithParams(handleBrowserGet) },
            .{ "browser.kill", wrapWithParams(handleBrowserKill) },
            .{ "browser.url", wrapWithParams(handleBrowserUrl) },
            .{ "browser.screenshot", wrapWithParams(handleBrowserScreenshot) },
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
        var resp = protocol.makeResponse(id, result);
        resp.gw = build_id;
        return resp.encode(self.allocator);
    }

    fn fail(self: *Server, id: json.Value, code: protocol.ErrorCode, message: []const u8) []u8 {
        var resp = protocol.makeErrorResponse(id, code, message);
        resp.gw = build_id;
        return resp.encode(self.allocator) catch &.{};
    }

    /// Get a cached CDP connection for a profile, or create one if not cached.
    /// Returns a pointer to the cached Connection, or null if browser not found.
    fn getConnection(self: *Server, profile: []const u8) ?*cdp.Connection {
        // Check cache first
        if (self.connections.getPtr(profile)) |pc| {
            return &pc.conn;
        }

        // Not cached — resolve the port (resolution cache first, scan on miss)
        const info = (self.resolveBrowser(profile) catch null) orelse return null;
        const resolved_port = info.port;

        // Discover targets via HTTP
        const targets = cdp.discoverTargets(self.allocator, self.io, resolved_port) catch return null;
        defer cdp.freeTargets(self.allocator, targets);

        const ws_url = findPageTarget(targets) orelse return null;

        // Connect WebSocket
        var conn = cdp.Connection.init(self.allocator, self.io);
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

    /// Run a CDP operation against the cached chrome connection, reconnecting
    /// once if the cached socket has gone stale. Chrome can close a target's
    /// websocket between commands (a tab closing, an idle teardown), leaving the
    /// cached connection dead; the first use then fails with EOF
    /// (`UnexpectedEndOfInput`). Rather than surface that as a command failure,
    /// evict and retry once on a fresh connection. A second failure propagates.
    /// `error.BrowserNotFound` means the browser could not be resolved at all.
    fn chromeOp(self: *Server, profile: []const u8, ctx: OpCtx, comptime op: anytype) !OpPayload(@TypeOf(op)) {
        const conn1 = self.getConnection(profile) orelse return error.BrowserNotFound;
        if (op(conn1, ctx)) |r| return r else |e| {
            // Only a stale/broken connection is worth a reconnect-and-retry. An
            // application result like "element not found" will come back the same
            // on a fresh connection, and for a waiting op (click) retrying would
            // repeat the whole timeout — so surface those immediately.
            if (!isTransientConnError(e)) return e;
            self.evict(profile);
        }
        const conn2 = self.getConnection(profile) orelse return error.BrowserNotFound;
        return op(conn2, ctx) catch |e| {
            self.evict(profile);
            return e;
        };
    }

    /// Evict a cached connection for a profile, closing the WebSocket.
    fn evictConnection(self: *Server, profile: []const u8) void {
        if (self.connections.fetchRemove(profile)) |kv| {
            var pc = kv.value;
            pc.conn.deinit();
            self.allocator.free(kv.key);
        }
    }

    /// Drop a cached port/type resolution for a profile. Leaves any live
    /// connection alone (use evict() to drop both).
    fn evictResolution(self: *Server, profile: []const u8) void {
        if (self.resolutions.fetchRemove(profile)) |kv| self.allocator.free(kv.key);
    }

    /// Forget everything cached for a profile — the live socket and the
    /// port/type resolution. Used on kill and whenever an operation against the
    /// cache fails, since a failure can mean the browser is gone.
    fn evict(self: *Server, profile: []const u8) void {
        self.evictConnection(profile);
        self.evictResolution(profile);
    }

    /// Cheap liveness check: can we open a TCP connection to the debug port on
    /// loopback? A dead listener (browser crashed or was replaced) refuses fast,
    /// so this costs well under a millisecond and lets resolveBrowser validate a
    /// cached entry before trusting it — far cheaper than the process scan it
    /// replaces. It does not prove the listener is still the same browser; a
    /// stale socket that survives is caught by the operation failing and
    /// evicting.
    fn portAlive(self: *Server, port: u16) bool {
        const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch return false;
        stream.close(self.io);
        return true;
    }

    /// Resolve a profile to its browser's debug port and type, consulting the
    /// resolution cache first and scanning the process table only on a miss (or
    /// when a cached entry fails its liveness check). Every hot-path handler
    /// goes through here instead of calling findBrowserInfo directly, which is
    /// what keeps the ~100ms scan off warm commands.
    fn resolveBrowser(self: *Server, profile: []const u8) !?BrowserInfo {
        if (self.resolutions.get(profile)) |info| {
            if (self.portAlive(info.port)) return info;
            // Listener gone — drop the stale resolution and its dead socket,
            // then fall through to a fresh scan so the caller never sees it.
            self.evict(profile);
        }

        const info = (try findBrowserInfo(self.allocator, self.io, profile)) orelse return null;

        // Cache for next time. A cache-put failure is non-fatal: we still
        // return the resolution, the next command just scans again.
        const key = self.allocator.dupe(u8, profile) catch return info;
        self.resolutions.put(key, info) catch {
            self.allocator.free(key);
        };
        return info;
    }

    /// Is a browser for this profile actually usable right now? True only when
    /// the process scan finds it AND its debug port answers. A dying instance
    /// whose port has closed (but whose renderer/crashpad processes still carry
    /// the profile in their command line) counts as gone — which is exactly what
    /// a kill waits for and what a relaunch must not mistake for "already
    /// running". On a scan error we assume still-running so a waiter keeps
    /// waiting rather than declaring a premature exit.
    fn stillRunning(self: *Server, profile: []const u8) bool {
        const info = findBrowserInfo(self.allocator, self.io, profile) catch return true;
        if (info) |i| return self.portAlive(i.port);
        return false;
    }

    /// Block until no usable browser remains for the profile, or the timeout
    /// elapses. Returns true if it is gone. Polls cheaply (a sub-ms port probe
    /// behind each scan), so a browser that exits in a second returns in about a
    /// second.
    fn waitForGone(self: *Server, profile: []const u8, timeout_ms: u64) bool {
        var waited: u64 = 0;
        while (waited < timeout_ms) : (waited += 100) {
            if (!self.stillRunning(profile)) return true;
            sleepMs(100);
        }
        return !self.stillRunning(profile);
    }

    /// Collect the OS pids of every process whose command line names this
    /// profile (browser plus its children). Caller frees. Empty slice if none.
    fn profilePids(self: *Server, profile: []const u8) ![]os.Pid {
        const browsers = try browser_mod.discover(self.allocator, self.io);
        defer browser_mod.freeBrowsers(self.allocator, browsers);
        for (browsers) |b| {
            if (mem.eql(u8, b.profile, profile)) {
                return self.allocator.dupe(os.Pid, b.pids);
            }
        }
        return self.allocator.alloc(os.Pid, 0);
    }

    /// Serialize a Browser struct to a JSON object value.
    fn browserToJson(self: *Server, b: browser_mod.Browser) !json.ObjectMap {
        var obj: json.ObjectMap = .empty;
        try obj.put(self.allocator, "profile", .{ .string = b.profile });
        try obj.put(self.allocator, "port", .{ .integer = @intCast(b.port) });
        var pids_arr = json.Array.init(self.allocator);
        for (b.pids) |pid| {
            try pids_arr.append(.{ .integer = @intCast(pid) });
        }
        try obj.put(self.allocator, "pids", .{ .array = pids_arr });
        const display_dir = try collapseTilde(self.allocator, b.profile_dir);
        try obj.put(self.allocator, "profile_dir", .{ .string = display_dir });
        try obj.put(self.allocator, "browser_type", .{ .string = b.browser_type.toString() });
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

        var rit = self.resolutions.keyIterator();
        while (rit.next()) |key| self.allocator.free(key.*);
        self.resolutions.clearRetainingCapacity();

        // Shut down after encoding the response so the client gets the reply.
        self.running = false;
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
        if (self.socket_path) |p| std.Io.Dir.deleteFileAbsolute(self.io, p) catch {};

        return encoded;
    }

    fn handleBrowserList(self: *Server, id: json.Value) ![]u8 {
        const browsers = browser_mod.discover(self.allocator, self.io) catch
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

        // Already running? Check via process scan — but only reuse an instance
        // whose debug port actually answers. A process that lingers after a kill
        // (or that crashed) can still appear in the scan with a port that no
        // longer listens; reusing it hands back a dead port and the next command
        // fails. When the port is dead, drop any stale resolution, wait briefly
        // for the zombie to clear, and fall through to a fresh launch.
        if (try findBrowserInfo(self.allocator, self.io, profile)) |ei| {
            if (self.portAlive(ei.port)) {
                var obj: json.ObjectMap = .empty;
                defer obj.deinit(self.allocator);
                try obj.put(self.allocator, "profile", .{ .string = profile });
                try obj.put(self.allocator, "port", .{ .integer = @intCast(ei.port) });
                try obj.put(self.allocator, "already_running", .{ .bool = true });
                try obj.put(self.allocator, "browser_type", .{ .string = browser_type.toString() });
                return self.ok(id, .{ .object = obj });
            }
            self.evict(profile);
            _ = self.waitForGone(profile, 3_000);
        }

        const b = browser_mod.launch(self.allocator, self.io, .{
            .profile = profile,
            .proxy = extractStringParam(params, "proxy"),
            .proxy_dns = extractBoolParam(params, "proxy_dns") orelse false,
            .headless = extractBoolParam(params, "headless") orelse false,
            .allow_autoplay = extractBoolParam(params, "allow_autoplay") orelse false,
            .browser_type = browser_type,
        }) catch |err|
            return self.fail(id, .browser_launch_failed, @errorName(err));
        defer self.allocator.free(b.profile);

        var obj = try self.browserToJson(b);
        defer obj.deinit(self.allocator);
        return self.ok(id, .{ .object = obj });
    }

    fn handleBrowserEval(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const expression = extractStringParam(params, "expression") orelse
            return self.fail(id, .invalid_params, "Missing 'expression' parameter");
        // Optional frame path: "1,0,0" / "#outer/#inner" — eval inside a nested frame.
        const frame = extractStringParam(params, "frame");
        // `eval --await`: await a returned promise, bounded by timeout_ms.
        const want_await = extractBoolParam(params, "await") orelse false;
        const timeout_ms: i64 = extractIntParam(params, "timeout_ms") orelse 30000;

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        if (want_await) return self.handleBrowserEvalAwait(id, profile, expression, frame, timeout_ms, info);

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const eval_result = (if (frame) |f|
                    conn.evalInFrame(f, expression)
                else
                    conn.eval(expression)) catch
                    return self.fail(id, .cdp_error, "Eval failed");
                if (eval_result.exception) |exc| {
                    defer self.allocator.free(exc);
                    return self.fail(id, .cdp_error, exc);
                }
                return self.ok(id, eval_result.value);
            },
            .chrome => {
                const eval_result = self.chromeOp(profile, .{ .expr = expression, .frame = frame }, opEval) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Eval failed"),
                };
                if (eval_result.exception) |exc| {
                    defer self.allocator.free(exc);
                    return self.fail(id, .cdp_error, exc);
                }
                return self.ok(id, eval_result.value);
            },
        }
    }

    /// `eval --await`: run the user's code and settle a returned promise, bounded
    /// page-side by timeout_ms (see cdp.buildAwaitScript). The settled outcome
    /// comes back in a `{__hibrow:...}` envelope that finishAwait classifies into
    /// a value, a JS error, or a timeout. Deliberately does NOT retry the user's
    /// script on a dropped connection — re-running could repeat a mutation — so a
    /// mid-await disconnect becomes a context-loss error.
    fn handleBrowserEvalAwait(self: *Server, id: json.Value, profile: []const u8, expression: []const u8, frame: ?[]const u8, timeout_ms: i64, info: BrowserInfo) ![]u8 {
        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const eval_result = (if (frame) |f|
                    conn.evalAwaitTimeoutInFrame(f, expression, timeout_ms)
                else
                    conn.evalAwaitTimeout(expression, timeout_ms)) catch
                    return self.fail(id, .context_lost, "execution context lost during eval --await");
                return self.finishAwait(id, eval_result.exception, eval_result.value);
            },
            .chrome => {
                // Warm the cached socket first: Chrome idly closes a target's
                // websocket between commands, and that stale-socket reconnect is
                // the one retry we allow. It must happen BEFORE the user's script
                // runs, because the await itself is never retried (it may have
                // mutated page state). A trivial eval reconnects a dead socket.
                _ = self.chromeOp(profile, .{ .expr = "0" }, opEval) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => {}, // non-connection failure: let the real call report it
                };
                const conn = self.getConnection(profile) orelse
                    return self.fail(id, .browser_not_found, "Browser not found");
                const eval_result = opEvalAwait(conn, .{ .expr = expression, .frame = frame, .timeout_ms = timeout_ms }) catch {
                    self.evict(profile);
                    return self.fail(id, .context_lost, "execution context lost during eval --await");
                };
                return self.finishAwait(id, eval_result.exception, eval_result.value);
            },
        }
    }

    /// Turn an await envelope (or a context-loss exception) into a response.
    fn finishAwait(self: *Server, id: json.Value, exception: ?[]const u8, value: json.Value) ![]u8 {
        if (exception) |exc| {
            defer self.allocator.free(exc);
            // With script errors captured inside the envelope, a raw exception
            // here means the context went away before the envelope could resolve.
            return self.fail(id, .context_lost, exc);
        }
        return switch (classifyAwaitEnvelope(value)) {
            .ok => |v| self.ok(id, v),
            .timeout => self.fail(id, .eval_timeout, "eval --await timed out; the script may still be running in the page"),
            .js_error => |m| self.fail(id, .cdp_error, m),
            .malformed => self.fail(id, .cdp_error, "malformed eval --await result"),
        };
    }

    fn handleBrowserFrames(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const frames = conn.frameList() catch
                    return self.fail(id, .cdp_error, "frame list failed");
                return self.ok(id, frames);
            },
            .chrome => {
                const frames = self.chromeOp(profile, .{}, opFrames) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "frame list failed"),
                };
                return self.ok(id, frames);
            },
        }
    }

    fn handleBrowserClick(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const selector = extractStringParam(params, "selector") orelse
            return self.fail(id, .invalid_params, "Missing 'selector' parameter");
        const frame = extractStringParam(params, "frame");
        // How long to wait for the target to appear before failing. Defaults to
        // 5s so a click rides out a not-yet-ready frame/shadow subtree.
        const timeout_ms: i64 = extractIntParam(params, "timeout_ms") orelse 5000;

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                if (frame) |f| conn.switchToFramePath(f) catch
                    return self.fail(id, .cdp_error, "Frame not found");
                conn.clickElement(selector, timeout_ms) catch
                    return self.fail(id, .cdp_error, "Click failed (element not found?)");
                return self.ok(id, .{ .string = "clicked" });
            },
            .chrome => {
                self.chromeOp(profile, .{ .selector = selector, .frame = frame, .timeout_ms = timeout_ms }, opClick) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Click failed (element not found?)"),
                };
                return self.ok(id, .{ .string = "clicked" });
            },
        }
    }

    fn handleBrowserWait(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const selector = extractStringParam(params, "selector") orelse
            return self.fail(id, .invalid_params, "Missing 'selector' parameter");
        const frame = extractStringParam(params, "frame");
        const timeout_ms = extractIntParam(params, "timeout_ms") orelse 10000;
        const gone = extractBoolParam(params, "gone") orelse false;
        const desired = !gone;

        const wait_expr = try buildWaitExpr(self.allocator, selector, desired, timeout_ms);
        defer self.allocator.free(wait_expr);

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                if (frame) |f| conn.switchToFramePath(f) catch
                    return self.fail(id, .cdp_error, "Frame not found");
                const res = conn.evalAsync(wait_expr, timeout_ms) catch
                    return self.fail(id, .cdp_error, "Wait failed");
                return self.waitResult(id, res);
            },
            .chrome => {
                const res = self.chromeOp(profile, .{ .expr = wait_expr, .frame = frame }, opWait) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Wait failed"),
                };
                return self.waitResult(id, res);
            },
        }
    }

    /// Map a wait eval result to a response: the condition held (true) → ok,
    /// anything else (page-side timeout returned false, or an exception) →
    /// timeout failure. Generic over the Chrome and Firefox EvalResult types;
    /// frees any exception string the result owns.
    fn waitResult(self: *Server, id: json.Value, res: anytype) ![]u8 {
        if (res.value == .bool and res.value.bool) return self.ok(id, .{ .bool = true });
        if (res.exception) |exc| self.allocator.free(exc);
        return self.fail(id, .cdp_error, "Timeout waiting for selector");
    }

    fn handleBrowserNavigate(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const url = extractStringParam(params, "url") orelse
            return self.fail(id, .invalid_params, "Missing 'url' parameter");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                conn.navigate(url) catch
                    return self.fail(id, .cdp_error, "Navigate failed");
            },
            .chrome => {
                self.chromeOp(profile, .{ .url = url }, opNavigate) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Navigate failed"),
                };
            },
        }

        var obj: json.ObjectMap = .empty;
        defer obj.deinit(self.allocator);
        try obj.put(self.allocator, "status", .{ .string = "navigated" });
        try obj.put(self.allocator, "url", .{ .string = url });
        return self.ok(id, .{ .object = obj });
    }

    fn handleBrowserGet(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const browsers = browser_mod.discover(self.allocator, self.io) catch
            return self.fail(id, .internal_error, "Discovery failed");
        defer browser_mod.freeBrowsers(self.allocator, browsers);

        for (browsers) |b| {
            if (mem.eql(u8, b.profile, profile)) {
                var obj = try self.browserToJson(b);
                defer obj.deinit(self.allocator);
                return self.ok(id, .{ .object = obj });
            }
        }

        return self.fail(id, .browser_not_found, "Browser not found");
    }

    fn handleBrowserKill(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                conn.quit() catch {};
            },
            .chrome => {
                // Get browser-level WebSocket URL from /json/version
                const version = cdp.getVersion(self.allocator, self.io, info.port) catch
                    return self.fail(id, .cdp_error, "Could not reach browser");
                defer cdp.freeVersionInfo(self.allocator, version);

                const browser_ws = version.webSocketDebuggerUrl orelse
                    return self.fail(id, .cdp_error, "No browser WebSocket URL");

                var conn = cdp.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(browser_ws) catch
                    return self.fail(id, .cdp_error, "WebSocket connection failed");

                conn.closeBrowser() catch
                    return self.fail(id, .cdp_error, "Browser.close failed");
            },
        }

        // Browser.close / quit only *start* shutdown — the process keeps running
        // for a moment (renderers, GPU, profile writes) and holds the profile's
        // singleton lock until it truly exits. Returning now would let an
        // immediate relaunch see the dying instance and reuse its about-to-close
        // port. So wait for it to actually go, and force it if it will not.
        var exited = self.waitForGone(profile, 10_000);
        var forced = false;
        if (!exited) {
            forced = true;
            const pids = self.profilePids(profile) catch &[_]os.Pid{};
            defer if (pids.len > 0) self.allocator.free(pids);
            for (pids) |p| os.terminateProcess(p, false); // SIGTERM
            exited = self.waitForGone(profile, 3_000);
            if (!exited) {
                for (pids) |p| os.terminateProcess(p, true); // SIGKILL
                exited = self.waitForGone(profile, 3_000);
            }
        }

        // Forget the live socket and the port/type resolution.
        self.evict(profile);

        var obj: json.ObjectMap = .empty;
        defer obj.deinit(self.allocator);
        try obj.put(self.allocator, "killed", .{ .bool = true });
        try obj.put(self.allocator, "exited", .{ .bool = exited });
        try obj.put(self.allocator, "forced", .{ .bool = forced });
        return self.ok(id, .{ .object = obj });
    }

    fn handleBrowserUrl(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");
                const url_str = conn.getCurrentUrl() catch
                    return self.fail(id, .cdp_error, "Could not get URL");
                defer self.allocator.free(url_str);
                return self.ok(id, .{ .string = url_str });
            },
            .chrome => {
                const url_str = self.chromeOp(profile, .{}, opUrl) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Could not get URL"),
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
        const port = (try self.resolveBrowser(profile) orelse return null).port;

        const all_targets = cdp.discoverTargets(self.allocator, self.io, port) catch return null;
        defer cdp.freeTargets(self.allocator, all_targets);

        // Filter to page-type targets, duping them into owned memory
        var pages: std.ArrayList(cdp.Target) = .empty;
        errdefer {
            for (pages.items) |t| {
                self.allocator.free(t.id);
                self.allocator.free(t.title);
                self.allocator.free(t.url);
                self.allocator.free(t.type);
                if (t.webSocketDebuggerUrl) |ws| self.allocator.free(ws);
            }
            pages.deinit(self.allocator);
        }

        for (all_targets) |t| {
            if (mem.eql(u8, t.type, "page")) {
                const ws_url = if (t.webSocketDebuggerUrl) |ws|
                    try self.allocator.dupe(u8, ws)
                else
                    null;
                errdefer if (ws_url) |w| self.allocator.free(w);

                try pages.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, t.id),
                    .title = try self.allocator.dupe(u8, t.title),
                    .url = try self.allocator.dupe(u8, t.url),
                    .type = try self.allocator.dupe(u8, t.type),
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

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
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

                    var obj: json.ObjectMap = .empty;
                    try obj.put(self.allocator, "index", .{ .integer = @intCast(i) });
                    try obj.put(self.allocator, "title", .{ .string = title });
                    try obj.put(self.allocator, "url", .{ .string = url });
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
                    var obj: json.ObjectMap = .empty;
                    try obj.put(self.allocator, "index", .{ .integer = @intCast(i) });
                    try obj.put(self.allocator, "title", .{ .string = t.title });
                    try obj.put(self.allocator, "url", .{ .string = t.url });
                    try arr.append(.{ .object = obj });
                }
                return self.ok(id, .{ .array = arr });
            },
        }
    }

    fn handleTabNew(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        const url = extractStringParam(params, "url");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
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
                var obj: json.ObjectMap = .empty;
                defer obj.deinit(self.allocator);
                try obj.put(self.allocator, "status", .{ .string = "created" });
                try obj.put(self.allocator, "url", .{ .string = url orelse "about:blank" });
                return self.ok(id, .{ .object = obj });
            },
            .chrome => {
                const new_target = cdp.createTarget(self.allocator, self.io, info.port, url) catch
                    return self.fail(id, .cdp_error, "Could not create tab");
                defer {
                    self.allocator.free(new_target.id);
                    self.allocator.free(new_target.title);
                    self.allocator.free(new_target.url);
                    self.allocator.free(new_target.type);
                    if (new_target.webSocketDebuggerUrl) |ws| self.allocator.free(ws);
                }

                self.evictConnection(profile);
                var obj: json.ObjectMap = .empty;
                defer obj.deinit(self.allocator);
                try obj.put(self.allocator, "status", .{ .string = "created" });
                try obj.put(self.allocator, "url", .{ .string = new_target.url });
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

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
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

                cdp.closeTarget(self.allocator, self.io, result.port, result.targets[idx].id) catch
                    return self.fail(id, .cdp_error, "Could not close tab");

                self.evictConnection(profile);
                return self.ok(id, .{ .string = "closed" });
            },
        }
    }

    fn handleBrowserScreenshot(self: *Server, id: json.Value, params: ?json.Value) ![]u8 {
        const profile = extractStringParam(params, "profile") orelse
            return self.fail(id, .invalid_params, "Missing 'profile' parameter");
        const frame = extractStringParam(params, "frame");

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
                defer conn.deinit();
                conn.connect(info.port) catch
                    return self.fail(id, .cdp_error, "Marionette connection failed");

                // Switch tab if requested
                if (extractIntParam(params, "tab")) |tab_idx| {
                    if (tab_idx < 0) return self.fail(id, .invalid_params, "Tab index must be non-negative");
                    const idx: usize = @intCast(tab_idx);
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
                }

                const b64 = (if (frame) |f| conn.screenshotFrame(f) else conn.takeScreenshot()) catch
                    return self.fail(id, .cdp_error, "Screenshot failed");
                defer self.allocator.free(b64);
                return self.ok(id, .{ .string = b64 });
            },
            .chrome => {
                const b64 = self.chromeOp(profile, .{ .frame = frame }, opScreenshot) catch |e| switch (e) {
                    error.BrowserNotFound => return self.fail(id, .browser_not_found, "Browser not found"),
                    else => return self.fail(id, .cdp_error, "Screenshot failed"),
                };
                defer self.allocator.free(b64);
                return self.ok(id, .{ .string = b64 });
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

        const info = try self.resolveBrowser(profile) orelse
            return self.fail(id, .browser_not_found, "Browser not found");

        switch (info.browser_type) {
            .firefox => {
                var conn = marionette_mod.Connection.init(self.allocator, self.io);
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

                cdp.activateTarget(self.allocator, self.io, result.port, result.targets[idx].id) catch
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
    return os.runtimeDir(allocator);
}

/// Get the full socket path.
pub fn getSocketPath(allocator: mem.Allocator) ![]u8 {
    const dir = try os.runtimeDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, socket_filename });
}

/// Get the PID file path.
pub fn getPidFilePath(allocator: mem.Allocator) ![]u8 {
    const dir = try os.runtimeDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, pid_filename });
}

/// Get the singleton lock-file path. A serving daemon holds an exclusive advisory
/// lock on this file for its lifetime, so at most one daemon owns the socket.
pub fn getLockPath(allocator: mem.Allocator) ![]u8 {
    const dir = try os.runtimeDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, lock_filename });
}

// ---------------------------------------------------------------------------
// Auto-start
// ---------------------------------------------------------------------------

/// Try to start the gateway daemon in the background.
/// Forks, child calls setsid, closes stdio, execs gateway in server mode.
pub fn autoStartDaemon(io: std.Io) !void {
    // Get path to our own executable
    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &self_path_buf);
    const self_path = self_path_buf[0..len];

    // Spawn the daemon process, detached in a new process group so it survives
    // our exit, with stdio pointed at /dev/null.
    var child = try std.process.spawn(io, .{
        .argv = &.{ self_path, "gateway", "serve" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = os.new_process_group,
    });
    _ = &child;
    // Don't wait — let the daemon run independently.
}

// ---------------------------------------------------------------------------
// Socket helpers
// ---------------------------------------------------------------------------

/// Connect to an existing Unix domain socket.
fn connectToSocket(io: std.Io, path: []const u8) !Stream {
    const addr = try std.Io.net.UnixAddress.init(path);
    return addr.connect(io);
}

/// Read a newline-delimited line from a stream.
/// Returns allocated slice (caller owns). Does not include the newline.
fn readLine(allocator: mem.Allocator, io: std.Io, stream: Stream) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var read_buf: [read_buf_size]u8 = undefined;
    while (true) {
        const n = try streamRead(io, stream, &read_buf);
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
    io: std.Io,
    stream: Stream,
    id: json.Value,
    code: protocol.ErrorCode,
    message: []const u8,
) !void {
    const resp = protocol.makeErrorResponse(id, code, message);
    const bytes = try resp.encode(allocator);
    defer allocator.free(bytes);
    try streamWriteAll(io, stream, bytes);
}

/// Write a PID file into the socket directory.
fn writePidFile(allocator: mem.Allocator, io: std.Io, sock_dir: []const u8) !void {
    const pid_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sock_dir, pid_filename });
    defer allocator.free(pid_path);

    const file = try std.Io.Dir.cwd().createFile(io, pid_path, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.print("{d}\n", .{os.getpid()});
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

/// Build the JavaScript a wait evaluates: a Promise that resolves true the
/// instant `document.querySelector(selector)` reaches the desired presence, and
/// resolves false after `timeout_ms`. A MutationObserver drives the re-check, so
/// the browser signals the moment the DOM changes instead of us polling. The
/// page-side timeout guarantees the Promise always settles, so the awaiting
/// connection never blocks past the deadline. Caller owns the returned string.
fn buildWaitExpr(allocator: mem.Allocator, selector: []const u8, present: bool, timeout_ms: i64) ![]u8 {
    const sel_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = selector }, .{});
    defer allocator.free(sel_json);
    const want = if (present) "true" else "false";
    return std.fmt.allocPrint(allocator, "(function(){{return new Promise(function(resolve){{" ++
        "var want={s};" ++
        "function hit(){{return (!!document.querySelector({s}))===want;}}" ++
        "if(hit()){{resolve(true);return;}}" ++
        "var t;var obs=new MutationObserver(function(){{if(hit()){{obs.disconnect();clearTimeout(t);resolve(true);}}}});" ++
        "obs.observe(document.documentElement||document,{{childList:true,subtree:true,attributes:true}});" ++
        "t=setTimeout(function(){{obs.disconnect();resolve(false);}},{d});" ++
        "}});}})()", .{ want, sel_json, timeout_ms });
}

/// Find a browser's CDP port by scanning running processes for the given profile.
const BrowserInfo = struct {
    port: u16,
    browser_type: browser_mod.BrowserType,
};

/// Inputs any chrome connection op might need; each op reads only what it uses.
/// An anonymous struct literal at the call site coerces to this, the unused
/// fields taking their defaults.
const OpCtx = struct {
    expr: []const u8 = "",
    selector: []const u8 = "",
    url: []const u8 = "",
    frame: ?[]const u8 = null,
    timeout_ms: i64 = 5000,
};

/// Payload type T of an op with signature `fn (*cdp.Connection, OpCtx) !T`.
fn OpPayload(comptime Op: type) type {
    return @typeInfo(@typeInfo(Op).@"fn".return_type.?).error_union.payload;
}

/// Whether an op error means the cached connection is broken (so a reconnect may
/// help) rather than a real result from the browser. Only these are worth the
/// chromeOp reconnect-and-retry; application errors like ElementNotFound are
/// returned as-is so a waiting op is not run a second time for its full timeout.
fn isTransientConnError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed,
        error.NotConnected,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.EndOfStream,
        error.UnexpectedEndOfInput,
        error.WriteFailed,
        => true,
        else => false,
    };
}

// The chrome operations `chromeOp` can run with one stale-connection retry.
fn opEval(conn: *cdp.Connection, ctx: OpCtx) !cdp.EvalResult {
    return if (ctx.frame) |f| conn.evalInFrame(f, ctx.expr) else conn.eval(ctx.expr);
}
fn opWait(conn: *cdp.Connection, ctx: OpCtx) !cdp.EvalResult {
    return if (ctx.frame) |f| conn.evalAwaitInFrame(f, ctx.expr) else conn.evalAwait(ctx.expr);
}
fn opEvalAwait(conn: *cdp.Connection, ctx: OpCtx) !cdp.EvalResult {
    return if (ctx.frame) |f| conn.evalAwaitTimeoutInFrame(f, ctx.expr, ctx.timeout_ms) else conn.evalAwaitTimeout(ctx.expr, ctx.timeout_ms);
}

/// The classified outcome of an `eval --await` envelope (see cdp.buildAwaitScript).
const AwaitOutcome = union(enum) {
    ok: json.Value, // resolved value (borrows from the envelope)
    js_error: []const u8, // thrown/rejected; message borrows from the envelope
    timeout, // the page-side timer won the race
    malformed, // not a recognizable envelope (should not happen)
};

/// Classify a settled await envelope by its `__hibrow` tag.
fn classifyAwaitEnvelope(env: json.Value) AwaitOutcome {
    if (env != .object) return .malformed;
    const tag = env.object.get("__hibrow") orelse return .malformed;
    if (tag != .string) return .malformed;
    if (std.mem.eql(u8, tag.string, "ok")) return .{ .ok = env.object.get("value") orelse .null };
    if (std.mem.eql(u8, tag.string, "timeout")) return .timeout;
    if (std.mem.eql(u8, tag.string, "err")) {
        const m = env.object.get("message") orelse .null;
        return .{ .js_error = if (m == .string) m.string else "eval --await rejected" };
    }
    return .malformed;
}
fn opFrames(conn: *cdp.Connection, ctx: OpCtx) !json.Value {
    _ = ctx;
    return conn.frameList();
}
fn opClick(conn: *cdp.Connection, ctx: OpCtx) !void {
    return if (ctx.frame) |f| conn.clickInFrame(f, ctx.selector, ctx.timeout_ms) else conn.click(ctx.selector, ctx.timeout_ms);
}
fn opNavigate(conn: *cdp.Connection, ctx: OpCtx) !void {
    return conn.navigate(ctx.url);
}
fn opUrl(conn: *cdp.Connection, ctx: OpCtx) ![]u8 {
    _ = ctx;
    return conn.getUrl();
}
fn opScreenshot(conn: *cdp.Connection, ctx: OpCtx) ![]const u8 {
    return if (ctx.frame) |f| conn.screenshotFrame(f) else conn.takeScreenshot();
}

fn findBrowserInfo(allocator: mem.Allocator, io: std.Io, profile: []const u8) !?BrowserInfo {
    const browsers = try browser_mod.discover(allocator, io);
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
    const home_z = std.c.getenv("HOME") orelse return try allocator.dupe(u8, path);
    const home = mem.span(home_z);
    if (mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        return try std.fmt.allocPrint(allocator, "~{s}", .{rest});
    }
    return try allocator.dupe(u8, path);
}

/// Find the first "page" type target with a webSocketDebuggerUrl.
fn findPageTarget(targets: []const cdp.Target) ?[]const u8 {
    for (targets) |t| {
        if (mem.eql(u8, t.type, "page")) {
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
}

test "getSocketDir is a per-user hibrow directory" {
    const allocator = std.testing.allocator;
    const dir = try getSocketDir(allocator);
    defer allocator.free(dir);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(mem.endsWith(u8, dir, "hibrow"));
    } else {
        try std.testing.expect(mem.startsWith(u8, dir, "/tmp/hibrow-"));
    }
}

test "getSocketPath contains socket filename" {
    const allocator = std.testing.allocator;
    const path = try getSocketPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(mem.endsWith(u8, path, "/gateway.sock"));
}

test "getPidFilePath contains pid filename" {
    const allocator = std.testing.allocator;
    const path = try getPidFilePath(allocator);
    defer allocator.free(path);
    try std.testing.expect(mem.endsWith(u8, path, "/gateway.pid"));
}

test "extractStringParam extracts from object" {
    const allocator = std.testing.allocator;
    var obj: json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "profile", .{ .string = "work" });
    try obj.put(allocator, "count", .{ .integer = 5 });

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
    var obj: json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "proxy_dns", .{ .bool = true });
    try obj.put(allocator, "name", .{ .string = "test" });

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
            .type = "background_page",
            .webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/bg1",
        },
        .{
            .id = "page1",
            .title = "Example",
            .url = "https://example.com",
            .type = "page",
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
            .type = "service_worker",
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
            .type = "page",
            .webSocketDebuggerUrl = null,
        },
    };
    try std.testing.expect(findPageTarget(&targets) == null);
}

test "Server initializes and deinitializes cleanly" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
    // Verify connection cache is empty
    try std.testing.expectEqual(@as(u32, 0), server.connections.count());
    server.deinit();
}

test "Server evictConnection on empty cache is safe" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
    defer server.deinit();
    // Should not crash or leak
    server.evictConnection("nonexistent");
}

test "Server resolution cache put/evict frees keys" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
    defer server.deinit();

    // Seed a resolution directly (bypasses the process scan) with an owned key,
    // the same way resolveBrowser does, and confirm evict paths free it without
    // leaking. The testing allocator fails the test on any leak.
    const key = try allocator.dupe(u8, "work");
    try server.resolutions.put(key, .{ .port = 9222, .browser_type = .chrome });

    // evictResolution drops only the resolution.
    server.evictResolution("work");
    try std.testing.expect(server.resolutions.get("work") == null);

    // evict() and both evictors are safe on an absent profile.
    server.evict("nonexistent");
    server.evictResolution("nonexistent");
}

test "readLine reads up to newline" {
    // POSIX-only: uses socketpair + raw fds. Windows exercises readLine over a
    // real AF_UNIX socket in the e2e suite instead.
    if (builtin.os.tag != .windows) {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;

        const read_stream = streamFromFd(fds[0]);
        const write_fd = fds[1];

        // Write test data with newline
        const test_data = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}\n";
        _ = std.c.write(write_fd, test_data.ptr, test_data.len);
        _ = std.c.close(write_fd);

        const allocator = std.testing.allocator;
        const line = try readLine(allocator, undefined, read_stream);
        defer allocator.free(line);
        defer _ = std.c.close(fds[0]);

        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}", line);
    }
}

test "readLine handles EOF without newline" {
    if (builtin.os.tag != .windows) {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;

        const read_stream = streamFromFd(fds[0]);
        const write_fd = fds[1];

        // Write data without newline, then close
        const partial = "partial data";
        _ = std.c.write(write_fd, partial.ptr, partial.len);
        _ = std.c.close(write_fd);

        const allocator = std.testing.allocator;
        const line = try readLine(allocator, undefined, read_stream);
        defer allocator.free(line);
        defer _ = std.c.close(fds[0]);

        try std.testing.expectEqualStrings("partial data", line);
    }
}

test "Unix socket round-trip" {
    // POSIX-only socket path (/tmp); Windows IPC is covered by the e2e suite.
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;

    // Use a unique socket path to avoid collisions between parallel test runs
    var path_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "/tmp/hibrow-test-{d}.sock", .{os.getpid()});

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Clean up any stale socket
    std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};

    // Create server
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};
    }

    // Connect client (in same thread since we can use non-blocking approach)
    const client_stream = try connectToSocket(io, sock_path);
    defer client_stream.close(io);

    // Accept on server
    const server_stream = try server.accept(io);
    defer server_stream.close(io);

    // Client sends a request
    const req = protocol.Request{
        .method = "gateway.status",
        .id = .{ .integer = 1 },
    };
    const req_bytes = try req.encode(allocator);
    defer allocator.free(req_bytes);
    try streamWriteAll(io, client_stream, req_bytes);

    // Server reads the request
    const line = try readLine(allocator, io, server_stream);
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
    try streamWriteAll(io, server_stream, resp_bytes);

    // Client reads the response
    const resp_line = try readLine(allocator, io, client_stream);
    defer allocator.free(resp_line);

    var resp_parsed = try protocol.parseMessage(allocator, resp_line);
    defer resp_parsed.deinit();
    const resp_obj = resp_parsed.value().object;
    try std.testing.expectEqualStrings("ok", resp_obj.get("result").?.string);
}

test "Server dispatch returns method_not_found for unknown method" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
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
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
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
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
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
    // POSIX-only: uses socketpair + raw fds.
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        // Use a Unix socket pair (Stream uses sendmsg, which requires sockets)
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;

        const write_stream = streamFromFd(fds[1]);
        const read_fd = fds[0];

        try sendErrorResponse(allocator, undefined, write_stream, .{ .integer = 42 }, .parse_error, "bad json");
        _ = std.c.close(fds[1]);

        // Read from the socket
        var read_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try posix.read(read_fd, read_buf[total..]);
            if (n == 0) break;
            total += n;
        }
        _ = std.c.close(read_fd);

        // Parse and verify
        var parsed = try protocol.parseMessage(allocator, read_buf[0..total]);
        defer parsed.deinit();
        const obj = parsed.value().object;
        try std.testing.expectEqual(@as(i64, 42), obj.get("id").?.integer);
        const err_obj = obj.get("error").?.object;
        try std.testing.expectEqual(@as(i64, -32700), err_obj.get("code").?.integer);
        try std.testing.expectEqualStrings("bad json", err_obj.get("message").?.string);
    }
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
    var obj: json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "tab", .{ .integer = 3 });
    try obj.put(allocator, "name", .{ .string = "test" });

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
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var server = Server.init(allocator, threaded.io());
    defer server.deinit();

    // browser.url — needs profile param
    {
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(allocator);
        try params_obj.put(allocator, "profile", .{ .string = "nonexistent" });
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
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(allocator);
        try params_obj.put(allocator, "profile", .{ .string = "nonexistent" });
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
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(allocator);
        try params_obj.put(allocator, "profile", .{ .string = "nonexistent" });
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
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(allocator);
        try params_obj.put(allocator, "profile", .{ .string = "nonexistent" });
        try params_obj.put(allocator, "tab", .{ .integer = 0 });
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
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(allocator);
        try params_obj.put(allocator, "profile", .{ .string = "nonexistent" });
        try params_obj.put(allocator, "tab", .{ .integer = 0 });
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
    const home_z = std.c.getenv("HOME") orelse return;
    const home = mem.span(home_z);

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
