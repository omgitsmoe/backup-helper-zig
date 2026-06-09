const std = @import("std");
const testing = std.testing;

const zlob = @import("zlob");

const ZlobFlags = zlob.ZlobFlags.recommended();

pub const Matcher = struct {
    allow: []zlob.CompiledPattern,
    block: []zlob.CompiledPattern,

    pub fn isBlocked(self: *const @This(), value: []const u8) bool {
        for (self.block) |block| {
            if (block.matches(value, ZlobFlags)) {
                return true;
            }
        }

        return false;
    }

    pub fn isMatch(self: *const @This(), value: []const u8) bool {
        if (self.isBlocked(value)) {
            return false;
        }

        if (self.allow.len == 0) {
            return true;
        }

        for (self.allow) |allow| {
            if (allow.matches(value, ZlobFlags)) {
                return true;
            }
        }

        return false;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.allow) |*allow| {
            allow.deinit();
        }

        allocator.free(self.allow);

        for (self.block) |*block| {
            block.deinit();
        }

        allocator.free(self.block);

        self.* = undefined;
    }
};

pub const MatcherBuilder = struct {
    allocator: std.mem.Allocator,
    allow_list: std.ArrayList(zlob.CompiledPattern) = .empty,
    block_list: std.ArrayList(zlob.CompiledPattern) = .empty,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
        };
    }

    /// Resulting `Matcher` takes ownership of the allocated
    /// slices and their contents.
    /// `Matcher.deinit` has to be called with the same allocator
    /// to free its memory.
    pub fn build(self: *@This()) !Matcher {
        const matcher = Matcher{
            .allow = try self.allow_list.toOwnedSlice(self.allocator),
            .block = try self.block_list.toOwnedSlice(self.allocator),
        };

        self.* = undefined;

        return matcher;
    }

    pub fn allow(self: *@This(), glob_pattern: []const u8) !void {
        const compiled = try zlob.compilePattern(
            self.allocator,
            glob_pattern,
            ZlobFlags,
        );
        try self.allow_list.append(self.allocator, compiled);
    }

    pub fn block(self: *@This(), glob_pattern: []const u8) !void {
        const compiled = try zlob.compilePattern(
            self.allocator,
            glob_pattern,
            ZlobFlags,
        );
        try self.block_list.append(self.allocator, compiled);
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

test "empty matcher matches everything" {
    var builder = MatcherBuilder.init(testing.allocator);

    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    try testing.expect(!matcher.isBlocked("bar/foo/xer.zig"));
    try testing.expect(!matcher.isBlocked("bar/xer.bin"));
    try testing.expect(!matcher.isBlocked("foo.go"));
    try testing.expect(!matcher.isBlocked("xer/foo.go"));
    try testing.expect(!matcher.isBlocked("foo/bar/abc.zig"));

    try testing.expect(matcher.isMatch("foo/bar/abc.zig"));
    try testing.expect(matcher.isMatch("foo/xer/abc.zig"));
    try testing.expect(matcher.isMatch("xer/file.txt"));
}
