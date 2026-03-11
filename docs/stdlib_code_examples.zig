// EXACT CODE FROM ZIG 0.15.2 STDLIB (std/net.zig)

// ============================================================================
// 1. ADDRESS.INITUNIX() - Create Unix socket address
// ============================================================================

pub fn initUnix(path: []const u8) !Address {
    var sock_addr = posix.sockaddr.un{
        .family = posix.AF.UNIX,
        .path = undefined,
    };

    // Add 1 to ensure a terminating 0 is present in the path array
    if (path.len + 1 > sock_addr.path.len) return error.NameTooLong;

    @memset(&sock_addr.path, 0);
    @memcpy(sock_addr.path[0..path.len], path);

    return .{ .un = sock_addr };
}

// ============================================================================
// 2. ADDRESS.LISTEN() - Create listening server socket
// ============================================================================

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

/// The returned `Server` has an open `stream`.
pub fn listen(address: Address, options: ListenOptions) ListenError!Server {
    const nonblock: u32 = if (options.force_nonblocking) posix.SOCK.NONBLOCK else 0;
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | nonblock;
    const proto: u32 = if (address.any.family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;

    const sockfd = try posix.socket(address.any.family, sock_flags, proto);
    var s: Server = .{
        .listen_address = undefined,
        .stream = .{ .handle = sockfd },
    };
    errdefer s.stream.close();

    if (options.reuse_address) {
        try posix.setsockopt(
            sockfd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &mem.toBytes(@as(c_int, 1)),
        );
        if (@hasDecl(posix.SO, "REUSEPORT") and address.any.family != posix.AF.UNIX) {
            try posix.setsockopt(
                sockfd,
                posix.SOL.SOCKET,
                posix.SO.REUSEPORT,
                &mem.toBytes(@as(c_int, 1)),
            );
        }
    }

    var socklen = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, socklen);
    try posix.listen(sockfd, options.kernel_backlog);
    try posix.getsockname(sockfd, &s.listen_address.any, &socklen);
    return s;
}

// ============================================================================
// 3. SERVER STRUCTURE AND ACCEPT
// ============================================================================

pub const Server = struct {
    listen_address: Address,
    stream: Stream,

    pub const Connection = struct {
        stream: Stream,
        address: Address,
    };

    pub fn deinit(s: *Server) void {
        s.stream.close();
        s.* = undefined;
    }

    pub const AcceptError = posix.AcceptError;

    /// Blocks until a client connects to the server. The returned `Connection` has
    /// an open stream.
    pub fn accept(s: *Server) AcceptError!Connection {
        var accepted_addr: Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(Address);
        const fd = try posix.accept(s.stream.handle, &accepted_addr.any, &addr_len, posix.SOCK.CLOEXEC);
        return .{
            .stream = .{ .handle = fd },
            .address = accepted_addr,
        };
    }
};

// ============================================================================
// 4. CONNECTUNIXSOCKET() - Client connection
// ============================================================================

pub fn connectUnixSocket(path: []const u8) !Stream {
    const opt_non_block = 0;
    const sockfd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | opt_non_block,
        0,
    );
    errdefer Stream.close(.{ .handle = sockfd });

    var addr = try Address.initUnix(path);
    try posix.connect(sockfd, &addr.any, addr.getOsSockLen());

    return .{ .handle = sockfd };
}

// ============================================================================
// 5. STREAM STRUCTURE AND READ/WRITE
// ============================================================================

pub const Stream = struct {
    /// Underlying platform-defined type which may or may not be
    /// interchangeable with a file system file descriptor.
    handle: Handle,

    pub const Handle = switch (native_os) {
        .windows => windows.ws2_32.SOCKET,
        else => posix.fd_t,
    };

    pub fn close(s: Stream) void {
        switch (native_os) {
            .windows => windows.closesocket(s.handle) catch unreachable,
            else => posix.close(s.handle),
        }
    }

    pub const ReadError = posix.ReadError || error{
        SocketNotBound,
        MessageTooBig,
        NetworkSubsystemFailed,
        ConnectionResetByPeer,
        SocketNotConnected,
    };

    pub const WriteError = posix.SendMsgError || error{
        ConnectionResetByPeer,
        SocketNotBound,
        MessageTooBig,
        NetworkSubsystemFailed,
        SystemResources,
        SocketNotConnected,
        Unexpected,
    };

    pub fn reader(stream: Stream, buffer: []u8) Reader {
        return .init(stream, buffer);
    }

    pub fn writer(stream: Stream, buffer: []u8) Writer {
        return .init(stream, buffer);
    }

    /// Deprecated in favor of `Reader`.
    pub fn read(self: Stream, buffer: []u8) ReadError!usize {
        if (native_os == .windows) {
            return windows.ReadFile(self.handle, buffer, null);
        }

        return posix.read(self.handle, buffer);
    }

    /// Deprecated in favor of `Reader`.
    pub fn readv(s: Stream, iovecs: []const posix.iovec) ReadError!usize {
        if (native_os == .windows) {
            if (iovecs.len == 0) return 0;
            const first = iovecs[0];
            return windows.ReadFile(s.handle, first.base[0..first.len], null);
        }

        return posix.readv(s.handle, iovecs);
    }

    /// Deprecated in favor of `Reader`.
    pub fn readAtLeast(s: Stream, buffer: []u8, len: usize) ReadError!usize {
        assert(len <= buffer.len);
        var index: usize = 0;
        while (index < len) {
            const amt = try s.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }

    /// Deprecated in favor of `Writer`.
    pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
        var stream_writer = self.writer(&.{});
        return stream_writer.interface.writeVec(&.{buffer}) catch return stream_writer.err.?;
    }

    /// Deprecated in favor of `Writer`.
    pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    /// Deprecated in favor of `Writer`.
    pub fn writev(self: Stream, iovecs: []const posix.iovec_const) WriteError!usize {
        return @errorCast(posix.writev(self.handle, iovecs));
    }

    /// Deprecated in favor of `Writer`.
    pub fn writevAll(self: Stream, iovecs: []posix.iovec_const) WriteError!void {
        if (iovecs.len == 0) return;

        var i: usize = 0;
        while (true) {
            var amt = try self.writev(iovecs[i..]);
            while (amt >= iovecs[i].len) {
                amt -= iovecs[i].len;
                i += 1;
                if (i >= iovecs.len) return;
            }
            iovecs[i].base += amt;
            iovecs[i].len -= amt;
        }
    }
};

// ============================================================================
// 6. ADDRESS STRUCTURE (union)
// ============================================================================

pub const Address = extern union {
    any: posix.sockaddr,
    in: Ip4Address,
    in6: Ip6Address,
    un: if (has_unix_sockets) posix.sockaddr.un else void,
    
    // ... other methods omitted for brevity ...
};

