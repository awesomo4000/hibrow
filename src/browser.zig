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

    // Resolve port
    const port: u16 = if (options.port == 0) try findFreePort() else options.port;

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
    try argv_list.append(allocator, "--disable-infobars");
    try argv_list.append(allocator, "--disable-blink-features=AutomationControlled");
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
// Port discovery
// ---------------------------------------------------------------------------

/// Find an available TCP port by binding to port 0 and reading the assigned port.
pub fn findFreePort() !u16 {
    const addr = try std.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    server.deinit();
    return port;
}

// ---------------------------------------------------------------------------
// Process discovery
// ---------------------------------------------------------------------------

/// Discover running CDP-enabled browsers by scanning processes.
/// Caller owns the returned slice. Free with freeBrowsers().
pub fn discover(allocator: mem.Allocator) ![]Browser {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        return discoverPosix(allocator);
    }
    return &[_]Browser{};
}

/// Free a browser list returned by discover().
pub fn freeBrowsers(allocator: mem.Allocator, browsers: []Browser) void {
    for (browsers) |b| {
        allocator.free(b.profile);
    }
    allocator.free(browsers);
}

fn discoverPosix(allocator: mem.Allocator) ![]Browser {
    // Use `ps aux` to find browser processes
    const result = try runCommand(allocator, &.{ "ps", "aux" });
    defer allocator.free(result);

    var browsers: std.ArrayList(Browser) = .{};
    defer browsers.deinit(allocator);

    var lines = mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Look for --remote-debugging-port= in the command
        const port_val = extractCdpPort(line) orelse continue;

        // Extract PID from ps output (second column)
        const pid_val = extractPsPid(line);

        // Extract user-data-dir for profile name
        const profile = if (extractUserDataDir(line)) |dir|
            try allocator.dupe(u8, profileNameFromDir(dir))
        else
            try allocator.dupe(u8, "unknown");

        try browsers.append(allocator, .{
            .profile = profile,
            .port = port_val,
            .pid = pid_val,
            .managed = false,
        });
    }

    return try browsers.toOwnedSlice(allocator);
}

/// Extract --remote-debugging-port=N from a string.
pub fn extractCdpPort(line: []const u8) ?u16 {
    const prefix = "--remote-debugging-port=";
    const start = mem.indexOf(u8, line, prefix) orelse return null;
    const after = line[start + prefix.len ..];
    // Find end of number
    var end: usize = 0;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u16, after[0..end], 10) catch null;
}

/// Extract --user-data-dir=<path> from a string.
pub fn extractUserDataDir(line: []const u8) ?[]const u8 {
    const prefix = "--user-data-dir=";
    const start = mem.indexOf(u8, line, prefix) orelse return null;
    const after = line[start + prefix.len ..];
    // Value ends at space or end of string
    const end = mem.indexOfScalar(u8, after, ' ') orelse after.len;
    if (end == 0) return null;
    return after[0..end];
}

/// Extract profile name from a user-data-dir path.
/// If the path contains "hibrow/profiles/", use the last component.
/// Otherwise, use the last path component.
pub fn profileNameFromDir(dir: []const u8) []const u8 {
    // Try to extract from hibrow profile path
    const marker = "hibrow/profiles/";
    if (mem.indexOf(u8, dir, marker)) |pos| {
        const after = dir[pos + marker.len ..];
        // Trim trailing slashes
        const trimmed = mem.trimRight(u8, after, "/");
        if (trimmed.len > 0) return trimmed;
    }
    // Fall back to last path component
    const trimmed = mem.trimRight(u8, dir, "/");
    if (mem.lastIndexOfScalar(u8, trimmed, '/')) |last_slash| {
        return trimmed[last_slash + 1 ..];
    }
    return trimmed;
}

/// Extract PID from ps aux output line (second whitespace-delimited field).
fn extractPsPid(line: []const u8) ?posix.pid_t {
    // Skip leading whitespace and first field (USER)
    var rest = mem.trimLeft(u8, line, " ");
    // Skip USER field
    const user_end = mem.indexOfScalar(u8, rest, ' ') orelse return null;
    rest = mem.trimLeft(u8, rest[user_end..], " ");
    // PID field
    const pid_end = mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const pid_str = rest[0..pid_end];
    return std.fmt.parseInt(posix.pid_t, pid_str, 10) catch null;
}

// ---------------------------------------------------------------------------
// Browser verification
// ---------------------------------------------------------------------------

/// Verify a browser is responsive by hitting its CDP endpoint.
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

fn runCommand(allocator: mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Read all stdout
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    const stdout = child.stdout.?;
    while (true) {
        const n = try stdout.read(&read_buf);
        if (n == 0) break;
        try output.appendSlice(allocator, read_buf[0..n]);
    }

    _ = try child.wait();
    return try output.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Browser struct has expected fields" {
    const b = Browser{
        .profile = "test",
        .port = 9222,
        .pid = 12345,
        .managed = true,
    };
    try std.testing.expectEqualStrings("test", b.profile);
    try std.testing.expectEqual(@as(u16, 9222), b.port);
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

test "extractCdpPort finds port" {
    const line = "user  12345 0.0 1.0 /usr/bin/chrome --remote-debugging-port=9222 --no-first-run";
    try std.testing.expectEqual(@as(?u16, 9222), extractCdpPort(line));
}

test "extractCdpPort returns null for no port" {
    const line = "/usr/bin/chrome --headless --no-first-run";
    try std.testing.expect(extractCdpPort(line) == null);
}

test "extractCdpPort handles port at end of line" {
    const line = "--remote-debugging-port=12345";
    try std.testing.expectEqual(@as(?u16, 12345), extractCdpPort(line));
}

test "extractUserDataDir finds path" {
    const line = "chrome --user-data-dir=/home/user/.hibrow/profiles/work --remote-debugging-port=9222";
    const dir = extractUserDataDir(line).?;
    try std.testing.expectEqualStrings("/home/user/.hibrow/profiles/work", dir);
}

test "extractUserDataDir returns null when missing" {
    const line = "chrome --remote-debugging-port=9222";
    try std.testing.expect(extractUserDataDir(line) == null);
}

test "profileNameFromDir extracts hibrow profile name" {
    try std.testing.expectEqualStrings("work", profileNameFromDir("/home/user/.hibrow/profiles/work"));
    try std.testing.expectEqualStrings("personal", profileNameFromDir("/home/user/.hibrow/profiles/personal/"));
}

test "profileNameFromDir falls back to last component" {
    try std.testing.expectEqualStrings("custom-dir", profileNameFromDir("/tmp/custom-dir"));
    try std.testing.expectEqualStrings("myprofile", profileNameFromDir("/tmp/myprofile/"));
}

test "profileNameFromDir handles bare name" {
    try std.testing.expectEqualStrings("simple", profileNameFromDir("simple"));
}

test "findFreePort returns valid port" {
    const port = try findFreePort();
    try std.testing.expect(port > 0);
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

test "extractPsPid parses pid from ps output" {
    const line = "user     12345  0.0  1.0 12345 1234 ?  Sl   09:00   0:01 /usr/bin/chrome";
    const pid = extractPsPid(line);
    try std.testing.expectEqual(@as(?posix.pid_t, 12345), pid);
}

test "extractPsPid returns null for invalid line" {
    try std.testing.expect(extractPsPid("") == null);
    try std.testing.expect(extractPsPid("nopid") == null);
}
