///! grab — extract binary data from browser to filesystem.
///!
///! Orchestrates multiple eval calls to:
///! 1. Inject JS that fetches a URL or evaluates an expression
///! 2. Chunk the base64 result to stay under gateway line limits
///! 3. Pull chunks one by one
///! 4. Decode and write to file
///!
///! Two modes (auto-detected):
///! - URL mode: arg starts with http:// or https:// → fetch in-browser
///! - JS mode: arg is a JS expression that returns a base64/data-URI string
const std = @import("std");
const mem = std.mem;
const json = std.json;
const hibrow = @import("root.zig");
const gateway = @import("gateway.zig");

const CHUNK_SIZE = 950_000; // Stay under 1MB gateway line limit

pub const GrabError = error{
    EvalFailed,
    Timeout,
    BrowserError,
    NoData,
    InvalidBase64,
};

pub const GrabResult = struct {
    data: []u8,

    pub fn deinit(self: *GrabResult, allocator: mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Helper: connect, eval, disconnect. Each call is a fresh connection.
fn evalOnce(allocator: mem.Allocator, profile: []const u8, expression: []const u8) !gateway.ParsedResponse {
    var client = try hibrow.Client.connect(allocator);
    defer client.disconnect();
    return client.eval(profile, expression);
}

/// Grab binary data from the browser.
/// `source` is either a URL (http/https) or a JS expression returning base64.
/// Returns decoded binary data. Caller owns the result.
pub fn grab(allocator: mem.Allocator, profile: []const u8, source: []const u8) !GrabResult {
    // Generate the injection JS based on mode
    const inject_js = try buildInjectionJs(allocator, source);
    defer allocator.free(inject_js);

    // Step 1: Inject the fetch/eval + chunking script
    {
        var resp = try evalOnce(allocator, profile, inject_js);
        defer resp.deinit();
        if (resp.is_error) return GrabError.EvalFailed;
        if (resp.result != .string) return GrabError.EvalFailed;
        if (!mem.eql(u8, resp.result.string, "started")) return GrabError.EvalFailed;
    }

    // Step 2: Poll for completion
    const poll_timeout_ms: u64 = 30_000;
    const poll_interval_ms: u64 = 500;
    var elapsed: u64 = 0;

    while (elapsed < poll_timeout_ms) {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        elapsed += poll_interval_ms;

        var resp = try evalOnce(allocator, profile, "window.__hibrowGrabStatus");
        defer resp.deinit();
        if (resp.is_error) continue;
        if (resp.result != .string) continue;

        const status = resp.result.string;
        if (mem.startsWith(u8, status, "done")) break;
        if (mem.startsWith(u8, status, "error")) return GrabError.BrowserError;
    }

    if (elapsed >= poll_timeout_ms) return GrabError.Timeout;

    // Step 3: Get chunk count
    const num_chunks: usize = blk: {
        var resp = try evalOnce(allocator, profile, "window.__hibrowGrabChunks.length");
        defer resp.deinit();
        if (resp.is_error) return GrabError.EvalFailed;
        if (resp.result == .integer) break :blk @intCast(resp.result.integer);
        return GrabError.EvalFailed;
    };

    if (num_chunks == 0) return GrabError.NoData;

    // Step 4: Pull chunks
    var b64_parts: std.ArrayList([]const u8) = .{};
    defer {
        for (b64_parts.items) |part| allocator.free(part);
        b64_parts.deinit(allocator);
    }

    for (0..num_chunks) |i| {
        const chunk_js = try std.fmt.allocPrint(allocator, "window.__hibrowGrabChunks[{d}]", .{i});
        defer allocator.free(chunk_js);

        var resp = try evalOnce(allocator, profile, chunk_js);
        defer resp.deinit();
        if (resp.is_error) return GrabError.EvalFailed;
        if (resp.result != .string) return GrabError.EvalFailed;

        try b64_parts.append(allocator, try allocator.dupe(u8, resp.result.string));
    }

    // Step 5: Concatenate and decode base64
    var total_len: usize = 0;
    for (b64_parts.items) |part| total_len += part.len;

    const b64_full = try allocator.alloc(u8, total_len);
    defer allocator.free(b64_full);
    var offset: usize = 0;
    for (b64_parts.items) |part| {
        @memcpy(b64_full[offset..][0..part.len], part);
        offset += part.len;
    }

    // Decode base64
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_full) catch
        return GrabError.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_size);
    errdefer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, b64_full) catch
        return GrabError.InvalidBase64;

    return .{ .data = decoded };
}

/// Build the injection JavaScript.
/// URL mode: fetches the URL in-browser, converts to base64, chunks.
/// JS mode: evals the expression (must return base64/data-URI), chunks.
fn buildInjectionJs(allocator: mem.Allocator, source: []const u8) ![]u8 {
    const is_url = mem.startsWith(u8, source, "http://") or mem.startsWith(u8, source, "https://");

    if (is_url) {
        // JSON-encode the URL string for safe embedding in JS
        const url_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = source }, .{});
        defer allocator.free(url_json);

        return std.fmt.allocPrint(allocator,
            \\(function() {{
            \\  window.__hibrowGrabStatus = "pending";
            \\  window.__hibrowGrabChunks = null;
            \\  var _f = window.__zone_symbol__fetch || window.fetch;
            \\  _f.call(window, {0s}).then(function(r) {{
            \\    if (!r.ok) {{ window.__hibrowGrabStatus = "error: HTTP " + r.status; return; }}
            \\    return r.blob();
            \\  }}).then(function(blob) {{
            \\    if (!blob) return;
            \\    var reader = new FileReader();
            \\    reader.onload = function() {{
            \\      var b64 = reader.result.split(",")[1] || reader.result;
            \\      var chunks = [];
            \\      for (var i = 0; i < b64.length; i += {1d}) chunks.push(b64.substring(i, i + {1d}));
            \\      window.__hibrowGrabChunks = chunks;
            \\      window.__hibrowGrabStatus = "done";
            \\    }};
            \\    reader.readAsDataURL(blob);
            \\  }}).catch(function(e) {{ window.__hibrowGrabStatus = "error: " + e.message; }});
            \\  return "started";
            \\}})()
        , .{ url_json, CHUNK_SIZE });
    } else {
        // JS mode — expression should return a base64 string or data URI
        return std.fmt.allocPrint(allocator,
            \\(function() {{
            \\  window.__hibrowGrabStatus = "pending";
            \\  window.__hibrowGrabChunks = null;
            \\  try {{
            \\    var result = ({0s});
            \\    if (typeof result === "string" && result.startsWith("http")) {{
            \\      var _f = window.__zone_symbol__fetch || window.fetch;
            \\      _f.call(window, result).then(function(r) {{
            \\        if (!r.ok) {{ window.__hibrowGrabStatus = "error: HTTP " + r.status; return; }}
            \\        return r.blob();
            \\      }}).then(function(blob) {{
            \\        if (!blob) return;
            \\        var reader = new FileReader();
            \\        reader.onload = function() {{
            \\          var b64 = reader.result.split(",")[1] || reader.result;
            \\          var chunks = [];
            \\          for (var i = 0; i < b64.length; i += {1d}) chunks.push(b64.substring(i, i + {1d}));
            \\          window.__hibrowGrabChunks = chunks;
            \\          window.__hibrowGrabStatus = "done";
            \\        }};
            \\        reader.readAsDataURL(blob);
            \\      }}).catch(function(e) {{ window.__hibrowGrabStatus = "error: " + e.message; }});
            \\    }} else if (typeof result === "string") {{
            \\      var b64 = result.indexOf(",") > -1 ? result.split(",")[1] : result;
            \\      var chunks = [];
            \\      for (var i = 0; i < b64.length; i += {1d}) chunks.push(b64.substring(i, i + {1d}));
            \\      window.__hibrowGrabChunks = chunks;
            \\      window.__hibrowGrabStatus = "done";
            \\    }} else {{
            \\      window.__hibrowGrabStatus = "error: expression did not return a string";
            \\    }}
            \\  }} catch(e) {{ window.__hibrowGrabStatus = "error: " + e.message; }}
            \\  return "started";
            \\}})()
        , .{ source, CHUNK_SIZE });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildInjectionJs URL mode" {
    const allocator = std.testing.allocator;
    const js = try buildInjectionJs(allocator, "https://example.com/img.png");
    defer allocator.free(js);
    try std.testing.expect(mem.indexOf(u8, js, "hibrowGrabStatus") != null);
    try std.testing.expect(mem.indexOf(u8, js, "fetch") != null);
    try std.testing.expect(mem.indexOf(u8, js, "\"started\"") != null);
}

test "buildInjectionJs JS mode" {
    const allocator = std.testing.allocator;
    const js = try buildInjectionJs(allocator, "document.querySelector('img').src");
    defer allocator.free(js);
    try std.testing.expect(mem.indexOf(u8, js, "hibrowGrabStatus") != null);
    try std.testing.expect(mem.indexOf(u8, js, "querySelector") != null);
    try std.testing.expect(mem.indexOf(u8, js, "\"started\"") != null);
}
