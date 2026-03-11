///! JSON-RPC 2.0 protocol types for hibrow client ↔ gateway communication.
///!
///! Wire format: line-delimited JSON over Unix domain socket.
///! Each message is a single JSON object terminated by '\n'.
///!
///! Two-layer decode:
///!   1. parseMessage() — bytes → json.Value (owns parsed memory via Parsed)
///!   2. extractRequest() — json.Value → Request (borrows from parsed memory)
///!
///! Encode: Request.encode(), Response.encode(), ErrorResponse.encode()
///! all produce line-delimited JSON (trailing '\n').
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
        return encodeJsonLine(allocator, self);
    }
};

/// A JSON-RPC 2.0 success response.
pub const Response = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    result: json.Value = .null,
    id: json.Value,

    /// Serialize this response to a JSON string (with trailing newline).
    pub fn encode(self: Response, allocator: mem.Allocator) ![]u8 {
        return encodeJsonLine(allocator, self);
    }
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

    /// Serialize this error response to a JSON string (with trailing newline).
    pub fn encode(self: ErrorResponse, allocator: mem.Allocator) ![]u8 {
        return encodeJsonLine(allocator, self);
    }
};

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

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
// Decoding — two-layer: parse bytes → json.Value, then extract typed fields
// ---------------------------------------------------------------------------

/// Owns the parsed JSON memory. Fields extracted via extractRequest()
/// borrow from this — they become dangling after deinit().
pub const ParsedMessage = struct {
    parsed: json.Parsed(json.Value),

    pub fn value(self: *const ParsedMessage) json.Value {
        return self.parsed.value;
    }

    pub fn deinit(self: *ParsedMessage) void {
        self.parsed.deinit();
    }
};

/// Parse raw bytes into a JSON value. Caller must deinit the returned
/// ParsedMessage to free memory.
pub fn parseMessage(allocator: mem.Allocator, line: []const u8) !ParsedMessage {
    // Strip trailing newline if present
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\n')
        line[0 .. line.len - 1]
    else
        line;
    const parsed = try json.parseFromSlice(json.Value, allocator, trimmed, .{});
    return .{ .parsed = parsed };
}

/// Extract Request fields from a parsed JSON value.
/// The returned Request borrows string slices from the ParsedMessage — do not
/// use after ParsedMessage.deinit().
pub fn extractRequest(msg: json.Value) !Request {
    if (msg != .object) return error.InvalidRequest;
    const obj = msg.object;

    // Validate jsonrpc version
    const jsonrpc_val = obj.get("jsonrpc") orelse return error.InvalidRequest;
    if (jsonrpc_val != .string) return error.InvalidRequest;
    if (!mem.eql(u8, jsonrpc_val.string, "2.0")) return error.InvalidRequest;

    // Extract method (required, must be string)
    const method_val = obj.get("method") orelse return error.InvalidRequest;
    if (method_val != .string) return error.InvalidRequest;

    // Extract params (optional — null or object or array)
    const params = obj.get("params");

    // Extract id (required for requests; string, integer, or null)
    const id = obj.get("id") orelse .null;

    return .{
        .method = method_val.string,
        .params = params,
        .id = id,
    };
}

/// Returns true if the message is a notification (has method but no id).
/// JSON-RPC 2.0 notifications have method + params but no id field.
pub fn isNotification(msg: json.Value) bool {
    if (msg != .object) return false;
    const obj = msg.object;
    // Must have method
    const method_val = obj.get("method") orelse return false;
    if (method_val != .string) return false;
    // Must NOT have id (absent, not just null)
    return obj.get("id") == null;
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

/// Serialize any struct to JSON + trailing newline.
fn encodeJsonLine(allocator: mem.Allocator, value: anytype) ![]u8 {
    const json_bytes = try json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json_bytes);
    const result = try allocator.alloc(u8, json_bytes.len + 1);
    @memcpy(result[0..json_bytes.len], json_bytes);
    result[json_bytes.len] = '\n';
    return result;
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

test "Request.encode produces valid JSON with newline" {
    const allocator = std.testing.allocator;
    const req = Request{
        .method = "browser.list",
        .id = .{ .integer = 1 },
    };
    const encoded = try req.encode(allocator);
    defer allocator.free(encoded);

    // Must end with newline
    try std.testing.expect(encoded[encoded.len - 1] == '\n');

    // Parse the JSON (without newline) to verify structure
    const parsed = try json.parseFromSlice(json.Value, allocator, encoded[0 .. encoded.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("browser.list", obj.get("method").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
}

test "Response.encode produces valid JSON with newline" {
    const allocator = std.testing.allocator;
    const resp = makeResponse(.{ .integer = 7 }, .{ .bool = true });
    const encoded = try resp.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded[encoded.len - 1] == '\n');

    const parsed = try json.parseFromSlice(json.Value, allocator, encoded[0 .. encoded.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expect(obj.get("result").?.bool == true);
    try std.testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
}

test "ErrorResponse.encode produces valid JSON with newline" {
    const allocator = std.testing.allocator;
    const resp = makeErrorResponse(.{ .string = "req-42" }, .parse_error, "Parse error");
    const encoded = try resp.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded[encoded.len - 1] == '\n');

    const parsed = try json.parseFromSlice(json.Value, allocator, encoded[0 .. encoded.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("req-42", obj.get("id").?.string);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Parse error", err_obj.get("message").?.string);
}

test "parseMessage and extractRequest round-trip" {
    const allocator = std.testing.allocator;

    // Encode a request
    const req = Request{
        .method = "browser.eval",
        .id = .{ .integer = 5 },
    };
    const encoded = try req.encode(allocator);
    defer allocator.free(encoded);

    // Decode it back
    var parsed = try parseMessage(allocator, encoded);
    defer parsed.deinit();
    const decoded = try extractRequest(parsed.value());
    try std.testing.expectEqualStrings("browser.eval", decoded.method);
    try std.testing.expectEqual(@as(i64, 5), decoded.id.integer);
    // When params is null in the struct, it serializes as "params":null,
    // which parses back as a json.Value .null (not absent). Both representations
    // mean "no params" in JSON-RPC 2.0.
    if (decoded.params) |p| {
        try std.testing.expect(p == .null);
    }
}

test "extractRequest rejects missing method" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRequest, extractRequest(parsed.value()));
}

test "extractRequest rejects wrong jsonrpc version" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"1.0\",\"method\":\"test\",\"id\":1}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRequest, extractRequest(parsed.value()));
}

test "extractRequest rejects non-object" {
    const allocator = std.testing.allocator;
    const line = "[1,2,3]";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRequest, extractRequest(parsed.value()));
}

test "extractRequest accepts string id" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":\"abc-123\"}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    const req = try extractRequest(parsed.value());
    try std.testing.expectEqualStrings("abc-123", req.id.string);
}

test "extractRequest accepts integer id" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":42}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    const req = try extractRequest(parsed.value());
    try std.testing.expectEqual(@as(i64, 42), req.id.integer);
}

test "extractRequest accepts null params" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"params\":null,\"id\":1}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    const req = try extractRequest(parsed.value());
    try std.testing.expectEqualStrings("test", req.method);
    try std.testing.expect(req.params.? == .null);
}

test "extractRequest accepts absent params" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    const req = try extractRequest(parsed.value());
    try std.testing.expect(req.params == null);
}

test "isNotification detects broadcast" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"console.output\",\"params\":{}}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expect(isNotification(parsed.value()));
}

test "isNotification rejects request with id" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expect(!isNotification(parsed.value()));
}

test "isNotification rejects non-object" {
    const allocator = std.testing.allocator;
    const line = "\"hello\"";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    try std.testing.expect(!isNotification(parsed.value()));
}

test "parseMessage strips trailing newline" {
    const allocator = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}\n";
    var parsed = try parseMessage(allocator, line);
    defer parsed.deinit();
    const req = try extractRequest(parsed.value());
    try std.testing.expectEqualStrings("test", req.method);
}

test "parseMessage rejects invalid JSON" {
    const allocator = std.testing.allocator;
    const result = parseMessage(allocator, "not json at all");
    try std.testing.expectError(error.SyntaxError, result);
}
