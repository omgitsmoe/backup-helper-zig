const std = @import("std");
const testing = std.testing;

const glob = @import("glob");

pub const Matcher = struct {
    allow: [][]const u8,
    block: [][]const u8,

    pub fn isBlocked(self: *@This(), value: []const u8) bool {
        return glob.matchAny(self.block, value);
    }

    pub fn isMatch(self: *@This(), value: []const u8) bool {
        return !self.isBlocked(value) and glob.matchAny(self.allow, value);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.allow) |allow| {
            allocator.free(allow);
        }

        allocator.free(self.allow);

        for (self.block) |block| {
            allocator.free(block);
        }

        allocator.free(self.block);

        self.* = undefined;
    }
};

pub const MatcherBuilder = struct {
    allocator: std.mem.Allocator,
    allow_list: std.ArrayList([]const u8) = .empty,
    block_list: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
        };
    }

    /// Resulting `Matcher` takes ownership of the allocated
    /// slices and their contents.
    /// `Matcher.deinit` has to be called to free its memory.
    pub fn build(self: *@This()) !Matcher {
        const matcher = Matcher{
            .allow = try self.allow_list.toOwnedSlice(self.allocator),
            .block = try self.block_list.toOwnedSlice(self.allocator),
        };

        self.* = undefined;

        return matcher;
    }

    pub fn allow(self: *@This(), glob_pattern: []const u8) !void {
        const dupe = try self.allocator.dupe(u8, glob_pattern);
        try self.allow_list.append(self.allocator, dupe);
    }

    pub fn block(self: *@This(), glob_pattern: []const u8) !void {
        const dupe = try self.allocator.dupe(u8, glob_pattern);
        try self.block_list.append(self.allocator, dupe);
    }
};

test Matcher {
    var builder = MatcherBuilder.init(testing.allocator);
    try builder.allow("foo/**/*.zig");
    try builder.allow("**/*.txt");
    try builder.block("bar/**/*");
    try builder.block("**/*.go");
    try builder.block("foo/bar/*.zig");

    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.isBlocked("bar/foo/xer.zig"));
    try testing.expect(matcher.isBlocked("bar/xer.bin"));
    try testing.expect(matcher.isBlocked("foo.go"));
    try testing.expect(matcher.isBlocked("xer/foo.go"));
    try testing.expect(matcher.isBlocked("foo/bar/abc.zig"));
    try testing.expect(!matcher.isMatch("foo/bar/abc.zig"));

    try testing.expect(matcher.isMatch("foo/xer/abc.zig"));
    try testing.expect(matcher.isMatch("xer/file.txt"));
}
