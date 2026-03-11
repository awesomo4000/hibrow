///! Stable tab indexing: maps profile:N → CDP targetId.
///!
///! Each profile gets a monotonic counter. Tab indices never renumber —
///! if tab 2 is closed, index 2 is retired (not reused). The gateway
///! persists the mapping so tab references survive restarts.
///!
///! Parsing: "work:3" means profile "work", tab index 3.
///!          "work" alone means the active tab for profile "work".
const std = @import("std");
const mem = std.mem;

/// A parsed tab reference: profile name + optional tab index.
pub const TabRef = struct {
    profile: []const u8,
    /// null means "active tab" (no explicit index).
    tab: ?u32 = null,

    /// Format as "profile:N" or just "profile".
    pub fn format(self: TabRef, allocator: mem.Allocator) ![]u8 {
        if (self.tab) |t| {
            return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.profile, t });
        } else {
            return allocator.dupe(u8, self.profile);
        }
    }
};

/// Parse a tab reference string like "profile:N" or "profile".
pub fn parseTabRef(input: []const u8) !TabRef {
    if (mem.indexOfScalar(u8, input, ':')) |colon_pos| {
        const profile = input[0..colon_pos];
        const tab_str = input[colon_pos + 1 ..];
        if (profile.len == 0) return error.EmptyProfile;
        const tab = std.fmt.parseInt(u32, tab_str, 10) catch return error.InvalidTabIndex;
        return .{ .profile = profile, .tab = tab };
    } else {
        if (input.len == 0) return error.EmptyProfile;
        return .{ .profile = input };
    }
}

/// Per-profile tab mapping: monotonic index → CDP targetId.
pub const TabMap = struct {
    allocator: mem.Allocator,
    /// Next index to assign.
    next_index: u32 = 1,
    /// Map from tab index → CDP targetId.
    entries: std.AutoHashMap(u32, []const u8),

    pub fn init(allocator: mem.Allocator) TabMap {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TabMap) void {
        var it = self.entries.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.*);
        }
        self.entries.deinit();
    }

    /// Assign the next index to a targetId. Returns the new index.
    pub fn assign(self: *TabMap, target_id: []const u8) !u32 {
        const idx = self.next_index;
        self.next_index += 1;
        const owned = try self.allocator.dupe(u8, target_id);
        try self.entries.put(idx, owned);
        return idx;
    }

    /// Look up the targetId for a given tab index.
    pub fn lookup(self: *const TabMap, index: u32) ?[]const u8 {
        return self.entries.get(index);
    }

    /// Remove a tab (close). The index is never reused.
    pub fn remove(self: *TabMap, index: u32) void {
        if (self.entries.fetchRemove(index)) |entry| {
            self.allocator.free(entry.value);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseTabRef with index" {
    const ref = try parseTabRef("work:3");
    try std.testing.expectEqualStrings("work", ref.profile);
    try std.testing.expectEqual(@as(?u32, 3), ref.tab);
}

test "parseTabRef without index" {
    const ref = try parseTabRef("personal");
    try std.testing.expectEqualStrings("personal", ref.profile);
    try std.testing.expect(ref.tab == null);
}

test "parseTabRef rejects empty profile" {
    const result = parseTabRef("");
    try std.testing.expectError(error.EmptyProfile, result);
}

test "parseTabRef rejects empty profile with colon" {
    const result = parseTabRef(":5");
    try std.testing.expectError(error.EmptyProfile, result);
}

test "parseTabRef rejects invalid tab index" {
    const result = parseTabRef("work:abc");
    try std.testing.expectError(error.InvalidTabIndex, result);
}

test "TabMap assign and lookup" {
    const allocator = std.testing.allocator;
    var tm = TabMap.init(allocator);
    defer tm.deinit();

    const idx1 = try tm.assign("AAAA-BBBB-1111");
    const idx2 = try tm.assign("CCCC-DDDD-2222");

    try std.testing.expectEqual(@as(u32, 1), idx1);
    try std.testing.expectEqual(@as(u32, 2), idx2);

    try std.testing.expectEqualStrings("AAAA-BBBB-1111", tm.lookup(1).?);
    try std.testing.expectEqualStrings("CCCC-DDDD-2222", tm.lookup(2).?);
}

test "TabMap remove does not renumber" {
    const allocator = std.testing.allocator;
    var tm = TabMap.init(allocator);
    defer tm.deinit();

    _ = try tm.assign("target-1");
    _ = try tm.assign("target-2");
    _ = try tm.assign("target-3");

    // Remove tab 2
    tm.remove(2);

    // Tab 2 is gone, but 1 and 3 remain; next index is 4, not 3
    try std.testing.expect(tm.lookup(2) == null);
    try std.testing.expectEqualStrings("target-1", tm.lookup(1).?);
    try std.testing.expectEqualStrings("target-3", tm.lookup(3).?);

    const idx4 = try tm.assign("target-4");
    try std.testing.expectEqual(@as(u32, 4), idx4);
}
