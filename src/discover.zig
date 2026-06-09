const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;
const Matcher = @import("matcher.zig").Matcher;

pub const PredicateFn = *const fn (context: *anyopaque, entry: Dir.Walker.Entry) bool;

/// NOTE: the memory `relativePath` that the PredicateFn receives will only
///       remain valid for the duration of the PredicateFn call.
pub const FilteredWalker = struct {
    predicateFn: ?PredicateFn,
    walker: Dir.SelectiveWalker,

    pub const Error = Dir.OpenError || Dir.StatFileError || std.mem.Allocator.Error;
    const Self = @This();

    pub const Status = enum {
        ok,
        ignored_predicate,
        ignored_special_file,
    };

    pub const Entry = struct {
        inner: Dir.Walker.Entry,
        status: Status,
    };

    /// NOTE: `root` must have been opened with `OpenOptions.iterate` set to true
    pub fn init(
        allocator: std.mem.Allocator,
        root: Dir,
        predicate: ?PredicateFn,
    ) Error!FilteredWalker {
        const walker = try Dir.walkSelectively(root, allocator);
        return .{
            .predicateFn = predicate,
            .walker = walker,
        };
    }

    pub fn deinit(self: *Self) void {
        self.walker.deinit();
    }

    /// `userdata` is passed to the `Self.predicateFn`
    pub fn next(self: *Self, io: std.Io, userdata: *anyopaque) Error!?Entry {
        while (try self.walker.next(io)) |entry| {
            // NOTE we will only visit regular files, but notify
            //      about skipped files!
            //
            //      options:
            //      - skip non-regular files
            //        - scorch: skips non-regular files
            //        - `find ./foo/ -type f -print0 | xargs -0 sha1sum`
            //          also skips non-regular files
            //      - follow the symlink for files, record error for faulty links
            //        - is confusing, since we don't follow links to directories
            //          and doing that would be a completely different rabbit hole
            //        - also most tools don't follow symlinks when copying by
            //          default, e.g. rsync BUT cp does follow BUT only
            //          in file, not directory-mode :/
            //      - hash the contents of a symlink
            //        - would lead to confusing results for links that point
            //          to the same path, but different contents depending
            //          on the environment
            //      - record the symlink itself as a special entry
            //        - same drawback as hashing the link contents

            const include = if (self.predicateFn) |predicateFn|
                predicateFn(userdata, entry)
            else
                true;

            if (include) {
                if (entry.kind == .directory) {
                    try self.walker.enter(io, entry);
                    continue;
                }

                if (entry.kind == .file) {
                    return .{ .inner = entry, .status = .ok };
                }

                return .{ .inner = entry, .status = .ignored_special_file };
            } else {
                return .{ .inner = entry, .status = .ignored_predicate };
            }
        }

        return null;
    }
};

pub const MatcherWalker = struct {
    inner: FilteredWalker,
    matcher: *const Matcher,

    /// NOTE: `root` must have been opened with `OpenOptions.iterate` set to true
    pub fn init(
        allocator: std.mem.Allocator,
        root: Dir,
        matcher: *const Matcher,
    ) FilteredWalker.Error!MatcherWalker {
        return .{
            .inner = try .init(allocator, root, &MatcherWalker.pred),
            .matcher = matcher,
        };
    }

    fn pred(userdata: *anyopaque, entry: Dir.Walker.Entry) bool {
        const self: *const MatcherWalker = @ptrCast(@alignCast(userdata));
        return self.match(entry);
    }

    fn match(self: *const MatcherWalker, entry: Dir.Walker.Entry) bool {
        if (entry.kind == .directory) {
            if (self.matcher.isBlocked(entry.path)) {
                return false;
            }
        }

        return self.matcher.isMatch(entry.path);
    }

    pub fn deinit(self: *MatcherWalker) void {
        self.inner.deinit();
    }

    pub fn next(self: *MatcherWalker, io: std.Io) FilteredWalker.Error!?FilteredWalker.Entry {
        while (try self.inner.next(io, self)) |entry| {
            return entry;
        }

        return null;
    }
};

test "FilteredWalker iterates all files" {
    const helpers = @import("test_helpers.zig");
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
    });

    var walker = try FilteredWalker.init(
        testing.allocator,
        tmp.dir,
        null,
    );
    defer walker.deinit();

    var actual = std.ArrayList(struct { FilteredWalker.Status, []const u8 }).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e.@"1");
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io, &.{})) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.inner.path);
        try actual.append(testing.allocator, .{ entry.status, pathCopy });
    }

    // TODO order independence
    try helpers.expectEqualSlicesDeep(
        struct { FilteredWalker.Status, []const u8 },
        &[_]struct { FilteredWalker.Status, []const u8 }{
            .{ .ok, "bar/foo" },
            .{ .ok, "bar/xer/file.txt" },
            .{ .ok, "foo" },
        },
        actual.items,
    );
}

fn testPredicate(_: *anyopaque, entry: Dir.Walker.Entry) bool {
    if (entry.kind == .directory) {
        return std.mem.startsWith(u8, entry.basename, "bar") or
            std.mem.startsWith(u8, entry.basename, "xer");
    }

    return std.mem.endsWith(u8, entry.basename, "file.txt");
}

test "FilteredWalker respects include function" {
    const helpers = @import("test_helpers.zig");
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
        "xer/vid.mp4",
    });

    var walker = try FilteredWalker.init(
        testing.allocator,
        tmp.dir,
        &testPredicate,
    );
    defer walker.deinit();

    var actual = std.ArrayList(struct { FilteredWalker.Status, []const u8 }).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e.@"1");
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io, &.{})) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.inner.path);
        try actual.append(testing.allocator, .{ entry.status, pathCopy });
    }

    // TODO order independence
    try helpers.expectEqualSlicesDeep(
        struct { FilteredWalker.Status, []const u8 },
        &[_]struct { FilteredWalker.Status, []const u8 }{
            .{ .ignored_predicate, "bar/foo" },
            .{ .ok, "bar/xer/file.txt" },
            .{ .ignored_predicate, "foo" },
            .{ .ignored_predicate, "xer/vid.mp4" },
        },
        actual.items,
    );
}

test "FilteredWalker visits all symlinks, but does not follow them" {
    const helpers = @import("test_helpers.zig");
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "regular-file",
        "regular-dir/file",
    });
    try tmp.dir.symLink(io, "regular-dir/file", "link-file", .{});
    try tmp.dir.symLink(
        io,
        "regular-dir",
        "link-dir",
        .{ .is_directory = true },
    );

    var walker = try FilteredWalker.init(
        testing.allocator,
        tmp.dir,
        null,
    );
    defer walker.deinit();

    var actual = std.ArrayList(struct { FilteredWalker.Status, []const u8 }).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e.@"1");
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io, &.{})) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.inner.path);
        try actual.append(testing.allocator, .{ entry.status, pathCopy });
    }

    // TODO order independence
    try helpers.expectEqualSlicesDeep(
        struct { FilteredWalker.Status, []const u8 },
        &[_]struct { FilteredWalker.Status, []const u8 }{
            .{ .ignored_special_file, "link-dir" },
            .{ .ignored_special_file, "link-file" },
            .{ .ok, "regular-dir/file" },
            .{ .ok, "regular-file" },
        },
        actual.items,
    );
}

test "FilteredWalker handles invalid symlinks" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.symLink(io, "target/does/not/exist", "link-file", .{});

    var walker = try FilteredWalker.init(
        testing.allocator,
        tmp.dir,
        null,
    );
    defer walker.deinit();

    while (try walker.next(io, &.{})) |_| {}
}

test "MatcherWalker" {
    const helpers = @import("test_helpers.zig");
    const MatcherBuilder = @import("matcher.zig").MatcherBuilder;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
    });

    var builder = MatcherBuilder.init(testing.allocator);
    try builder.allow("**/*.txt");
    try builder.allow("*/foo");
    try builder.allow("bar/**");
    try builder.block("bar/xer/**/*");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    var walker = try MatcherWalker.init(
        testing.allocator,
        tmp.dir,
        &matcher,
    );
    defer walker.deinit();

    var actual = std.ArrayList(struct { FilteredWalker.Status, []const u8 }).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e.@"1");
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io)) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.inner.path);
        try actual.append(testing.allocator, .{ entry.status, pathCopy });
    }

    // TODO order independence
    try helpers.expectEqualSlicesDeep(
        struct { FilteredWalker.Status, []const u8 },
        &[_]struct { FilteredWalker.Status, []const u8 }{
            .{ .ok, "bar/foo" },
            .{ .ignored_predicate, "bar/xer/file.txt" },
            .{ .ignored_predicate, "foo" },
        },
        actual.items,
    );
}
