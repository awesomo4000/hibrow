///! Browser lifecycle management: find chromium binary, launch with flags,
///! discover running CDP-enabled browser instances.
///!
///! Discovery-first design: finds browsers by scanning processes for
///! --remote-debugging-port flags rather than tracking complex state.
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const builtin = @import("builtin");

/// A discovered or launched browser instance.
pub const Browser = struct {
    /// Profile name (maps to user-data-dir).
    profile: []const u8,
    /// CDP debugging port.
    port: u16,
    /// OS process ID.
    pid: ?posix.pid_t = null,
    /// Whether we launched this browser (vs discovered it).
    managed: bool = false,
};

/// Browser launch configuration.
pub const LaunchOptions = struct {
    profile: []const u8,
    /// Explicit port, or 0 for auto-assign.
    port: u16 = 0,
    /// SOCKS5 proxy URL (e.g., "socks5://127.0.0.1:1080").
    proxy: ?[]const u8 = null,
    /// Route DNS through the proxy (requires SOCKS5).
    proxy_dns: bool = false,
};

/// Profile registry entry (stored in ~/.hibrow/profiles.json).
pub const ProfileEntry = struct {
    name: []const u8,
    directory: []const u8,
    port: u16,
};

// ---------------------------------------------------------------------------
// Chromium binary discovery
// ---------------------------------------------------------------------------

/// Search order for finding a chromium binary.
const chromium_search_paths_macos = [_][]const u8{
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
};

const chromium_search_names_linux = [_][]const u8{
    "google-chrome",
    "chromium-browser",
    "chromium",
};

/// Find the chromium binary path.
/// Priority: HIBROW_BROWSER env var > platform-specific search.
/// Caller owns the returned string.
pub fn findChromium(allocator: mem.Allocator) ![]const u8 {
    // 1. Check HIBROW_BROWSER env var
    if (std.process.getEnvVarOwned(allocator, "HIBROW_BROWSER")) |path| {
        return path;
    } else |_| {}

    // 2. Platform-specific search
    if (builtin.os.tag == .macos) {
        for (chromium_search_paths_macos) |path| {
            if (fs.accessAbsolute(path, .{})) |_| {
                return try allocator.dupe(u8, path);
            } else |_| {}
        }
    } else if (builtin.os.tag == .linux) {
        // Search PATH for known chromium binary names
        if (std.process.getEnvVarOwned(allocator, "PATH")) |path_env| {
            defer allocator.free(path_env);
            for (chromium_search_names_linux) |name| {
                var it = mem.splitScalar(u8, path_env, ':');
                while (it.next()) |dir| {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
                    if (fs.accessAbsolute(full_path, .{})) |_| {
                        return full_path;
                    } else |_| {
                        allocator.free(full_path);
                    }
                }
            }
        } else |_| {}
    }

    return error.ChromiumNotFound;
}

// ---------------------------------------------------------------------------
// Browser launching
// ---------------------------------------------------------------------------

/// Launch a new browser instance with the given options.
/// Returns the Browser info once the instance is responsive.
pub fn launch(allocator: mem.Allocator, options: LaunchOptions) !Browser {
    const chrome = try findChromium(allocator);
    defer allocator.free(chrome);

    // Resolve port from our dedicated range
    const port: u16 = if (options.port == 0) try findFreePortInRange() else options.port;

    // Resolve profile directory
    const profile_dir = try getProfileDir(allocator, options.profile);
    defer allocator.free(profile_dir);

    // Create profile dir if it does not exist
    ensureDirExists(profile_dir) catch {};

    // Build argv
    var argv_list: std.ArrayList([]const u8) = .{};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, chrome);

    var port_buf: [32]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--remote-debugging-port={d}", .{port});
    try argv_list.append(allocator, port_arg);

    var dir_buf: [1024]u8 = undefined;
    const dir_arg = try std.fmt.bufPrint(&dir_buf, "--user-data-dir={s}", .{profile_dir});
    try argv_list.append(allocator, dir_arg);

    try argv_list.append(allocator, "--no-first-run");
    try argv_list.append(allocator, "--no-default-browser-check");
    try argv_list.append(allocator, "--password-store=basic");
    try argv_list.append(allocator, "--use-mock-keychain");

    // Optional proxy args
    if (options.proxy) |proxy| {
        var proxy_buf: [512]u8 = undefined;
        const proxy_arg = try std.fmt.bufPrint(&proxy_buf, "--proxy-server={s}", .{proxy});
        try argv_list.append(allocator, proxy_arg);

        if (options.proxy_dns) {
            try argv_list.append(allocator, "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1");
        }
    }

    try argv_list.append(allocator, "about:blank");

    // Spawn the browser process
    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    // pgid = 0 → create new process group (setsid equivalent)
    child.pgid = 0;

    try child.spawn();
    const pid = child.id;

    // Wait for CDP to become responsive (poll with TCP connect, then verify HTTP)
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        // Quick TCP probe first (cheap)
        if (tcpProbe(port)) {
            // TCP is open — now verify CDP responds over HTTP
            if (verify(allocator, port) catch false) {
                // Record in registry so discovery can map port → profile
                registerProfile(allocator, options.profile, profile_dir, port) catch {};
                return .{
                    .profile = try allocator.dupe(u8, options.profile),
                    .port = port,
                    .pid = pid,
                    .managed = true,
                };
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms between attempts
    }

    return error.BrowserStartupTimeout;
}

// ---------------------------------------------------------------------------
// Port management
// ---------------------------------------------------------------------------

/// CDP port range — we allocate ports sequentially within this range.
/// Starts at 9322 to avoid collisions with the conventional 9222 used
/// by manual --remote-debugging-port sessions.
pub const port_range_start: u16 = 9322;
pub const port_range_end: u16 = 9422;

/// Find the next free port in the CDP range by probing each one.
pub fn findFreePortInRange() !u16 {
    var port: u16 = port_range_start;
    while (port < port_range_end) : (port += 1) {
        if (!tcpProbe(port)) return port;
    }
    return error.NoFreePorts;
}

// ---------------------------------------------------------------------------
// Network-based discovery
// ---------------------------------------------------------------------------

/// Discover running CDP-enabled browsers by scanning the port range.
/// Checks each port for a responsive CDP endpoint, then resolves profile
/// names from the registry. No process scanning — pure network-based.
/// Caller owns the returned slice. Free with freeBrowsers().
pub fn discover(allocator: mem.Allocator) ![]Browser {
    var browsers: std.ArrayList(Browser) = .{};
    errdefer {
        for (browsers.items) |b| allocator.free(b.profile);
        browsers.deinit(allocator);
    }

    // Load profile registry to map ports → profile names
    var registry = ProfileRegistry.init(allocator) catch null;
    defer if (registry) |*r| r.deinit();

    const entries = if (registry) |*r| r.load() catch null else null;
    defer if (entries) |e| {
        for (e) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.directory);
        }
        allocator.free(e);
    };

    var port: u16 = port_range_start;
    while (port < port_range_end) : (port += 1) {
        // Quick TCP probe — skip ports that aren't listening
        if (!tcpProbe(port)) continue;

        // Verify it's actually a CDP endpoint
        if (!(verify(allocator, port) catch false)) continue;

        // Look up profile name from registry
        const profile_name = if (entries) |e| blk: {
            for (e) |entry| {
                if (entry.port == port) break :blk try allocator.dupe(u8, entry.name);
            }
            break :blk try allocator.dupe(u8, "unknown");
        } else try allocator.dupe(u8, "unknown");

        try browsers.append(allocator, .{
            .profile = profile_name,
            .port = port,
            .pid = null,
            .managed = false,
        });
    }

    return try browsers.toOwnedSlice(allocator);
}

/// Free a browser list returned by discover().
pub fn freeBrowsers(allocator: mem.Allocator, browsers: []Browser) void {
    for (browsers) |b| {
        allocator.free(b.profile);
    }
    allocator.free(browsers);
}

// ---------------------------------------------------------------------------
// Browser verification
// ---------------------------------------------------------------------------

/// Quick TCP connect probe — returns true if the port is accepting connections.
/// Much cheaper than a full HTTP request for polling.
pub fn tcpProbe(port: u16) bool {
    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch return false;
    const stream = std.net.tcpConnectToAddress(addr) catch return false;
    stream.close();
    return true;
}

pub fn verify(allocator: mem.Allocator, port: u16) !bool {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/json/version", .{port});
    const uri = std.Uri.parse(url) catch return false;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .uri = uri },
    }) catch return false;

    return result.status == .ok;
}

// ---------------------------------------------------------------------------
// Profile management
// ---------------------------------------------------------------------------

/// Get the profile directory for a named profile.
/// Returns ~/.hibrow/profiles/{name}
pub fn getProfileDir(allocator: mem.Allocator, profile: []const u8) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.hibrow/profiles/{s}", .{ home, profile });
}

/// Default profile registry path: ~/.hibrow/profiles.json
pub fn getProfileRegistryPath(allocator: mem.Allocator) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.hibrow/profiles.json", .{home});
}

/// Profile registry: reads/writes the profile → directory mappings.
pub const ProfileRegistry = struct {
    allocator: mem.Allocator,
    path: []const u8,

    pub fn init(allocator: mem.Allocator) !ProfileRegistry {
        const path = try getProfileRegistryPath(allocator);
        return .{ .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *ProfileRegistry) void {
        self.allocator.free(self.path);
    }

    /// Load all profile entries from the registry file.
    /// Returns empty slice if file does not exist.
    pub fn load(self: *ProfileRegistry) ![]ProfileEntry {
        const data = fs.cwd().readFileAlloc(self.allocator, self.path, 1 << 20) catch |err| {
            if (err == error.FileNotFound) return &[_]ProfileEntry{};
            return err;
        };
        defer self.allocator.free(data);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .array) return error.InvalidRegistry;

        var entries: std.ArrayList(ProfileEntry) = .{};
        defer entries.deinit(self.allocator);

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const name_val = obj.get("name") orelse continue;
            if (name_val != .string) continue;
            const dir_val = obj.get("directory") orelse continue;
            if (dir_val != .string) continue;
            const port_val = obj.get("port") orelse continue;
            if (port_val != .integer) continue;

            try entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name_val.string),
                .directory = try self.allocator.dupe(u8, dir_val.string),
                .port = @intCast(port_val.integer),
            });
        }

        return try entries.toOwnedSlice(self.allocator);
    }

    /// Save profile entries to the registry file.
    /// Uses atomic write (write to .tmp, then rename).
    pub fn save(self: *ProfileRegistry, entries: []const ProfileEntry) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(self.path)) |dir| {
            ensureDirExists(dir) catch {};
        }

        // Serialize to JSON
        const json_data = try std.json.Stringify.valueAlloc(self.allocator, entries, .{});
        defer self.allocator.free(json_data);

        // Write atomically: tmp file then rename
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);

        const file = try fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf);
        try writer.interface.writeAll(json_data);
        try writer.interface.flush();

        try fs.cwd().rename(tmp_path, self.path);
    }
};

/// Register a profile in the registry (upsert by name).
fn registerProfile(allocator: mem.Allocator, name: []const u8, directory: []const u8, port: u16) !void {
    var registry = try ProfileRegistry.init(allocator);
    defer registry.deinit();

    const existing = try registry.load();
    defer {
        for (existing) |e| {
            allocator.free(e.name);
            allocator.free(e.directory);
        }
        allocator.free(existing);
    }

    // Build new entries list: replace if name matches, append if new
    var entries: std.ArrayList(ProfileEntry) = .{};
    defer entries.deinit(allocator);

    var found = false;
    for (existing) |e| {
        if (mem.eql(u8, e.name, name)) {
            try entries.append(allocator, .{ .name = name, .directory = directory, .port = port });
            found = true;
        } else {
            try entries.append(allocator, .{ .name = e.name, .directory = e.directory, .port = e.port });
        }
    }
    if (!found) {
        try entries.append(allocator, .{ .name = name, .directory = directory, .port = port });
    }

    try registry.save(entries.items);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn getHomeDir(allocator: mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch error.NoHomeDir;
}

fn ensureDirExists(path: []const u8) !void {
    // Try to create the full directory tree
    fs.cwd().makePath(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Browser struct has expected fields" {
    const b = Browser{
        .profile = "test",
        .port = 9322,
        .pid = 12345,
        .managed = true,
    };
    try std.testing.expectEqualStrings("test", b.profile);
    try std.testing.expectEqual(@as(u16, 9322), b.port);
    try std.testing.expectEqual(@as(?posix.pid_t, 12345), b.pid);
    try std.testing.expect(b.managed);
}

test "LaunchOptions defaults" {
    const opts = LaunchOptions{
        .profile = "default",
    };
    try std.testing.expectEqual(@as(u16, 0), opts.port);
    try std.testing.expect(opts.proxy == null);
    try std.testing.expect(!opts.proxy_dns);
}

test "findFreePortInRange returns port in range" {
    const port = try findFreePortInRange();
    try std.testing.expect(port >= port_range_start);
    try std.testing.expect(port < port_range_end);
}

test "tcpProbe returns false for unused port" {
    // Port 9421 is very unlikely to be in use
    try std.testing.expect(!tcpProbe(9421));
}

test "getProfileRegistryPath contains hibrow" {
    const allocator = std.testing.allocator;
    const path = getProfileRegistryPath(allocator) catch |err| {
        // OK if HOME is not set in test environment
        if (err == error.NoHomeDir) return;
        return err;
    };
    defer allocator.free(path);
    try std.testing.expect(mem.indexOf(u8, path, ".hibrow/profiles.json") != null);
}

test "getProfileDir contains profile name" {
    const allocator = std.testing.allocator;
    const dir = getProfileDir(allocator, "myprofile") catch |err| {
        if (err == error.NoHomeDir) return;
        return err;
    };
    defer allocator.free(dir);
    try std.testing.expect(mem.indexOf(u8, dir, ".hibrow/profiles/myprofile") != null);
}
