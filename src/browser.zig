///! Browser lifecycle management: find chromium binary, launch with flags,
///! discover running CDP-enabled browser instances.
///!
///! Discovery-first design: finds browsers by scanning processes for
///! --remote-debugging-port flags rather than tracking complex state.
const std = @import("std");
const mem = std.mem;
const fs = std.fs;

/// A discovered or launched browser instance.
pub const Browser = struct {
    /// Profile name (maps to user-data-dir).
    profile: []const u8,
    /// CDP debugging port.
    port: u16,
    /// OS process ID.
    pid: ?std.posix.pid_t = null,
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
pub fn findChromium(allocator: mem.Allocator) ![]const u8 {
    // 1. Check HIBROW_BROWSER env var
    if (std.process.getEnvVarOwned(allocator, "HIBROW_BROWSER")) |path| {
        return path;
    } else |_| {}

    // 2. Platform-specific search
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        for (chromium_search_paths_macos) |path| {
            if (fs.accessAbsolute(path, .{})) |_| {
                return try allocator.dupe(u8, path);
            } else |_| {}
        }
    } else if (builtin.os.tag == .linux) {
        _ = chromium_search_names_linux;
        // TODO: search PATH for these binaries
    }

    return error.ChromiumNotFound;
}

/// Launch a new browser instance with the given options.
pub fn launch(allocator: mem.Allocator, options: LaunchOptions) !Browser {
    _ = allocator;
    _ = options;
    // TODO: resolve chromium binary, build args, spawn child with setsid
    return error.NotImplemented;
}

// ---------------------------------------------------------------------------
// Process discovery
// ---------------------------------------------------------------------------

/// Discover running CDP-enabled browsers by scanning processes.
/// On macOS: parse `ps aux` output.
/// On Linux: scan /proc/{pid}/cmdline.
pub fn discover(allocator: mem.Allocator) ![]Browser {
    _ = allocator;
    // TODO: platform-specific process scanning
    return &[_]Browser{};
}

/// Verify a browser is responsive by hitting its CDP endpoint.
pub fn verify(allocator: mem.Allocator, port: u16) !bool {
    _ = allocator;
    _ = port;
    // TODO: HTTP GET http://127.0.0.1:{port}/json/version
    return false;
}

// ---------------------------------------------------------------------------
// Profile registry
// ---------------------------------------------------------------------------

/// Default profile registry path: ~/.hibrow/profiles.json
pub fn getProfileRegistryPath(allocator: mem.Allocator) ![]u8 {
    _ = allocator;
    // TODO: resolve home dir + .hibrow/profiles.json
    return error.NotImplemented;
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
    try std.testing.expectEqual(@as(?std.posix.pid_t, 12345), b.pid);
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
