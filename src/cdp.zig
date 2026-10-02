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

/// Build a JS expression that resolves `selector` (which may pierce OPEN shadow
/// roots with `>>>`), scrolls it into view, and returns its viewport rect as
/// [left, top, width, height], or null if not found.
fn deepRectExpr(allocator: mem.Allocator, selector: []const u8) ![]u8 {
    const sel_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = selector }, .{});
    defer allocator.free(sel_json);
    const prefix = "(function(){var sel=";
    const suffix = ";var parts=sel.split('>>>');var root=document,el=null;for(var i=0;i<parts.length;i++){el=root.querySelector(parts[i].trim());if(!el)return null;if(i<parts.length-1){if(!el.shadowRoot)return null;root=el.shadowRoot;}}el.scrollIntoView({block:'center'});var r=el.getBoundingClientRect();return [r.left,r.top,r.width,r.height];})()";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, sel_json, suffix });
}

/// Extract a [x,y,w,h] rect from a JSON array value, or null.
fn rectFromValue(v: json.Value) ?Rect {
    if (v != .array or v.array.items.len < 4) return null;
    const it = v.array.items;
    return .{ .x = numOf(it[0], 0), .y = numOf(it[1], 0), .w = numOf(it[2], 0), .h = numOf(it[3], 0) };
}

/// Read a string field from a Page.getFrameTree `frame` object (or "" if absent).
fn frameField(frame: ?json.Value, key: []const u8) []const u8 {
    const f = frame orelse return "";
    if (f != .object) return "";
    const v = f.object.get(key) orelse return "";
    if (v != .string) return "";
    return v.string;
}

/// Free an owned list of owned strings.
fn freeStrList(allocator: mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
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
    /// Whether Page/Target auto-attach has been enabled (for OOPIF support).
    frame_support_enabled: bool = false,
    /// OOPIF (out-of-process iframe) frameId -> CDP sessionId.
    oopif_session: ?std.StringHashMap([]u8) = null,
    /// OOPIF frameId -> its parent frameId.
    oopif_parent: ?std.StringHashMap([]u8) = null,

    pub fn init(allocator: mem.Allocator, io: std.Io) Connection {
        return .{
            .allocator = allocator,
            .ws = websocket.WebSocket.init(allocator, io),
            .oopif_session = std.StringHashMap([]u8).init(allocator),
            .oopif_parent = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.oopif_session) |*m| {
            var it = m.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            m.deinit();
        }
        if (self.oopif_parent) |*m| {
            var it = m.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            m.deinit();
        }
        self.ws.deinit();
    }

    /// Connect to a target by its webSocketDebuggerUrl.
    pub fn connect(self: *Connection, ws_url: []const u8) !void {
        const parsed = try parseWsUrl(ws_url);
        try self.ws.connect(parsed.host, parsed.port, parsed.path);
    }

    /// Send a CDP command on the default (page) session and wait for the response.
    pub fn send(self: *Connection, method: []const u8, params: ?json.Value) !CdpResult {
        return self.sendSession(method, params, null);
    }

    /// Send a CDP command, optionally routed to an OOPIF session via `sessionId`.
    /// Returns a CdpResult that owns the parsed response. Caller must deinit.
    pub fn sendSession(self: *Connection, method: []const u8, params: ?json.Value, session_id: ?[]const u8) !CdpResult {
        const id = self.next_id;
        self.next_id += 1;

        // Build CDP message
        const msg_json = try buildCdpMessage(self.allocator, id, method, params, session_id);
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
            // Not our response (an event) — record OOPIF attach/detach, then discard.
            self.handleEvent(parsed.value) catch {};
            parsed.deinit();
        }
    }

    /// Record Target.attachedToTarget / detachedFromTarget events so we can
    /// route commands to out-of-process iframe (OOPIF) sessions.
    fn handleEvent(self: *Connection, msg: json.Value) !void {
        if (msg != .object) return;
        const method_v = msg.object.get("method") orelse return;
        if (method_v != .string) return;
        const params_v = msg.object.get("params") orelse return;
        if (params_v != .object) return;
        const p = params_v.object;

        if (mem.eql(u8, method_v.string, "Target.attachedToTarget")) {
            const session_v = p.get("sessionId") orelse return;
            const ti_v = p.get("targetInfo") orelse return;
            if (session_v != .string or ti_v != .object) return;
            const ti = ti_v.object;
            const type_v = ti.get("type") orelse return;
            if (type_v != .string or !mem.eql(u8, type_v.string, "iframe")) return;
            const target_v = ti.get("targetId") orelse return;
            if (target_v != .string) return;
            const parent_v = ti.get("parentFrameId");

            const fid = target_v.string;
            try self.putOopif(&self.oopif_session.?, fid, session_v.string);
            if (parent_v) |pv| {
                if (pv == .string) try self.putOopif(&self.oopif_parent.?, fid, pv.string);
            }
        } else if (mem.eql(u8, method_v.string, "Target.detachedFromTarget")) {
            const session_v = p.get("sessionId") orelse return;
            if (session_v != .string) return;
            // Remove any frameId whose session matches.
            var it = self.oopif_session.?.iterator();
            var victim: ?[]const u8 = null;
            while (it.next()) |e| {
                if (mem.eql(u8, e.value_ptr.*, session_v.string)) {
                    victim = e.key_ptr.*;
                    break;
                }
            }
            if (victim) |fid| {
                if (self.oopif_session.?.fetchRemove(fid)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }
                if (self.oopif_parent.?.fetchRemove(fid)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value);
                }
            }
        }
    }

    /// Insert/replace a frameId -> value mapping, duplicating both strings.
    fn putOopif(self: *Connection, map: *std.StringHashMap([]u8), key: []const u8, value: []const u8) !void {
        if (map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        try map.put(k, v);
    }

    /// Enable Page + Target auto-attach so cross-origin OOPIF frames (one level
    /// below the main page) are discoverable and routable. Idempotent.
    ///
    /// Note: auto-attach is enabled only on the main session, so a single level
    /// of OOPIF is fully supported. Frames nested INSIDE an OOPIF (OOPIF-within-
    /// OOPIF) are not attached and are silently omitted — chasing them by
    /// enabling auto-attach on child sessions proved able to hang the event
    /// stream, so it is deliberately not done.
    fn ensureFrameSupport(self: *Connection) !void {
        if (self.frame_support_enabled) return;
        self.frame_support_enabled = true;

        {
            var r = self.send("Page.enable", null) catch |e| return e;
            r.deinit();
        }
        try self.enableAutoAttach(null);
        // Drain any attach events now in flight.
        {
            var r = self.send("Target.getTargets", null) catch |e| return e;
            r.deinit();
        }
    }

    fn enableAutoAttach(self: *Connection, session_id: ?[]const u8) !void {
        var p: json.ObjectMap = .empty;
        defer p.deinit(self.allocator);
        try p.put(self.allocator, "autoAttach", .{ .bool = true });
        try p.put(self.allocator, "waitForDebuggerOnStart", .{ .bool = false });
        try p.put(self.allocator, "flatten", .{ .bool = true });
        var r = try self.sendSession("Target.setAutoAttach", .{ .object = p }, session_id);
        r.deinit();
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

    /// Evaluate JavaScript within a specific execution context (used for frames),
    /// optionally on an OOPIF session.
    fn evalInContext(self: *Connection, context_id: i64, expression: []const u8, session: ?[]const u8) !EvalResult {
        var params_obj: json.ObjectMap = .empty;
        defer params_obj.deinit(self.allocator);
        try params_obj.put(self.allocator, "expression", .{ .string = expression });
        try params_obj.put(self.allocator, "returnByValue", .{ .bool = true });
        try params_obj.put(self.allocator, "contextId", .{ .integer = context_id });

        var cdp_result = try self.sendSession("Runtime.evaluate", .{ .object = params_obj }, session);
        defer cdp_result.deinit();
        return self.parseEvalResult(cdp_result.result);
    }

    /// Create an isolated world for a frame and return its execution context id.
    /// Isolated worlds share the frame's DOM and session (cookies/login) but not
    /// the page's own JS globals — sufficient for DOM reads, clicks, form fills.
    fn createIsolatedWorld(self: *Connection, frame_id: []const u8, session: ?[]const u8) !i64 {
        var p: json.ObjectMap = .empty;
        defer p.deinit(self.allocator);
        try p.put(self.allocator, "frameId", .{ .string = frame_id });
        try p.put(self.allocator, "worldName", .{ .string = "hibrow" });
        try p.put(self.allocator, "grantUniveralAccess", .{ .bool = true });

        var r = try self.sendSession("Page.createIsolatedWorld", .{ .object = p }, session);
        defer r.deinit();
        if (r.result == .object) {
            if (r.result.object.get("executionContextId")) |c| {
                if (c == .integer) return c.integer;
            }
        }
        return error.FrameContextFailed;
    }

    /// Find the child-frame index of the <iframe>/<frame> matching `selector`
    /// within the frame identified by `frame_id` (on the given session).
    fn selectorFrameIndex(self: *Connection, frame_id: []const u8, session: ?[]const u8, selector: []const u8) !usize {
        const ctx = try self.createIsolatedWorld(frame_id, session);
        const sel_json = try json.Stringify.valueAlloc(self.allocator, json.Value{ .string = selector }, .{});
        defer self.allocator.free(sel_json);
        const expr = try std.fmt.allocPrint(self.allocator, "(function(){{var t=document.querySelector({s});var l=[].slice.call(document.querySelectorAll('iframe,frame'));return l.indexOf(t);}})()", .{sel_json});
        defer self.allocator.free(expr);

        const res = try self.evalInContext(ctx, expr, session);
        if (res.exception) |e| {
            self.allocator.free(e);
            return error.FrameNotFound;
        }
        if (res.value == .integer and res.value.integer >= 0) return @intCast(res.value.integer);
        return error.FrameNotFound;
    }

    /// A resolved frame: its CDP frameId plus the OOPIF session that owns it
    /// (null = the main page session). Both strings are owned by the caller.
    const FrameTarget = struct {
        session: ?[]u8,
        frame_id: []u8,

        fn deinit(t: *FrameTarget, allocator: mem.Allocator) void {
            if (t.session) |s| allocator.free(s);
            allocator.free(t.frame_id);
        }
    };

    /// Resolve a frame path ("1,0,0" / "#outer/#inner") to a FrameTarget, walking
    /// a unified tree where each frame's children are its same-process children
    /// (from Page.getFrameTree) followed by its OOPIF children (from auto-attach).
    fn resolveFrameTarget(self: *Connection, frame_path: []const u8) !FrameTarget {
        try self.ensureFrameSupport();

        var tree = try self.sendSession("Page.getFrameTree", null, null);
        var owns_tree = true;
        defer if (owns_tree) tree.deinit();

        if (tree.result != .object) return error.FrameNotFound;
        var node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;

        var current_session: ?[]u8 = null;
        errdefer if (current_session) |s| self.allocator.free(s);
        var current_id = try self.allocator.dupe(u8, frameIdOf(node) orelse return error.FrameNotFound);
        errdefer self.allocator.free(current_id);

        var it = mem.tokenizeAny(u8, frame_path, ",/");
        while (it.next()) |seg| {
            const children = node.object.get("childFrames");
            const same: []const json.Value = if (children) |c|
                (if (c == .array) c.array.items else &.{})
            else
                &.{};

            var oopif = try self.oopifChildrenOf(current_id);
            defer freeStrList(self.allocator, &oopif);

            const total = same.len + oopif.items.len;
            const index: usize = std.fmt.parseInt(usize, seg, 10) catch
                try self.selectorFrameIndex(current_id, current_session, seg);
            if (index >= total) return error.FrameNotFound;

            if (index < same.len) {
                node = same[index];
                const next_id = frameIdOf(node) orelse return error.FrameNotFound;
                self.allocator.free(current_id);
                current_id = try self.allocator.dupe(u8, next_id);
            } else {
                const oopif_fid = oopif.items[index - same.len];
                const sess = self.oopif_session.?.get(oopif_fid) orelse return error.FrameNotFound;
                const new_session = try self.allocator.dupe(u8, sess);
                if (current_session) |s| self.allocator.free(s);
                current_session = new_session;
                self.allocator.free(current_id);
                current_id = try self.allocator.dupe(u8, oopif_fid);

                const sub = try self.sendSession("Page.getFrameTree", null, current_session);
                if (owns_tree) tree.deinit();
                tree = sub;
                owns_tree = true;
                if (tree.result != .object) return error.FrameNotFound;
                node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;
            }
        }
        return .{ .session = current_session, .frame_id = current_id };
    }

    /// OOPIF frameIds whose parent is `frame_id`, sorted for stable ordering.
    /// Returns OWNED copies (safe across later map mutation); caller frees each
    /// item and deinits the list via `freeStrList`.
    fn oopifChildrenOf(self: *Connection, frame_id: []const u8) !std.ArrayList([]const u8) {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer freeStrList(self.allocator, &list);
        var mit = self.oopif_parent.?.iterator();
        while (mit.next()) |e| {
            if (mem.eql(u8, e.value_ptr.*, frame_id)) {
                try list.append(self.allocator, try self.allocator.dupe(u8, e.key_ptr.*));
            }
        }
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return list;
    }

    /// Evaluate `expression` inside a nested frame. Runs in an isolated world of
    /// the target frame (routed to its OOPIF session if cross-process).
    pub fn evalInFrame(self: *Connection, frame_path: []const u8, expression: []const u8) !EvalResult {
        var target = try self.resolveFrameTarget(frame_path);
        defer target.deinit(self.allocator);
        const ctx = try self.createIsolatedWorld(target.frame_id, target.session);
        return self.evalInContext(ctx, expression, target.session);
    }

    /// Dispatch a trusted (isTrusted) left click at top-level viewport (x,y) via
    /// the Input domain. The browser routes it to whatever frame renders there,
    /// so this works across same-process and OOPIF frames.
    fn dispatchClickAt(self: *Connection, x: f64, y: f64) !void {
        const types = [_]struct { t: []const u8, buttons: i64 }{
            .{ .t = "mouseMoved", .buttons = 0 },
            .{ .t = "mousePressed", .buttons = 1 },
            .{ .t = "mouseReleased", .buttons = 0 },
        };
        for (types) |ev| {
            var p: json.ObjectMap = .empty;
            defer p.deinit(self.allocator);
            try p.put(self.allocator, "type", .{ .string = ev.t });
            try p.put(self.allocator, "x", .{ .float = x });
            try p.put(self.allocator, "y", .{ .float = y });
            try p.put(self.allocator, "button", .{ .string = "left" });
            try p.put(self.allocator, "buttons", .{ .integer = ev.buttons });
            try p.put(self.allocator, "clickCount", .{ .integer = 1 });
            var r = try self.send("Input.dispatchMouseEvent", .{ .object = p });
            r.deinit();
        }
    }

    /// Click the element matching `selector` (may pierce open shadow roots with
    /// `>>>`) in the top frame — a trusted input-level click.
    pub fn click(self: *Connection, selector: []const u8) !void {
        const expr = try deepRectExpr(self.allocator, selector);
        defer self.allocator.free(expr);
        const r = try self.eval(expr);
        const rect = rectFromValue(r.value) orelse return error.ElementNotFound;
        try self.dispatchClickAt(rect.x + rect.w / 2, rect.y + rect.h / 2);
    }

    /// Click the element matching `selector` inside a nested frame — a trusted
    /// input-level click, dispatched at the element's top-level coordinates
    /// (frame offset + element rect), which also works for OOPIF frames.
    pub fn clickInFrame(self: *Connection, frame_path: []const u8, selector: []const u8) !void {
        const foff = try self.resolveFrameRect(frame_path);
        var target = try self.resolveFrameTarget(frame_path);
        defer target.deinit(self.allocator);
        const ctx = try self.createIsolatedWorld(target.frame_id, target.session);
        const expr = try deepRectExpr(self.allocator, selector);
        defer self.allocator.free(expr);
        const r = try self.evalInContext(ctx, expr, target.session);
        const rect = rectFromValue(r.value) orelse return error.ElementNotFound;
        try self.dispatchClickAt(foff.x + rect.x + rect.w / 2, foff.y + rect.y + rect.h / 2);
    }

    /// List all (nested) frames, including cross-origin OOPIF frames, as an array
    /// of {path, parent, url, name, selector, title}. `path` is usable directly
    /// with `--frame` (e.g. "0", "0/1").
    pub fn frameList(self: *Connection) !json.Value {
        try self.ensureFrameSupport();
        var tree = try self.sendSession("Page.getFrameTree", null, null);
        defer tree.deinit();
        var arr = json.Array.init(self.allocator);
        if (tree.result == .object) {
            if (tree.result.object.get("frameTree")) |root| {
                if (frameIdOf(root)) |root_id| {
                    try self.appendFramesUnified(&arr, root, root_id, null, "");
                }
            }
        }
        return .{ .array = arr };
    }

    /// Append the children of frame (frame_id / session, whose subtree node is
    /// `node`) to `arr`, same-process children first then OOPIF children, recursing.
    fn appendFramesUnified(self: *Connection, arr: *json.Array, node: json.Value, frame_id: []const u8, session: ?[]const u8, prefix: []const u8) !void {
        if (node != .object) return;
        const children = node.object.get("childFrames");
        const same: []const json.Value = if (children) |c|
            (if (c == .array) c.array.items else &.{})
        else
            &.{};

        // Same-process children.
        for (same, 0..) |child, i| {
            const frame = if (child == .object) child.object.get("frame") else null;
            try self.appendOneFrame(arr, prefix, i, i, frame_id, session, frameIdOf(child), session, frameField(frame, "url"), frameField(frame, "name"));
            const path = try self.framePath(prefix, i);
            defer self.allocator.free(path);
            if (frameIdOf(child)) |cid| {
                try self.appendFramesUnified(arr, child, cid, session, path);
            }
        }

        // OOPIF children.
        var oopif = try self.oopifChildrenOf(frame_id);
        defer freeStrList(self.allocator, &oopif);
        for (oopif.items, 0..) |oopif_fid, j| {
            const index = same.len + j;
            const child_session = self.oopif_session.?.get(oopif_fid) orelse continue;
            var sub = self.sendSession("Page.getFrameTree", null, child_session) catch continue;
            defer sub.deinit();
            const sub_root = if (sub.result == .object) sub.result.object.get("frameTree") else null;
            const frame = if (sub_root) |sr| (if (sr == .object) sr.object.get("frame") else null) else null;
            try self.appendOneFrame(arr, prefix, index, index, frame_id, session, oopif_fid, child_session, frameField(frame, "url"), frameField(frame, "name"));
            const path = try self.framePath(prefix, index);
            defer self.allocator.free(path);
            if (sub_root) |sr| try self.appendFramesUnified(arr, sr, oopif_fid, child_session, path);
        }
    }

    fn framePath(self: *Connection, prefix: []const u8, index: usize) ![]u8 {
        return if (prefix.len == 0)
            std.fmt.allocPrint(self.allocator, "{d}", .{index})
        else
            std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ prefix, index });
    }

    /// Append a single frame entry (with selector hint from the parent context
    /// and title from the child context).
    fn appendOneFrame(
        self: *Connection,
        arr: *json.Array,
        prefix: []const u8,
        path_index: usize,
        dom_index: usize,
        parent_frame_id: []const u8,
        parent_session: ?[]const u8,
        child_frame_id: ?[]const u8,
        child_session: ?[]const u8,
        url: []const u8,
        name: []const u8,
    ) !void {
        const path = try self.framePath(prefix, path_index);

        var selector = try self.allocator.dupe(u8, "");
        if (self.createIsolatedWorld(parent_frame_id, parent_session)) |ctx| {
            const sexpr = try std.fmt.allocPrint(self.allocator, "(function(){{var e=document.querySelectorAll('iframe,frame')[{d}];return e?(e.id?('#'+e.id):(e.name?('[name=\"'+e.name+'\"]'):'')):'';}})()", .{dom_index});
            defer self.allocator.free(sexpr);
            if (self.evalInContext(ctx, sexpr, parent_session)) |sr| {
                if (sr.value == .string) {
                    self.allocator.free(selector);
                    selector = try self.allocator.dupe(u8, sr.value.string);
                }
            } else |_| {}
        } else |_| {}

        var title = try self.allocator.dupe(u8, "");
        if (child_frame_id) |cid| {
            if (self.createIsolatedWorld(cid, child_session)) |ctx| {
                if (self.evalInContext(ctx, "document.title", child_session)) |tr| {
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
        try obj.put(self.allocator, "url", .{ .string = try self.allocator.dupe(u8, url) });
        try obj.put(self.allocator, "name", .{ .string = try self.allocator.dupe(u8, name) });
        try obj.put(self.allocator, "selector", .{ .string = selector });
        try obj.put(self.allocator, "title", .{ .string = title });
        try arr.append(.{ .object = obj });
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

    /// Capture a PNG (base64) of a nested frame's rendered region by clipping the
    /// top page screenshot to the frame's rectangle (accumulated across the path).
    /// Works for same-process and cross-origin OOPIF frames (which are composited
    /// into the top page, so a top-level clip captures their pixels).
    pub fn screenshotFrame(self: *Connection, frame_path: []const u8) ![]const u8 {
        const rect = try self.resolveFrameRect(frame_path);
        return self.captureClip(rect.x, rect.y, rect.w, rect.h);
    }

    /// Resolve a frame path to its rectangle in the TOP viewport, walking the
    /// unified tree (same-process + OOPIF) and accumulating each hop's owner
    /// iframe rect (evaluated in the parent frame's — possibly OOPIF — context).
    fn resolveFrameRect(self: *Connection, frame_path: []const u8) !Rect {
        try self.ensureFrameSupport();
        var tree = try self.sendSession("Page.getFrameTree", null, null);
        var owns_tree = true;
        defer if (owns_tree) tree.deinit();
        if (tree.result != .object) return error.FrameNotFound;
        var node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;

        var current_session: ?[]u8 = null;
        defer if (current_session) |s| self.allocator.free(s);
        var current_id = try self.allocator.dupe(u8, frameIdOf(node) orelse return error.FrameNotFound);
        defer self.allocator.free(current_id);

        var acc_x: f64 = 0;
        var acc_y: f64 = 0;
        var w: f64 = 0;
        var h: f64 = 0;
        var it = mem.tokenizeAny(u8, frame_path, ",/");
        while (it.next()) |seg| {
            const children = node.object.get("childFrames");
            const same: []const json.Value = if (children) |c|
                (if (c == .array) c.array.items else &.{})
            else
                &.{};
            var oopif = try self.oopifChildrenOf(current_id);
            defer freeStrList(self.allocator, &oopif);
            const total = same.len + oopif.items.len;

            const index: usize = std.fmt.parseInt(usize, seg, 10) catch
                try self.selectorFrameIndex(current_id, current_session, seg);
            if (index >= total) return error.FrameNotFound;

            // Rect of the owner iframe element at `index` in the current frame.
            const ctx = try self.createIsolatedWorld(current_id, current_session);
            const rect_expr = try std.fmt.allocPrint(self.allocator, "(function(){{var e=document.querySelectorAll('iframe,frame')[{d}];if(!e)return[0,0,0,0];var r=e.getBoundingClientRect();return [r.left,r.top,r.width,r.height];}})()", .{index});
            defer self.allocator.free(rect_expr);
            const rr = try self.evalInContext(ctx, rect_expr, current_session);
            if (rr.value == .array and rr.value.array.items.len >= 4) {
                const items = rr.value.array.items;
                acc_x += numOf(items[0], 0);
                acc_y += numOf(items[1], 0);
                w = numOf(items[2], 0);
                h = numOf(items[3], 0);
            }

            if (index < same.len) {
                node = same[index];
                const next_id = frameIdOf(node) orelse return error.FrameNotFound;
                self.allocator.free(current_id);
                current_id = try self.allocator.dupe(u8, next_id);
            } else {
                const oopif_fid = oopif.items[index - same.len];
                const sess = self.oopif_session.?.get(oopif_fid) orelse return error.FrameNotFound;
                const new_session = try self.allocator.dupe(u8, sess);
                if (current_session) |s| self.allocator.free(s);
                current_session = new_session;
                self.allocator.free(current_id);
                current_id = try self.allocator.dupe(u8, oopif_fid);

                const sub = try self.sendSession("Page.getFrameTree", null, current_session);
                if (owns_tree) tree.deinit();
                tree = sub;
                owns_tree = true;
                if (tree.result != .object) return error.FrameNotFound;
                node = tree.result.object.get("frameTree") orelse return error.FrameNotFound;
            }
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
fn buildCdpMessage(allocator: mem.Allocator, id: u64, method: []const u8, params: ?json.Value, session_id: ?[]const u8) ![]u8 {
    // Build as json.Value manually for correct serialization
    var msg_obj: json.ObjectMap = .empty;
    defer msg_obj.deinit(allocator);
    try msg_obj.put(allocator, "id", .{ .integer = @intCast(id) });
    try msg_obj.put(allocator, "method", .{ .string = method });
    if (params) |p| {
        try msg_obj.put(allocator, "params", p);
    }
    if (session_id) |s| {
        try msg_obj.put(allocator, "sessionId", .{ .string = s });
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
    const msg = try buildCdpMessage(allocator, 1, "Runtime.evaluate", null, null);
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

    const msg = try buildCdpMessage(allocator, 5, "Runtime.evaluate", .{ .object = params }, null);
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
