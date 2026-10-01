///! push — inject text/data from filesystem into browser.
///!
///! The complement of grab: pushes content INTO the browser.
///! Two target modes (auto-detected):
///!   - Variable mode: target starts with "window." → assigns JS variable
///!   - Selector mode: anything else → CSS selector, sets .value + dispatches input event
///!
///! For content > 500KB, chunks are pushed individually then concatenated in-browser.
const std = @import("std");
const mem = std.mem;
const json = std.json;
const hibrow = @import("root.zig");
const gateway = @import("gateway.zig");

const CHUNK_SIZE = 500_000; // Stay under gateway line limit

pub const PushError = error{
    EvalFailed,
    TargetNotFound,
};

/// Helper: connect, eval, disconnect. Each call is a fresh connection.
fn evalOnce(allocator: mem.Allocator, io: std.Io, profile: []const u8, expression: []const u8) !gateway.ParsedResponse {
    var client = try hibrow.Client.connect(allocator, io);
    defer client.disconnect();
    return client.eval(profile, expression);
}

/// Push content into the browser at the given target.
/// Target is either a "window.*" variable name or a CSS selector.
pub fn push(allocator: mem.Allocator, io: std.Io, profile: []const u8, target: []const u8, content: []const u8) !void {
    const is_variable = mem.startsWith(u8, target, "window.");

    if (content.len <= CHUNK_SIZE) {
        // Single eval — encode content as JSON string and assign
        const content_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = content }, .{});
        defer allocator.free(content_json);

        const js = if (is_variable)
            try buildVariableJs(allocator, target, content_json)
        else
            try buildSelectorJs(allocator, target, content_json);
        defer allocator.free(js);

        var resp = try evalOnce(allocator, io, profile, js);
        defer resp.deinit();
        if (resp.is_error) return PushError.EvalFailed;
    } else {
        // Chunked: push pieces into a temp array, then concatenate
        const num_chunks = (content.len + CHUNK_SIZE - 1) / CHUNK_SIZE;

        // Initialize the buffer array
        {
            var resp = try evalOnce(allocator, io, profile, "window.__hibrowPushBuf = []; 'ok'");
            defer resp.deinit();
            if (resp.is_error) return PushError.EvalFailed;
        }

        // Push each chunk
        for (0..num_chunks) |i| {
            const start = i * CHUNK_SIZE;
            const end = @min(start + CHUNK_SIZE, content.len);
            const chunk = content[start..end];

            const chunk_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = chunk }, .{});
            defer allocator.free(chunk_json);

            const chunk_js = try std.fmt.allocPrint(allocator, "window.__hibrowPushBuf.push({s}); 'ok'", .{chunk_json});
            defer allocator.free(chunk_js);

            var resp = try evalOnce(allocator, io, profile, chunk_js);
            defer resp.deinit();
            if (resp.is_error) return PushError.EvalFailed;
        }

        // Concatenate and assign to target
        const concat_expr = "window.__hibrowPushBuf.join('')";
        const final_js = if (is_variable)
            try buildVariableJs(allocator, target, concat_expr)
        else
            try buildSelectorJs(allocator, target, concat_expr);
        defer allocator.free(final_js);

        var resp = try evalOnce(allocator, io, profile, final_js);
        defer resp.deinit();
        if (resp.is_error) return PushError.EvalFailed;

        // Clean up temp
        var cleanup = try evalOnce(allocator, io, profile, "delete window.__hibrowPushBuf; 'ok'");
        defer cleanup.deinit();
    }
}

/// Build JS to assign a value to a window variable.
/// `value_expr` is either a JSON string literal or a JS expression.
fn buildVariableJs(allocator: mem.Allocator, target: []const u8, value_expr: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} = {s}; 'ok'", .{ target, value_expr });
}

/// Build JS to set a CSS-selected element's value and dispatch input event.
/// `value_expr` is either a JSON string literal or a JS expression.
fn buildSelectorJs(allocator: mem.Allocator, target: []const u8, value_expr: []const u8) ![]u8 {
    const target_json = try json.Stringify.valueAlloc(allocator, json.Value{ .string = target }, .{});
    defer allocator.free(target_json);

    return std.fmt.allocPrint(allocator,
        \\(function() {{
        \\  var el = document.querySelector({0s});
        \\  if (!el) return 'error: element not found';
        \\  el.value = {1s};
        \\  el.dispatchEvent(new Event('input', {{bubbles: true}}));
        \\  el.dispatchEvent(new Event('change', {{bubbles: true}}));
        \\  return 'ok';
        \\}})()
    , .{ target_json, value_expr });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildVariableJs" {
    const allocator = std.testing.allocator;
    const js = try buildVariableJs(allocator, "window.__test", "\"hello\"");
    defer allocator.free(js);
    try std.testing.expect(mem.indexOf(u8, js, "window.__test") != null);
    try std.testing.expect(mem.indexOf(u8, js, "\"hello\"") != null);
}

test "buildSelectorJs" {
    const allocator = std.testing.allocator;
    const js = try buildSelectorJs(allocator, "#myInput", "\"world\"");
    defer allocator.free(js);
    try std.testing.expect(mem.indexOf(u8, js, "querySelector") != null);
    try std.testing.expect(mem.indexOf(u8, js, "\"world\"") != null);
    try std.testing.expect(mem.indexOf(u8, js, "dispatchEvent") != null);
}

test "is_variable detection" {
    try std.testing.expect(mem.startsWith(u8, "window.__foo", "window."));
    try std.testing.expect(!mem.startsWith(u8, "#myInput", "window."));
    try std.testing.expect(!mem.startsWith(u8, "textarea.prompt", "window."));
}
