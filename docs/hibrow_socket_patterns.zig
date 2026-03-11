// HIBROW-SPECIFIC SOCKET PATTERNS FOR GATEWAY.ZIG
// Based on Zig 0.15.2 std.net Unix socket API

const std = @import("std");

// ============================================================================
// PATTERN 1: Gateway Daemon Setup - Server Listening
// ============================================================================

pub fn gatewayDaemonSetup(allocator: std.mem.Allocator, socket_path: []const u8) !std.net.Server {
    // 1. Create the socket address
    const addr = try std.net.Address.initUnix(socket_path);
    
    // 2. Set up listening with sensible defaults
    const server = try addr.listen(.{
        .kernel_backlog = 128,           // Queue up to 128 pending connections
        .reuse_address = true,           // Allow quick restarts
        .force_nonblocking = false,      // Use blocking for simplicity
    });
    
    std.debug.print("Gateway listening on {s}\n", .{socket_path});
    return server;
}

// ============================================================================
// PATTERN 2: Accept Loop - Handle Client Connections
// ============================================================================

pub fn acceptLoop(server: *std.net.Server) !void {
    while (true) {
        // Accept blocks until a client connects
        const connection = try server.accept();
        defer connection.stream.close();
        
        // Handle the connection
        // In real code: spawn thread or callback
        try handleClientRequest(connection.stream);
    }
}

// ============================================================================
// PATTERN 3: Read Full JSON-RPC Request
// ============================================================================

pub fn readJsonRpcRequest(
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    buffer: []u8,
) ![]const u8 {
    // Read until EOF or buffer full
    var total_read: usize = 0;
    
    while (total_read < buffer.len) {
        const n = try stream.read(buffer[total_read..]);
        
        if (n == 0) {
            // Connection closed
            break;
        }
        
        total_read += n;
        
        // Check if we have a complete JSON message
        // For now, just read one chunk and assume it's complete
        // In production: implement JSON boundary detection
        if (n < buffer.len - total_read) {
            // Partial read, likely complete message
            break;
        }
    }
    
    return buffer[0..total_read];
}

// ============================================================================
// PATTERN 4: Write JSON-RPC Response
// ============================================================================

pub fn writeJsonRpcResponse(
    stream: std.net.Stream,
    response: []const u8,
) !void {
    // writeAll guarantees all bytes are written
    try stream.writeAll(response);
    
    // Optional: flush if using buffered writer
    // Just writing raw bytes, so no flush needed
}

// ============================================================================
// PATTERN 5: Client Connection - Connect to Gateway
// ============================================================================

pub fn connectToGateway(socket_path: []const u8) !std.net.Stream {
    const stream = try std.net.connectUnixSocket(socket_path);
    
    // In real code: set timeouts if needed
    // Zig 0.15.2 doesn't have built-in timeout support for Unix sockets
    // Use system calls (posix.setsockopt) if needed
    
    return stream;
}

// ============================================================================
// PATTERN 6: Send Request and Read Response
// ============================================================================

pub fn sendRequestReceiveResponse(
    stream: std.net.Stream,
    request: []const u8,
    allocator: std.mem.Allocator,
    response_buffer: []u8,
) ![]const u8 {
    // Send request
    try stream.writeAll(request);
    
    // Read response
    var total_read: usize = 0;
    while (total_read < response_buffer.len) {
        const n = try stream.read(response_buffer[total_read..]);
        
        if (n == 0) {
            // Connection closed
            break;
        }
        
        total_read += n;
        
        // Check for complete message (naive approach)
        if (n < response_buffer.len - total_read) {
            break;
        }
    }
    
    return response_buffer[0..total_read];
}

// ============================================================================
// PATTERN 7: Error Handling Wrapper
// ============================================================================

pub const SocketError = error{
    PathTooLong,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ReadFailed,
    WriteFailed,
    ConnectionClosed,
    ConnectionRefused,
};

pub fn handleSocketError(err: anytype) SocketError!void {
    return switch (err) {
        error.NameTooLong => error.PathTooLong,
        std.net.Address.ListenError.PermissionDenied => error.BindFailed,
        std.net.Address.ListenError.AddressInUse => error.BindFailed,
        std.net.Stream.ReadError.ConnectionResetByPeer => error.ConnectionClosed,
        std.net.Stream.ReadError.SocketNotConnected => error.ConnectionClosed,
        std.net.Stream.WriteError.ConnectionResetByPeer => error.ConnectionClosed,
        std.net.Stream.WriteError.SocketNotConnected => error.ConnectionClosed,
        else => err,
    };
}

// ============================================================================
// PATTERN 8: Complete Gateway Request Handler
// ============================================================================

pub fn handleClientRequest(stream: std.net.Stream) !void {
    var buffer: [8192]u8 = undefined;
    
    // Read request
    const request_bytes = try readJsonRpcRequest(stream, undefined, &buffer);
    
    if (request_bytes.len == 0) {
        return; // Connection closed
    }
    
    // Parse JSON-RPC request (not implemented here)
    // const request = try parseJsonRpcRequest(request_bytes);
    
    // Process request (not implemented here)
    // const result = try processRequest(request);
    
    // Build response (not implemented here)
    // const response = try buildJsonRpcResponse(result);
    
    // Send response
    const response = "{}"; // placeholder
    try writeJsonRpcResponse(stream, response);
}

// ============================================================================
// PATTERN 9: Resource Cleanup
// ============================================================================

pub fn cleanupServer(server: *std.net.Server) void {
    server.deinit();
    // Socket file will still exist on disk
    // In production: call std.fs.deleteFile(socket_path) if needed
}

pub fn cleanupClient(stream: std.net.Stream) void {
    stream.close();
    // Connection is closed
}

// ============================================================================
// PATTERN 10: Full Example - Minimal Gateway
// ============================================================================

pub fn minimalGateway(allocator: std.mem.Allocator) !void {
    const socket_path = "/tmp/hibrow-1000/gateway.sock";
    
    // Setup server
    var server = try gatewayDaemonSetup(allocator, socket_path);
    defer server.deinit();
    
    // Accept loop
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        
        // Read request
        var buffer: [8192]u8 = undefined;
        const n = try connection.stream.read(&buffer);
        
        if (n == 0) continue; // Connection closed immediately
        
        const request = buffer[0..n];
        std.debug.print("Request: {s}\n", .{request});
        
        // Echo response
        const response = "OK";
        try connection.stream.writeAll(response);
    }
}

// ============================================================================
// KEY TAKEAWAYS FOR IMPLEMENTATION
// ============================================================================

// 1. ADDRESS CREATION
//    const addr = try std.net.Address.initUnix(path);
//    - Can fail with error.NameTooLong (~108 byte limit)
//    - Returns Address union with .un field set

// 2. SERVER LISTENING
//    var server = try addr.listen(.{ ... });
//    - Binds, listens, and returns open server
//    - kernel_backlog: how many pending connections
//    - reuse_address: allows quick restart
//    - force_nonblocking: sets O_NONBLOCK flag

// 3. ACCEPTING CONNECTIONS
//    const conn = try server.accept();
//    - BLOCKS until client connects (unless force_nonblocking=true)
//    - Returns Connection { stream, address }
//    - Always defer stream.close()

// 4. CLIENT CONNECTION
//    const stream = try std.net.connectUnixSocket(path);
//    - One call to connect
//    - Returns Stream for read/write
//    - Always defer stream.close()

// 5. READING DATA
//    const n = try stream.read(&buffer);
//    - Partial read: returns immediately with available data
//    - EOF: returns 0 when peer closes
//    - Check n > 0 to detect closed connections

// 6. WRITING DATA
//    try stream.writeAll(data);
//    - Guarantees all bytes written
//    - Loops internally if needed
//    - Preferred over deprecated stream.write()

// 7. ERROR HANDLING
//    All operations use Zig error unions
//    Handle with try/catch or if/else
//    Common errors: PermissionDenied, AddressInUse, ConnectionRefused

// 8. CLEANUP
//    defer server.deinit();
//    defer stream.close();
//    - Always use defer to prevent fd leaks
//    - Safe to call multiple times

