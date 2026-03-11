///! JSON-RPC 2.0 protocol types for hibrow client ↔ gateway communication.
///!
///! Wire format: line-delimited JSON over Unix domain socket.
///! Each message is a single JSON object terminated by '\n'.
const std = @import("std");
const json = std.json;
const mem = std.mem;

/// JSON-RPC 2.0 version string.
pub const jsonrpc_version = "2.0";

/// Standard JSON-RPC 2.0 error codes.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    /// Application-defined error: browser not found.
    browser_not_found = -32000,
    /// Application-defined error: browser launch failed.
    browser_launch_failed = -32001,
    /// Application-defined error: CDP connection failed.
    cdp_error = -32002,
};

/// A JSON-RPC 2.0 request.
pub const Request = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    method: []const u8,
    params: ?json.Value = null,
    id: json.Value, // string or integer

    /// Serialize this request to a JSON string (with trailing newline).
    pub fn encode(self: Request, allocator: mem.Allocator) ![]u8 {
        const json_bytes = try json.Stringify.valueAlloc(allocator, self, .{});
        defer allocator.free(json_bytes);
        // Append newline delimiter
        const result = try allocator.alloc(u8, json_bytes.len + 1);
        @memcpy(result[0..json_bytes.len], json_bytes);
        result[json_bytes.len] = '\n';
        return result;
    }
};

/// A JSON-RPC 2.0 success response.
pub const Response = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    result: json.Value = .null,
    id: json.Value,
};

/// A JSON-RPC 2.0 error detail.
pub const ErrorDetail = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

/// A JSON-RPC 2.0 error response.
pub const ErrorResponse = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    @"error": ErrorDetail,
    id: json.Value,
};

/// Construct a success response.
pub fn makeResponse(id: json.Value, result: json.Value) Response {
    return .{ .id = id, .result = result };
}

/// Construct an error response.
pub fn makeErrorResponse(id: json.Value, code: ErrorCode, message: []const u8) ErrorResponse {
    return .{
        .@"error" = .{
            .code = @intFromEnum(code),
            .message = message,
        },
        .id = id,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ErrorCode values match JSON-RPC 2.0 spec" {
    try std.testing.expectEqual(@as(i32, -32700), @intFromEnum(ErrorCode.parse_error));
    try std.testing.expectEqual(@as(i32, -32600), @intFromEnum(ErrorCode.invalid_request));
    try std.testing.expectEqual(@as(i32, -32601), @intFromEnum(ErrorCode.method_not_found));
    try std.testing.expectEqual(@as(i32, -32602), @intFromEnum(ErrorCode.invalid_params));
    try std.testing.expectEqual(@as(i32, -32603), @intFromEnum(ErrorCode.internal_error));
}

test "makeErrorResponse constructs valid error" {
    const resp = makeErrorResponse(
        .{ .integer = 1 },
        .method_not_found,
        "Method not found",
    );
    try std.testing.expectEqual(@as(i32, -32601), resp.@"error".code);
    try std.testing.expectEqualStrings("Method not found", resp.@"error".message);
}

test "makeResponse constructs valid result" {
    const resp = makeResponse(.{ .integer = 42 }, .{ .bool = true });
    try std.testing.expect(resp.result == .bool);
    try std.testing.expect(resp.result.bool == true);
}
