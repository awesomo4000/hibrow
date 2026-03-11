# Zig 0.15.2 Unix Domain Socket API Reference

## Overview
Zig's `std.net` module provides complete Unix domain socket support for both server and client implementations.

---

## 1. Creating Unix Socket Address: `Address.initUnix()`

**Function Signature:**
```zig
pub fn initUnix(path: []const u8) !Address
```

**Parameters:**
- `path: []const u8` — The Unix socket path (e.g., `/tmp/hibrow-1000/gateway.sock`)

**Returns:**
- `Address` — An Address union with the `.un` field set (posix.sockaddr.un)
- `error.NameTooLong` — If the path is too long for the socket address structure

**Implementation Details:**
- Internally creates a `posix.sockaddr.un` struct
- Initializes with `family = posix.AF.UNIX`
- Copies the path into the address struct (zero-padded)
- Requires path.len + 1 <= socket address path limit (typically 108 bytes on Linux)

**Example Usage:**
```zig
const addr = try std.net.Address.initUnix("/tmp/hibrow-1000/gateway.sock");
```

---

## 2. Server: Creating & Listening

### Address.listen() — Create a listening server

**Function Signature:**
```zig
pub fn listen(
    address: Address,
    options: ListenOptions
) ListenError!Server
```

**Parameters:**
- `address: Address` — The address to bind to (created via `Address.initUnix()`)
- `options: ListenOptions` — Configuration struct (see below)

**Returns:**
- `Server` — A server struct with listening stream
- `ListenError` — Various socket errors (e.g., PermissionDenied, AddressInUse)

**ListenOptions Structure:**
```zig
pub const ListenOptions = struct {
    /// How many connections the kernel will accept on the application's behalf.
    /// If more than this many connections pool in the kernel, clients will start
    /// seeing "Connection refused".
    kernel_backlog: u31 = 128,
    
    /// Sets SO_REUSEADDR and SO_REUSEPORT on POSIX.
    /// Sets SO_REUSEADDR on Windows, which is roughly equivalent.
    reuse_address: bool = false,
    
    /// Sets O_NONBLOCK.
    force_nonblocking: bool = false,
};
```

**Typical Server Setup:**
```zig
const addr = try std.net.Address.initUnix("/tmp/hibrow-1000/gateway.sock");
var server = try addr.listen(.{
    .kernel_backlog = 128,
    .reuse_address = true,
    .force_nonblocking = false,  // Use blocking for simplicity
});
defer server.deinit();
```

### Server Structure

**Server Definition:**
```zig
pub const Server = struct {
    listen_address: Address,
    stream: Stream,
    
    pub const Connection = struct {
        stream: Stream,
        address: Address,
    };
    
    pub fn deinit(s: *Server) void;
    pub fn accept(s: *Server) AcceptError!Connection;
};
```

### Server.accept() — Accept client connections

**Function Signature:**
```zig
pub fn accept(s: *Server) AcceptError!Connection
```

**Behavior:**
- **Blocks** until a client connects (unless `force_nonblocking=true`)
- Returns `Server.Connection` with:
  - `stream: Stream` — The connected socket
  - `address: Address` — The client's address

**Example Server Loop:**
```zig
while (true) {
    const connection = try server.accept();
    defer connection.stream.close();
    
    // Read from connection.stream
    var buffer: [4096]u8 = undefined;
    const bytes_read = try connection.stream.read(&buffer);
}
```

---

## 3. Client: Connecting to Unix Socket

### connectUnixSocket() — Connect to a Unix domain socket

**Function Signature:**
```zig
pub fn connectUnixSocket(path: []const u8) !Stream
```

**Parameters:**
- `path: []const u8` — Path to the Unix socket to connect to

**Returns:**
- `Stream` — Connected socket stream for reading/writing
- Error — Connection errors (e.g., FileNotFound, ConnectionRefused)

**Implementation Details:**
- Creates an `AF.UNIX` socket with `SOCK.STREAM | SOCK.CLOEXEC` flags
- Internally calls `Address.initUnix()` and `posix.connect()`
- Blocks until connected (non-blocking not set)

**Example Client Connection:**
```zig
const stream = try std.net.connectUnixSocket("/tmp/hibrow-1000/gateway.sock");
defer stream.close();

// Write request
try stream.writeAll(request_json);

// Read response
var buffer: [4096]u8 = undefined;
const bytes_read = try stream.read(&buffer);
```

---

## 4. Stream: Reading & Writing Data

### Stream Structure

**Stream Definition:**
```zig
pub const Stream = struct {
    handle: Handle,  // posix.fd_t on Unix
    
    // Reading
    pub fn read(self: Stream, buffer: []u8) ReadError!usize;
    pub fn readv(s: Stream, iovecs: []const posix.iovec) ReadError!usize;
    pub fn readAtLeast(s: Stream, buffer: []u8, len: usize) ReadError!usize;
    
    // Writing
    pub fn write(self: Stream, buffer: []const u8) WriteError!usize;
    pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void;
    pub fn writev(self: Stream, iovecs: []const posix.iovec_const) WriteError!usize;
    pub fn writevAll(self: Stream, iovecs: []posix.iovec_const) WriteError!void;
    
    // Reader/Writer interfaces
    pub fn reader(stream: Stream, buffer: []u8) Reader;
    pub fn writer(stream: Stream, buffer: []u8) Writer;
    
    // Lifecycle
    pub fn close(s: Stream) void;
};
```

### Stream.read() — Read from socket

**Function Signature:**
```zig
pub fn read(self: Stream, buffer: []u8) ReadError!usize
```

**Parameters:**
- `buffer: []u8` — Buffer to read data into

**Returns:**
- `usize` — Number of bytes read (0 means EOF/closed connection)
- `ReadError` — Socket read errors

**Behavior:**
- Reads up to `buffer.len` bytes
- Returns immediately after reading available data (doesn't wait for full buffer)
- Returns 0 on EOF (peer closed connection)

**Example:**
```zig
var buffer: [4096]u8 = undefined;
const n = try stream.read(&buffer);
if (n == 0) {
    // Connection closed
    break;
}
const data = buffer[0..n];
```

### Stream.write() — Write to socket

**Function Signature:**
```zig
pub fn write(self: Stream, buffer: []const u8) WriteError!usize
```

**Parameters:**
- `buffer: []const u8` — Data to write

**Returns:**
- `usize` — Number of bytes actually written
- `WriteError` — Socket write errors

**Behavior:**
- May write fewer bytes than provided (partial write)
- Must loop to ensure all data is written

**Example (Deprecated):**
```zig
const n = try stream.write(data);  // Might not write everything!
```

### Stream.writeAll() — Write all data (recommended)

**Function Signature:**
```zig
pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void
```

**Parameters:**
- `bytes: []const u8` — All data to write

**Returns:**
- `void` — Completes only when all bytes written
- `WriteError` — Socket write errors

**Behavior:**
- Loops internally until all bytes are written
- Guarantees all data is sent (or error occurs)

**Example (Preferred):**
```zig
try stream.writeAll(json_data);  // Guaranteed to write everything
```

### Stream.close() — Close socket

**Function Signature:**
```zig
pub fn close(s: Stream) void
```

**Behavior:**
- Closes the underlying file descriptor
- Safe to call multiple times
- Should be called in defer blocks to ensure cleanup

---

## 5. Error Types

### ReadError
```zig
pub const ReadError = posix.ReadError || error{
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    ConnectionResetByPeer,
    SocketNotConnected,
};
```

### WriteError
```zig
pub const WriteError = posix.SendMsgError || error{
    ConnectionResetByPeer,
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    SystemResources,
    SocketNotConnected,
    Unexpected,
};
```

### ListenError
Various socket errors from bind/listen operations.

### AcceptError
Errors from accepting connections (same as posix.AcceptError).

---

## 6. Complete Example: Unix Socket Server & Client

### Server Implementation
```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create socket address
    const addr = try std.net.Address.initUnix("/tmp/test.sock");
    
    // Listen for connections
    var server = try addr.listen(.{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    defer server.deinit();
    
    std.debug.print("Server listening on /tmp/test.sock\n", .{});
    
    // Accept loop
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        
        // Read request
        var buffer: [4096]u8 = undefined;
        const n = try connection.stream.read(&buffer);
        
        if (n > 0) {
            std.debug.print("Received: {s}\n", .{buffer[0..n]});
            
            // Echo response
            try connection.stream.writeAll("Echo: ");
            try connection.stream.writeAll(buffer[0..n]);
        }
    }
}
```

### Client Implementation
```zig
const std = @import("std");

pub fn main() !void {
    // Connect to server
    const stream = try std.net.connectUnixSocket("/tmp/test.sock");
    defer stream.close();
    
    // Send message
    const message = "Hello, server!";
    try stream.writeAll(message);
    
    // Read response
    var buffer: [1024]u8 = undefined;
    const n = try stream.read(&buffer);
    
    std.debug.print("Response: {s}\n", .{buffer[0..n]});
}
```

---

## 7. Key Design Patterns for hibrow

### Pattern 1: Server Accept Loop
```zig
var server = try address.listen(.{
    .kernel_backlog = 128,
    .reuse_address = true,
    .force_nonblocking = false,  // Blocking for simplicity
});
defer server.deinit();

while (true) {
    const conn = try server.accept();
    // Handle connection in thread or callback
}
```

### Pattern 2: Client Connection
```zig
const stream = try std.net.connectUnixSocket(socket_path);
defer stream.close();

try stream.writeAll(json_request);
var buffer: [8192]u8 = undefined;
const n = try stream.read(&buffer);
```

### Pattern 3: Robust Read Loop
```zig
var buffer: [4096]u8 = undefined;
var total_read: usize = 0;

while (true) {
    const n = try stream.read(buffer[total_read..]);
    if (n == 0) break;  // EOF
    total_read += n;
    if (total_read == buffer.len) break;  // Full buffer
}

const message = buffer[0..total_read];
```

---

## 8. Important Notes

1. **Path Length Limit**: Unix socket paths are typically limited to ~108 bytes. The `initUnix()` function will return `error.NameTooLong` if exceeded.

2. **Socket Lifecycle**:
   - Server: `Address.listen()` → `server.accept()` → `stream.read()/write()` → `stream.close()`
   - Client: `connectUnixSocket()` → `stream.read()/write()` → `stream.close()`

3. **Blocking vs Non-blocking**:
   - Default is blocking (recommended for simple daemon)
   - Set `force_nonblocking=true` to use O_NONBLOCK, requires proper error handling

4. **Memory Management**:
   - All socket operations use standard Zig error handling (no exceptions)
   - Always use `defer stream.close()` to prevent fd leaks

5. **Deprecated Methods**:
   - `stream.read()`, `stream.write()` are marked deprecated
   - Preferred: Use `stream.reader()` and `stream.writer()` for buffered I/O
   - For simple cases, `stream.writeAll()` and looping `read()` is fine

6. **Address Union**:
   - `Address` is a tagged union with `.any`, `.in` (IPv4), `.in6` (IPv6), and `.un` (Unix)
   - For Unix sockets, the `.un` field is used (type: `posix.sockaddr.un`)

