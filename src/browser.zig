///! Browser lifecycle management: find chromium binary, launch with flags,
///! discover running CDP-enabled browser instances.
///!
///! Discovery-first design: finds browsers by scanning processes for
///! --remote-debugging-port flags rather than tracking complex state.
///! Process args are the registry — zero files, fully stateless.
const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const builtin = @import("builtin");
const process = @import("process.zig");

/// Browser engine type.
pub const BrowserType = enum {
    chrome,
    firefox,

    pub fn toString(self: BrowserType) []const u8 {
        return switch (self) {
            .chrome => "chrome",
            .firefox => "firefox",
        };
    }

    pub fn fromString(s: []const u8) ?BrowserType {
        if (mem.eql(u8, s, "chrome")) return .chrome;
        if (mem.eql(u8, s, "firefox") or mem.eql(u8, s, "ff")) return .firefox;
        return null;
    }
};

/// A discovered or launched browser instance.
pub const Browser = struct {
    /// Profile name (maps to user-data-dir).
    profile: []const u8,
    /// CDP debugging port (Chrome) or Marionette port (Firefox).
    port: u16,
    /// OS process ID.
    pid: ?posix.pid_t = null,
    /// Whether we launched this browser (vs discovered it).
    managed: bool = false,
    /// Browser engine type.
    browser_type: BrowserType = .chrome,
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
    /// Browser engine to launch.
    browser_type: BrowserType = .chrome,
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
// Firefox binary discovery
// ---------------------------------------------------------------------------

/// Search order for finding a Firefox binary.
const firefox_search_paths_macos = [_][]const u8{
    "/Applications/Firefox.app/Contents/MacOS/firefox",
};

const firefox_search_names_linux = [_][]const u8{
    "firefox",
};

/// Find the Firefox binary path.
/// Priority: HIBROW_FIREFOX env var > platform-specific search.
/// Caller owns the returned string.
pub fn findFirefox(allocator: mem.Allocator) ![]const u8 {
    // 1. Check HIBROW_FIREFOX env var
    if (std.process.getEnvVarOwned(allocator, "HIBROW_FIREFOX")) |path| {
        return path;
    } else |_| {}

    // 2. Platform-specific search
    if (builtin.os.tag == .macos) {
        for (firefox_search_paths_macos) |path| {
            if (fs.accessAbsolute(path, .{})) |_| {
                return try allocator.dupe(u8, path);
            } else |_| {}
        }
    } else if (builtin.os.tag == .linux) {
        // Search PATH for known Firefox binary names
        if (std.process.getEnvVarOwned(allocator, "PATH")) |path_env| {
            defer allocator.free(path_env);
            for (firefox_search_names_linux) |name| {
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

    return error.FirefoxNotFound;
}

// ---------------------------------------------------------------------------
// Browser launching
// ---------------------------------------------------------------------------

/// Launch a new browser instance with the given options.
/// Returns the Browser info once the instance is responsive.
pub fn launch(allocator: mem.Allocator, options: LaunchOptions) !Browser {
    return switch (options.browser_type) {
        .chrome => launchChrome(allocator, options),
        .firefox => launchFirefox(allocator, options),
    };
}

/// Launch a Chrome instance.
fn launchChrome(allocator: mem.Allocator, options: LaunchOptions) !Browser {
    const chrome = try findChromium(allocator);
    defer allocator.free(chrome);

    // Resolve port from our dedicated range
    const port: u16 = if (options.port == 0) try findFreePortInRangeFor(.chrome) else options.port;

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
                return .{
                    .profile = try allocator.dupe(u8, options.profile),
                    .port = port,
                    .pid = pid,
                    .managed = true,
                    .browser_type = .chrome,
                };
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms between attempts
    }

    return error.BrowserStartupTimeout;
}

/// Launch a Firefox instance.
fn launchFirefox(allocator: mem.Allocator, options: LaunchOptions) !Browser {
    const firefox = try findFirefox(allocator);
    defer allocator.free(firefox);

    // Resolve port from Firefox-dedicated range
    const port: u16 = if (options.port == 0) try findFreePortInRangeFor(.firefox) else options.port;

    // Resolve profile directory (same structure as Chrome)
    const profile_dir = try getProfileDir(allocator, options.profile);
    defer allocator.free(profile_dir);

    // Create profile dir if it does not exist
    ensureDirExists(profile_dir) catch {};

    // Write user.js with Marionette prefs before launch
    try writeFirefoxPrefs(allocator, profile_dir, port);

    // Build argv
    var argv_list: std.ArrayList([]const u8) = .{};
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, firefox);
    try argv_list.append(allocator, "--marionette");
    try argv_list.append(allocator, "--no-remote");

    try argv_list.append(allocator, "--profile");
    try argv_list.append(allocator, profile_dir);

    // Spawn the browser process
    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.pgid = 0;

    try child.spawn();
    const pid = child.id;

    // Wait for Marionette TCP port to accept connections.
    // Unlike Chrome (which needs HTTP verify), Marionette sends a handshake
    // on connect — so TCP open means ready.
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (tcpProbe(port)) {
            return .{
                .profile = try allocator.dupe(u8, options.profile),
                .port = port,
                .pid = pid,
                .managed = true,
                .browser_type = .firefox,
            };
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    return error.BrowserStartupTimeout;
}

/// Write Firefox user.js with Marionette port and essential prefs.
fn writeFirefoxPrefs(allocator: mem.Allocator, profile_dir: []const u8, port: u16) !void {
    const prefs_path = try std.fmt.allocPrint(allocator, "{s}/user.js", .{profile_dir});
    defer allocator.free(prefs_path);

    const prefs_content = try std.fmt.allocPrint(allocator,
        \\// hibrow-managed Firefox prefs — do not edit
        \\user_pref("marionette.port", {d});
        \\user_pref("browser.shell.checkDefaultBrowser", false);
        \\user_pref("browser.startup.page", 0);
        \\user_pref("browser.startup.homepage_override.mstone", "ignore");
        \\user_pref("startup.homepage_welcome_url", "about:blank");
        \\user_pref("startup.homepage_welcome_url.additional", "");
        \\user_pref("app.update.disabledForTesting", true);
        \\user_pref("datareporting.policy.dataSubmissionEnabled", false);
        \\user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
        \\user_pref("browser.warnOnQuit", false);
        \\user_pref("browser.sessionstore.resume_from_crash", false);
        \\user_pref("toolkit.startup.max_resumed_crashes", -1);
        \\user_pref("extensions.autoDisableScopes", 0);
        \\user_pref("extensions.enabledScopes", 5);
        \\user_pref("browser.aboutConfig.showWarning", false);
        \\user_pref("devtools.debugger.remote-enabled", true);
        \\user_pref("devtools.debugger.prompt-connection", false);
        \\user_pref("dom.ipc.reportProcessHangs", false);
        \\user_pref("app.normandy.api_url", "");
        \\user_pref("browser.uitour.enabled", false);
        \\
    , .{port});
    defer allocator.free(prefs_content);

    const file = try fs.cwd().createFile(prefs_path, .{});
    defer file.close();
    try file.writeAll(prefs_content);
}

// ---------------------------------------------------------------------------
// Port management
// ---------------------------------------------------------------------------

/// CDP port range — we allocate ports sequentially within this range.
/// Starts at 9322 to avoid collisions with the conventional 9222 used
/// by manual --remote-debugging-port sessions.
pub const port_range_start: u16 = 9322;
pub const port_range_end: u16 = 9422;

/// Marionette port range for Firefox — separate from Chrome CDP ports.
pub const firefox_port_range_start: u16 = 9800;
pub const firefox_port_range_end: u16 = 9900;

/// Find the next free port in the CDP range by probing each one.
pub fn findFreePortInRange() !u16 {
    return findFreePortInRangeFor(.chrome);
}

/// Find the next free port in the appropriate range for the given browser type.
pub fn findFreePortInRangeFor(browser_type: BrowserType) !u16 {
    const start = switch (browser_type) {
        .chrome => port_range_start,
        .firefox => firefox_port_range_start,
    };
    const end = switch (browser_type) {
        .chrome => port_range_end,
        .firefox => firefox_port_range_end,
    };
    var port: u16 = start;
    while (port < end) : (port += 1) {
        if (!tcpProbe(port)) return port;
    }
    return error.NoFreePorts;
}

// ---------------------------------------------------------------------------
// Process-based discovery
// ---------------------------------------------------------------------------

/// Discover running CDP-enabled browsers by scanning process args.
/// Uses proc_listpids + sysctl(KERN_PROCARGS2) on macOS to find Chrome
/// processes with --remote-debugging-port and --user-data-dir flags.
/// Caller owns the returned slice. Free with freeBrowsers().
pub fn discover(allocator: mem.Allocator) ![]Browser {
    const procs = try process.findChromeBrowsers(allocator);
    defer process.freeDiscovered(allocator, procs);

    var browsers: std.ArrayList(Browser) = .{};
    errdefer {
        for (browsers.items) |b| allocator.free(b.profile);
        browsers.deinit(allocator);
    }

    for (procs) |p| {
        try browsers.append(allocator, .{
            .profile = try allocator.dupe(u8, p.profile),
            .port = p.port,
            .pid = p.pid,
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

/// Look up a browser's CDP port by scanning processes for the given profile.
/// Returns null if no process found with that profile name.
pub fn lookupPort(allocator: mem.Allocator, profile: []const u8) !?u16 {
    const procs = process.findChromeBrowsers(allocator) catch return null;
    defer process.freeDiscovered(allocator, procs);

    for (procs) |p| {
        if (mem.eql(u8, p.profile, profile)) {
            return p.port;
        }
    }
    return null;
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
        .browser_type = .chrome,
    };
    try std.testing.expectEqualStrings("test", b.profile);
    try std.testing.expectEqual(@as(u16, 9322), b.port);
    try std.testing.expectEqual(@as(?posix.pid_t, 12345), b.pid);
    try std.testing.expect(b.managed);
    try std.testing.expectEqual(BrowserType.chrome, b.browser_type);
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

test "BrowserType toString and fromString" {
    try std.testing.expectEqualStrings("chrome", BrowserType.chrome.toString());
    try std.testing.expectEqualStrings("firefox", BrowserType.firefox.toString());
    try std.testing.expectEqual(BrowserType.chrome, BrowserType.fromString("chrome").?);
    try std.testing.expectEqual(BrowserType.firefox, BrowserType.fromString("firefox").?);
    try std.testing.expectEqual(BrowserType.firefox, BrowserType.fromString("ff").?);
    try std.testing.expect(BrowserType.fromString("safari") == null);
}

test "Browser defaults to chrome type" {
    const b = Browser{
        .profile = "test",
        .port = 9322,
    };
    try std.testing.expectEqual(BrowserType.chrome, b.browser_type);
}

test "LaunchOptions defaults to chrome type" {
    const opts = LaunchOptions{
        .profile = "default",
    };
    try std.testing.expectEqual(BrowserType.chrome, opts.browser_type);
}

test "Firefox port range constants" {
    try std.testing.expect(firefox_port_range_start == 9800);
    try std.testing.expect(firefox_port_range_end == 9900);
    try std.testing.expect(firefox_port_range_start > port_range_end);
}

test "findFreePortInRangeFor returns port in correct range" {
    const chrome_port = try findFreePortInRangeFor(.chrome);
    try std.testing.expect(chrome_port >= port_range_start);
    try std.testing.expect(chrome_port < port_range_end);

    const ff_port = try findFreePortInRangeFor(.firefox);
    try std.testing.expect(ff_port >= firefox_port_range_start);
    try std.testing.expect(ff_port < firefox_port_range_end);
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

test "lookupPort returns null for nonexistent profile" {
    const allocator = std.testing.allocator;
    const result = try lookupPort(allocator, "nonexistent-profile-xyz");
    try std.testing.expect(result == null);
}

test "discover returns a slice" {
    const allocator = std.testing.allocator;
    const browsers = try discover(allocator);
    defer freeBrowsers(allocator, browsers);
    // Just verify it does not crash — may return 0 if no Chrome running
    _ = browsers.len;
}
