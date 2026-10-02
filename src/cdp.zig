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
pub fn discoverTargets(allocator: mem.Allocator, io: std.Io, port: u16) ![]Target {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json", .{port});
    const body = try httpGet(allocator, io, url);
    defer allocator.free(body);

    // Parse JSON array
    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidResponse;
    const arr = parsed.value.array;

    var targets: std.ArrayList(Target) = .empty;
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
pub fn getVersion(allocator: mem.Allocator, io: std.Io, port: u16) !VersionInfo {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/version", .{port});
    const body = try httpGet(allocator, io, url);
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

/// Build a JS expression that scrolls the selected element into view, dispatches
/// a pointer/mouse event sequence, calls .click(), and returns whether it was
/// found. The halves are plain string literals so the JS braces need no escaping.
fn clickerExpr(allocator: mem.Allocator, selector: []const u8) ![]u8 {
    const sel_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = selector }, .{});
    defer allocator.free(sel_json);
    const prefix = "(function(){var e=document.querySelector(";
    const suffix = ");if(!e)return false;e.scrollIntoView({block:'center'});try{e.focus()}catch(_){}var r=e.getBoundingClientRect();var o={bubbles:true,cancelable:true,view:window,clientX:r.left+r.width/2,clientY:r.top+r.height/2};['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,o))});if(e.click)e.click();return true;})()";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, sel_json, suffix });
}

/// Read a string field from a Page.getFrameTree `frame` object (or "" if absent).
fn frameField(frame: ?json.Value, key: []const u8) []const u8 {
    const f = frame orelse return "";
    if (f != .object) return "";
    const v = f.object.get(key) orelse return "";
    if (v != .string) return "";
    return v.string;
}

/// Extract the frame id from a Page.getFrameTree node:
/// {frame: {id, url, ...}, childFrames?: [...]}.
fn frameIdOf(node: json.Value) ?[]const u8 {
    if (node != .object) return null;
    const fr = node.object.get("frame") orelse return null;
    if (fr != .object) return null;
    const idv = fr.object.get("id") orelse return null;
    if (idv != .string) return null;
    return idv.string;
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

    pub fn init(allocator: mem.Allocator, io: std.Io) Connection {
        return .{
            .allocator = allocator,
            .ws = websocket.WebSocket.init(allocator, io),
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

    /// Parse a Runtime.evaluate CDP result into an EvalResult.
    /// CDP returns {"result": {"type": "...", "value": ...}, "exceptionDetails": {...}}.
    fn parseEvalResult(self: *Connection, result: json.Value) !EvalResult {
        if (result == .object) {
            const result_obj = result.object;
            if (result_obj.get("exceptionDetails")) |exception| {
                if (exception == .object) {
                    if (exception.object.get("text")) |text| {
                        if (text == .string) {
                            return .{ .exception = try self.allocator.dupe(u8, text.string) };
                        }
                    }
                }
                return .{ .exception = try self.allocator.dupe(u8, "Unknown exception") };
            }
            if (result_obj.get("result")) |inner_result| {
                if (inner_result == .object) {
                    if (inner_result.object.get("value")) |val| {
                        return .{ .value = try cloneJsonValue(self.allocator, val) };
                    }
                }
            }
        }
        return .{};
    }

    /// Evaluate JavaScript in the connected target (top frame).
    pub fn eval(self: *Connection, expression: []const u8) !EvalResult {
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(self.allocator);
        try params_obj.put(self.allocator, "expression", .{ .string = expression });
        try params_obj.put(self.allocator, "returnByValue", .{ .bool = true });

        var cdp_result = try self.send("Runtime.evaluate", .{ .object = params_obj });
        defer cdp_result.deinit();
        return self.parseEvalResult(cdp_result.result);
    }

    /// Evaluate JavaScript within a specific execution context (used for frames).
    fn evalInContext(self: *Connection, context_id: i64, expression: []const u8) !EvalResult {
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(self.allocator);
        try params_obj.put(self.allocator, "expression", .{ .string = expression });
        try params_obj.put(self.allocator, "returnByValue", .{ .bool = true });
        try params_obj.put(self.allocator, "contextId", .{ .integer = context_id });

        var cdp_result = try self.send("Runtime.evaluate", .{ .object = params_obj });
        defer cdp_result.deinit();
        return self.parseEvalResult(cdp_result.result);
    }

    /// Create an isolated world for a frame and return its execution context id.
    /// Isolated worlds share the frame's DOM and session (cookies/login) but not
    /// the page's own JS globals — sufficient for DOM reads, clicks, form fills.
    fn createIsolatedWorld(self: *Connection, frame_id: []const u8) !i64 {
        var p: json.ObjectMap = .empty;
        defer p.deinit(self.allocator);
        try p.put(self.allocator, "frameId", .{ .string = frame_id });
        try p.put(self.allocator, "worldName", .{ .string = "hibrow" });
        try p.put(self.allocator, "grantUniveralAccess", .{ .bool = true });

        var r = try self.send("Page.createIsolatedWorld", .{ .object = p });
        defer r.deinit();
        if (r.result == .object) {
            if (r.result.object.get("executionContextId")) |c| {
                if (c == .integer) return c.integer;
            }
        }
        return error.FrameContextFailed;
    }

    /// Find the child-frame index of the <iframe>/<frame> matching `selector`
    /// within the frame identified by `frame_id`.
    fn selectorFrameIndex(self: *Connection, frame_id: []const u8, selector: []const u8) !usize {
        const ctx = try self.createIsolatedWorld(frame_id);
        const sel_json = try json.Stringify.valueAlloc(self.allocator, json.Value{ .string = selector }, .{});
        defer self.allocator.free(sel_json);
        const expr = try std.fmt.allocPrint(self.allocator, "(function(){{var t=document.querySelector({s});var l=[].slice.call(document.querySelectorAll('iframe,frame'));return l.indexOf(t);}})()", .{sel_json});
        defer self.allocator.free(expr);

        const res = try self.evalInContext(ctx, expr);
        if (res.exception) |e| {
            self.allocator.free(e);
            return error.FrameNotFound;
        }
        if (res.value == .integer and res.value.integer >= 0) return @intCast(res.value.integer);
        return error.FrameNotFound;
    }

    /// Resolve a frame path ("1,0,0" / "#outer/#inner") to a CDP frameId.
    /// Caller owns the returned slice.
    fn resolveFramePath(self: *Connection, frame_path: []const u8) ![]u8 {
        var tree = try self.send("Page.getFrameTree", null);
        defer tree.deinit();
        if (tree.result != .object) return error.FrameNotFound;
        var node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;

        var current_id = try self.allocator.dupe(u8, frameIdOf(node) orelse return error.FrameNotFound);
        errdefer self.allocator.free(current_id);

        var it = mem.tokenizeAny(u8, frame_path, ",/");
        while (it.next()) |seg| {
            const children = node.object.get("childFrames");
            const arr: []const json.Value = if (children) |c|
                (if (c == .array) c.array.items else &.{})
            else
                &.{};

            const index: usize = std.fmt.parseInt(usize, seg, 10) catch
                try self.selectorFrameIndex(current_id, seg);
            if (index >= arr.len) return error.FrameNotFound;

            node = arr[index];
            const next_id = frameIdOf(node) orelse return error.FrameNotFound;
            self.allocator.free(current_id);
            current_id = try self.allocator.dupe(u8, next_id);
        }
        return current_id;
    }

    /// Evaluate `expression` inside a nested frame (see resolveFramePath for the
    /// `frame_path` grammar). Runs in an isolated world of the target frame.
    pub fn evalInFrame(self: *Connection, frame_path: []const u8, expression: []const u8) !EvalResult {
        const frame_id = try self.resolveFramePath(frame_path);
        defer self.allocator.free(frame_id);
        const ctx = try self.createIsolatedWorld(frame_id);
        return self.evalInContext(ctx, expression);
    }

    /// Click the element matching `selector` in the top frame. Scrolls it into
    /// view and dispatches a full pointer/mouse event sequence plus .click().
    pub fn click(self: *Connection, selector: []const u8) !void {
        const expr = try clickerExpr(self.allocator, selector);
        defer self.allocator.free(expr);
        const r = try self.eval(expr);
        if (r.value == .bool and r.value.bool) return;
        return error.ElementNotFound;
    }

    /// Click the element matching `selector` inside a nested frame.
    pub fn clickInFrame(self: *Connection, frame_path: []const u8, selector: []const u8) !void {
        const expr = try clickerExpr(self.allocator, selector);
        defer self.allocator.free(expr);
        const frame_id = try self.resolveFramePath(frame_path);
        defer self.allocator.free(frame_id);
        const ctx = try self.createIsolatedWorld(frame_id);
        const r = try self.evalInContext(ctx, expr);
        if (r.value == .bool and r.value.bool) return;
        return error.ElementNotFound;
    }

    /// List all (nested) frames as an array of {path, url, name}, where `path`
    /// is the index path usable with evalInFrame (e.g. "0", "0/1").
    pub fn frameList(self: *Connection) !json.Value {
        var tree = try self.send("Page.getFrameTree", null);
        defer tree.deinit();
        var arr = json.Array.init(self.allocator);
        if (tree.result == .object) {
            if (tree.result.object.get("frameTree")) |root| {
                try self.appendChildFrames(&arr, root, "");
            }
        }
        return .{ .array = arr };
    }

    fn appendChildFrames(self: *Connection, arr: *json.Array, node: json.Value, prefix: []const u8) !void {
        if (node != .object) return;
        const parent_id = frameIdOf(node);
        const children = node.object.get("childFrames") orelse return;
        if (children != .array) return;
        for (children.array.items, 0..) |child, i| {
            const path = if (prefix.len == 0)
                try std.fmt.allocPrint(self.allocator, "{d}", .{i})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ prefix, i });
            const frame = if (child == .object) child.object.get("frame") else null;

            // Selector hint: evaluated in the PARENT frame's context.
            var selector = try self.allocator.dupe(u8, "");
            if (parent_id) |pid| {
                if (self.createIsolatedWorld(pid)) |ctx| {
                    const sexpr = try std.fmt.allocPrint(self.allocator, "(function(){{var e=document.querySelectorAll('iframe,frame')[{d}];return e?(e.id?('#'+e.id):(e.name?('[name=\"'+e.name+'\"]'):'')):'';}})()", .{i});
                    defer self.allocator.free(sexpr);
                    if (self.evalInContext(ctx, sexpr)) |sr| {
                        if (sr.value == .string) {
                            self.allocator.free(selector);
                            selector = try self.allocator.dupe(u8, sr.value.string);
                        }
                    } else |_| {}
                } else |_| {}
            }

            // Title: evaluated in the CHILD frame's context.
            var title = try self.allocator.dupe(u8, "");
            if (frameIdOf(child)) |cid| {
                if (self.createIsolatedWorld(cid)) |ctx| {
                    if (self.evalInContext(ctx, "document.title")) |tr| {
                        if (tr.value == .string) {
                            self.allocator.free(title);
                            title = try self.allocator.dupe(u8, tr.value.string);
                        }
                    } else |_| {}
                } else |_| {}
            }

            var obj: json.ObjectMap = .empty;
            try obj.put(self.allocator, "path", .{ .string = path });
            try obj.put(self.allocator, "parent", .{ .string = try self.allocator.dupe(u8, prefix) });
            try obj.put(self.allocator, "url", .{ .string = try self.allocator.dupe(u8, frameField(frame, "url")) });
            try obj.put(self.allocator, "name", .{ .string = try self.allocator.dupe(u8, frameField(frame, "name")) });
            try obj.put(self.allocator, "selector", .{ .string = selector });
            try obj.put(self.allocator, "title", .{ .string = title });
            try arr.append(.{ .object = obj });
            try self.appendChildFrames(arr, child, path);
        }
    }

    /// Navigate the connected target to a URL.
    pub fn navigate(self: *Connection, url: []const u8) !void {
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(self.allocator);
        try params_obj.put(self.allocator, "url", .{ .string = url });

        var cdp_result = try self.send("Page.navigate", .{ .object = params_obj });
        defer cdp_result.deinit();
    }

    /// Send Browser.close to gracefully shut down the browser.
    /// Must be connected to the browser-level WebSocket (from /json/version),
    /// not a page-level WebSocket.
    pub fn closeBrowser(self: *Connection) !void {
        var cdp_result = try self.send("Browser.close", null);
        defer cdp_result.deinit();
    }

    /// Get the current URL of the connected target.
    pub fn getUrl(self: *Connection) ![]u8 {
        var cdp_result = try self.send("Runtime.evaluate", blk: {
            var params_obj: json.ObjectMap = .empty;
            try params_obj.put(self.allocator, "expression", .{ .string = "window.location.href" });
            try params_obj.put(self.allocator, "returnByValue", .{ .bool = true });
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

    /// Take a screenshot. Returns base64-encoded PNG data.
    pub fn takeScreenshot(self: *Connection) ![]const u8 {
        // Get full page dimensions via layout metrics
        var metrics_result = try self.send("Page.getLayoutMetrics", null);
        defer metrics_result.deinit();

        var width: f64 = 1280;
        var height: f64 = 800;
        if (metrics_result.result == .object) {
            if (metrics_result.result.object.get("contentSize")) |cs| {
                if (cs == .object) {
                    if (cs.object.get("width")) |w| {
                        width = switch (w) {
                            .integer => |i| @floatFromInt(i),
                            .float => |f| f,
                            else => 1280,
                        };
                    }
                    if (cs.object.get("height")) |h| {
                        height = switch (h) {
                            .integer => |i| @floatFromInt(i),
                            .float => |f| f,
                            else => 800,
                        };
                    }
                }
            }
        }

        return self.captureClip(0, 0, width, height);
    }

    /// Capture a PNG (base64) of a rectangular region of the page.
    fn captureClip(self: *Connection, x: f64, y: f64, w: f64, h: f64) ![]const u8 {
        var clip: json.ObjectMap = .empty;
        defer clip.deinit(self.allocator);
        try clip.put(self.allocator, "x", .{ .float = x });
        try clip.put(self.allocator, "y", .{ .float = y });
        try clip.put(self.allocator, "width", .{ .float = w });
        try clip.put(self.allocator, "height", .{ .float = h });
        try clip.put(self.allocator, "scale", .{ .integer = 1 });

        var params: json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "clip", .{ .object = clip });
        try params.put(self.allocator, "captureBeyondViewport", .{ .bool = true });

        var cdp_result = try self.send("Page.captureScreenshot", .{ .object = params });
        defer cdp_result.deinit();
        if (cdp_result.result == .object) {
            if (cdp_result.result.object.get("data")) |val| {
                if (val == .string) return try self.allocator.dupe(u8, val.string);
            }
        }
        return error.InvalidResponse;
    }

    /// Capture a PNG (base64) of a nested frame's rendered region, by clipping
    /// to the frame's rectangle (accumulated across the nesting path).
    pub fn screenshotFrame(self: *Connection, frame_path: []const u8) ![]const u8 {
        const rect = try self.resolveFrameRect(frame_path);
        return self.captureClip(rect.x, rect.y, rect.w, rect.h);
    }

    fn resolveFrameRect(self: *Connection, frame_path: []const u8) !Rect {
        var tree = try self.send("Page.getFrameTree", null);
        defer tree.deinit();
        if (tree.result != .object) return error.FrameNotFound;
        var node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;
        var current_id = try self.allocator.dupe(u8, frameIdOf(node) orelse return error.FrameNotFound);
        defer self.allocator.free(current_id);

        var acc_x: f64 = 0;
        var acc_y: f64 = 0;
        var w: f64 = 0;
        var h: f64 = 0;
        var it = mem.tokenizeAny(u8, frame_path, ",/");
        while (it.next()) |seg| {
            const children = node.object.get("childFrames");
            const arr: []const json.Value = if (children) |c|
                (if (c == .array) c.array.items else &.{})
            else
                &.{};

            var index: usize = undefined;
            var elem_expr: []u8 = undefined;
            if (std.fmt.parseInt(usize, seg, 10)) |i| {
                index = i;
                elem_expr = try std.fmt.allocPrint(self.allocator, "document.querySelectorAll('iframe,frame')[{d}]", .{i});
            } else |_| {
                index = try self.selectorFrameIndex(current_id, seg);
                const sel_json = try json.Stringify.valueAlloc(self.allocator, json.Value{ .string = seg }, .{});
                defer self.allocator.free(sel_json);
                elem_expr = try std.fmt.allocPrint(self.allocator, "document.querySelector({s})", .{sel_json});
            }
            defer self.allocator.free(elem_expr);
            if (index >= arr.len) return error.FrameNotFound;

            const ctx = try self.createIsolatedWorld(current_id);
            const rect_expr = try std.fmt.allocPrint(self.allocator, "(function(){{var e={s};var r=e.getBoundingClientRect();return [r.left,r.top,r.width,r.height];}})()", .{elem_expr});
            defer self.allocator.free(rect_expr);
            const rr = try self.evalInContext(ctx, rect_expr);
            if (rr.value != .array or rr.value.array.items.len < 4) return error.FrameNotFound;
            const items = rr.value.array.items;
            acc_x += numOf(items[0], 0);
            acc_y += numOf(items[1], 0);
            w = numOf(items[2], 0);
            h = numOf(items[3], 0);

            node = arr[index];
            const next_id = frameIdOf(node) orelse return error.FrameNotFound;
            self.allocator.free(current_id);
            current_id = try self.allocator.dupe(u8, next_id);
        }
        if (w == 0 or h == 0) return error.FrameNotFound;
        return .{ .x = acc_x, .y = acc_y, .w = w, .h = h };
    }
};

const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// Coerce a JSON number value to f64, or `default` if not numeric.
fn numOf(v: json.Value, default: f64) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => default,
    };
}

// ---------------------------------------------------------------------------
// HTTP-based target management (no WebSocket needed)
// ---------------------------------------------------------------------------

/// Create a new tab/target via PUT /json/new?{url}.
/// Returns the new target info. Caller owns the Target; free with freeTargets() on a one-element slice
/// or manually free each string.
pub fn createTarget(allocator: mem.Allocator, io: std.Io, port: u16, url: ?[]const u8) !Target {
    var url_buf: [2048]u8 = undefined;
    const request_url = if (url) |u|
        try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/new?{s}", .{ port, u })
    else
        try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/new", .{port});

    const body = try httpPut(allocator, io, request_url);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;

    const id = obj.get("id") orelse return error.InvalidResponse;
    if (id != .string) return error.InvalidResponse;
    const title_val = obj.get("title") orelse return error.InvalidResponse;
    if (title_val != .string) return error.InvalidResponse;
    const url_val = obj.get("url") orelse return error.InvalidResponse;
    if (url_val != .string) return error.InvalidResponse;
    const type_val = obj.get("type") orelse return error.InvalidResponse;
    if (type_val != .string) return error.InvalidResponse;

    const ws_url = if (obj.get("webSocketDebuggerUrl")) |v| blk: {
        if (v == .string) break :blk try allocator.dupe(u8, v.string);
        break :blk null;
    } else null;
    errdefer if (ws_url) |w| allocator.free(w);

    return .{
        .id = try allocator.dupe(u8, id.string),
        .title = try allocator.dupe(u8, title_val.string),
        .url = try allocator.dupe(u8, url_val.string),
        .@"type" = try allocator.dupe(u8, type_val.string),
        .webSocketDebuggerUrl = ws_url,
    };
}

/// Close a target/tab via GET /json/close/{targetId}.
pub fn closeTarget(allocator: mem.Allocator, io: std.Io, port: u16, target_id: []const u8) !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/close/{s}", .{ port, target_id });

    const body = try httpGet(allocator, io, url);
    defer allocator.free(body);
    // Chrome returns "Target is closing" on success
}

/// Activate (focus) a target/tab via GET /json/activate/{targetId}.
pub fn activateTarget(allocator: mem.Allocator, io: std.Io, port: u16, target_id: []const u8) !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/activate/{s}", .{ port, target_id });

    const body = try httpGet(allocator, io, url);
    defer allocator.free(body);
    // Chrome returns "Target activated" on success
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build a CDP JSON message string.
fn buildCdpMessage(allocator: mem.Allocator, id: u64, method: []const u8, params: ?json.Value) ![]u8 {
    // Build as json.Value manually for correct serialization
    var msg_obj: json.ObjectMap = .empty;
    defer msg_obj.deinit(allocator);
    try msg_obj.put(allocator, "id", .{ .integer = @intCast(id) });
    try msg_obj.put(allocator, "method", .{ .string = method });
    if (params) |p| {
        try msg_obj.put(allocator, "params", p);
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
            var new_obj: json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                try new_obj.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = new_obj };
        },
    };
}

/// HTTP GET a URL and return the body as an allocated string.
fn httpGet(allocator: mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
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

/// HTTP PUT a URL and return the body as an allocated string.
/// Chrome requires PUT for /json/new (GET returns 404 on modern versions).
fn httpPut(allocator: mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const result = try client.fetch(.{
        .method = .PUT,
        .payload = "",
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
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var conn = Connection.init(allocator, threaded.io());
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

    var params: json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "expression", .{ .string = "1+1" });

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
