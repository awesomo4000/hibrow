# Zig 0.15.2 Unix Domain Socket APIs - Complete Reference

## Source Information

All APIs extracted from: `<zig>/lib/std/net.zig`

## Quick Summary Table

| Function | Location | Purpose | Key Notes |
|----------|----------|---------|-----------|
| `Address.initUnix()` | `std.net` | Create Unix socket address | Returns Address union with .un field; max ~108 bytes |
| `Address.listen()` | `std.net` | Create & bind listening server | All-in-one: socket + bind + listen |
| `Server.accept()` | `std.net` | Accept client connection | BLOCKS until client arrives |
| `connectUnixSocket()` | `std.net` | Client connect to socket | One-call connection |
| `Stream.read()` | `std.net` | Read data from socket | Partial read; returns 0 on EOF |
| `Stream.writeAll()` | `std.net` | Write all data | Guarantees full write (loops internally) |
| `Stream.close()` | `std.net` | Close socket | Safe to call multiple times |
| `Server.deinit()` | `std.net` | Cleanup server | Always use defer |

## Function Signatures at a Glance

### 1. `Address.initUnix(path: []const u8) !Address`
- **Parameters**: Unix socket path string
- **Returns**: Address union with `.un` field set
- **Errors**: `error.NameTooLong` if path > ~108 bytes
- **Notes**: Internally creates posix.sockaddr.un struct

### 2. `Address.listen(address: Address, options: ListenOptions) !Server`
- **Parameters**: 
  - Address (from initUnix)
  - Options: kernel_backlog (u31=128), reuse_address (bool=false), force_nonblocking (bool=false)
- **Returns**: Server struct with listening stream
- **Errors**: PermissionDenied, AddressInUse, etc.
- **Notes**: Single call binds and starts listening

### 3. `Server.accept(s: *Server) !Server.Connection`
- **Parameters**: Pointer to Server
- **Returns**: Connection { stream: Stream, address: Address }
- **Behavior**: BLOCKS until client connects
- **Notes**: Connection includes client's Unix address

### 4. `connectUnixSocket(path: []const u8) !Stream`
- **Parameters**: Path to Unix socket
- **Returns**: Connected Stream for read/write
- **Errors**: FileNotFound, ConnectionRefused, etc.
- **Notes**: Combines socket creation + connect in one call

### 5. `Stream.read(self: Stream, buffer: []u8) !usize`
- **Parameters**: Buffer to read into
- **Returns**: Number of bytes read (0 = EOF)
- **Errors**: ReadError types
- **Notes**: May return partial read; check return value

### 6. `Stream.writeAll(self: Stream, bytes: []const u8) !void`
- **Parameters**: Data to write
- **Returns**: void (all data written or error)
- **Errors**: WriteError types
- **Notes**: Loops internally; use instead of deprecated `write()`

### 7. `Stream.close(s: Stream) void`
- **Parameters**: Stream to close
- **Returns**: void
- **Notes**: Safe to call multiple times

### 8. `Server.deinit(s: *Server) void`
- **Parameters**: Pointer to Server
- **Returns**: void
- **Notes**: Close listening socket; use in defer

## ListenOptions Struct

```zig
pub const ListenOptions = struct {
    kernel_backlog: u31 = 128,      // Pending connections kernel accepts
    reuse_address: bool = false,    // SO_REUSEADDR + SO_REUSEPORT
    force_nonblocking: bool = false // Set O_NONBLOCK
};
```

## Server.Connection Struct

```zig
pub const Connection = struct {
    stream: Stream,                 // Connected socket
    address: Address,               // Client's address
};
```

## Stream Error Types

```zig
pub const ReadError = posix.ReadError || error{
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    ConnectionResetByPeer,          // Peer closed
    SocketNotConnected,
};

pub const WriteError = posix.SendMsgError || error{
    ConnectionResetByPeer,          // Peer closed
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    SystemResources,
    SocketNotConnected,
    Unexpected,
};
```

## Lifecycle Diagrams

### Server Lifecycle
```
initUnix(path)
    ↓
listen(options)
    ↓
accept()  ← BLOCKS here
    ↓
Connection { stream, address }
    ↓
read/write/close
    ↓
deinit()
```

### Client Lifecycle
```
connectUnixSocket(path)
    ↓
Stream
    ↓
writeAll(request)
    ↓
read(response)
    ↓
close()
```

## Implementation Checklist for hibrow/gateway.zig

- [ ] Import std.net for socket functions
- [ ] Call Address.initUnix() to create server address (handle NameTooLong error)
- [ ] Call address.listen() with appropriate options (reuse_address=true for restarts)
- [ ] Store Server in main/while loop
- [ ] defer server.deinit() at server setup
- [ ] loop: accept() to get Connection
- [ ] defer connection.stream.close() in loop
- [ ] Read JSON-RPC request with stream.read()
  - Check return value for EOF (0 bytes = connection closed)
  - Loop if partial reads needed
- [ ] Parse and process request
- [ ] Build JSON-RPC response
- [ ] Write response with stream.writeAll()
- [ ] Handle errors gracefully
- [ ] Test client connection with connectUnixSocket()
- [ ] Test partial reads/writes
- [ ] Clean up fd leaks with proper defer statements

## Key Differences from Zig Network Code

1. **No separate bind()**: Address.listen() does bind + listen internally
2. **Simple API**: connectUnixSocket() is one call, not socket() + Address.initUnix() + connect()
3. **Blocking by default**: Use force_nonblocking=true only if needed
4. **writeAll() is preferred**: The write() method is marked deprecated
5. **EOF detection**: read() returns 0 bytes on EOF, not an error
6. **Stream.close() is idempotent**: Safe to call multiple times

## Common Patterns for hibrow

### Pattern: Basic Server Loop
```zig
const addr = try std.net.Address.initUnix(socket_path);
var server = try addr.listen(.{ .reuse_address = true });
defer server.deinit();

while (true) {
    const conn = try server.accept();
    defer conn.stream.close();
    
    var buffer: [8192]u8 = undefined;
    const n = try conn.stream.read(&buffer);
    
    if (n > 0) {
        try conn.stream.writeAll(response);
    }
}
```

### Pattern: Basic Client
```zig
const stream = try std.net.connectUnixSocket(socket_path);
defer stream.close();

try stream.writeAll(json_request);

var buffer: [8192]u8 = undefined;
const n = try stream.read(&buffer);
const response = buffer[0..n];
```

### Pattern: Robust Read Loop
```zig
var buffer: [8192]u8 = undefined;
var total: usize = 0;

while (total < buffer.len) {
    const n = try stream.read(buffer[total..]);
    if (n == 0) break;  // EOF
    total += n;
}

const data = buffer[0..total];
```

## Performance Notes

- **Unix sockets are fast**: Zero-copy byte transfer between processes
- **Blocking is fine**: For a daemon with few clients
- **kernel_backlog=128**: Reasonable for most cases
- **8KB buffer**: Good default for JSON-RPC messages
- **Stream.writeAll()**: No performance penalty; just loops internally

## Testing

Test the APIs with this pattern:
```zig
test "unix socket basic" {
    const socket_path = "/tmp/test.sock";
    
    // Server setup
    const addr = try std.net.Address.initUnix(socket_path);
    var server = try addr.listen(.{});
    defer server.deinit();
    
    // Client connect
    const client = try std.net.connectUnixSocket(socket_path);
    defer client.close();
    
    // Server accept
    const conn = try server.accept();
    defer conn.stream.close();
    
    // Test write/read
    try client.writeAll("Hello");
    var buf: [64]u8 = undefined;
    const n = try conn.stream.read(&buf);
    
    try std.testing.expectEqualSlices(u8, "Hello", buf[0..n]);
}
```

## References

- Stdlib path: `<zig>/lib/std/net.zig`
- Zig version: 0.15.2
- Target: hibrow gateway daemon with Unix domain socket communication
- Documentation: See source code for detailed comments

