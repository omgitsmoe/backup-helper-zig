const std = @import("std");
const testing = std.testing;

const zlob = @import("zlob");

const ZlobFlags = zlob.ZlobFlags.recommended();

pub const PathMatcher = struct {
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

pub const PathMatcherBuilder = struct {
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
    pub fn build(self: *@This()) !PathMatcher {
        const matcher = PathMatcher{
            .allow = try self.allow_list.toOwnedSlice(self.allocator),
            .block = try self.block_list.toOwnedSlice(self.allocator),
        };

        self.* = undefined;

        return matcher;
    }

    pub fn allow(self: *@This(), glob_pattern: []const u8) !void {
        const compiled = try zlob.compilePattern(
            self.allocator,
            trimTrailingSeparator(glob_pattern),
            ZlobFlags,
        );
        try self.allow_list.append(self.allocator, compiled);
    }

    pub fn block(self: *@This(), glob_pattern: []const u8) !void {
        const compiled = try zlob.compilePattern(
            self.allocator,
            trimTrailingSeparator(glob_pattern),
            ZlobFlags,
        );
        try self.block_list.append(self.allocator, compiled);
    }

    // zlob doesn't match pattern foo/bar/ on directory foo/bar,
    // which would be confusing, so trim here
    fn trimTrailingSeparator(pattern: []const u8) []const u8 {
        const separators = if (comptime std.fs.path.sep == '\\')
            &[_]u8{ '/', '\\' }
        else
            &[_]u8{'/'};
        return std.mem.trimEnd(u8, pattern, separators);
    }
};

test PathMatcher {
    var builder = PathMatcherBuilder.init(testing.allocator);
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

test "trailing slash in patterns is trimmed" {
    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.block("foo/bar/");
    try builder.allow("**/*.txt");

    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    // isBlocked matches directory path (prevents walker entry)
    try testing.expect(matcher.isBlocked("foo/bar"));
    // isMatch still works for files at root
    try testing.expect(matcher.isMatch("a.txt"));
    try testing.expect(!matcher.isMatch("other.bin"));

    // Same result without trailing slash
    var builder2 = PathMatcherBuilder.init(testing.allocator);
    try builder2.block("foo/bar");
    try builder2.allow("**/*.txt");

    var matcher2 = try builder2.build();
    defer matcher2.deinit(testing.allocator);

    try testing.expect(matcher2.isBlocked("foo/bar"));
    try testing.expect(matcher2.isMatch("a.txt"));
    try testing.expect(!matcher2.isMatch("other.bin"));
}

test "empty matcher matches everything" {
    var builder = PathMatcherBuilder.init(testing.allocator);

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

test "PathMatcher.deinit works with copy" {
    const foo = &[_]struct {
        matcher: PathMatcher,
    }{
        .{
            .matcher = blk: {
                var builder = PathMatcherBuilder.init(testing.allocator);
                try builder.allow("foo/**/*.zig");
                try builder.allow("**/*.txt");
                try builder.block("bar/**/*");
                try builder.block("**/*.go");
                try builder.block("foo/bar/*.zig");

                const matcher = try builder.build();
                break :blk matcher;
            },
        },
    };

    for (foo) |tt| {
        var copy = @constCast(&tt.matcher);
        defer copy.deinit(testing.allocator);

        try testing.expect(copy.isBlocked("bar/foo/xer.zig"));
        try testing.expect(copy.isBlocked("bar/xer.bin"));
        try testing.expect(copy.isBlocked("foo.go"));
        try testing.expect(copy.isBlocked("xer/foo.go"));
        try testing.expect(copy.isBlocked("foo/bar/abc.zig"));
        try testing.expect(!copy.isMatch("foo/bar/abc.zig"));

        try testing.expect(copy.isMatch("foo/xer/abc.zig"));
        try testing.expect(copy.isMatch("xer/file.txt"));
    }
}
