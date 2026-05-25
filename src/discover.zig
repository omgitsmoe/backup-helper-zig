const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;

pub const PredicateFn = *const fn (entry: Dir.Walker.Entry) bool;

/// NOTE: the memory `relativePath` that the PredicateFn receives will only
///       remain valid for the duration of the PredicateFn call.
pub const FilteredWalker = struct {
    predicateFn: ?PredicateFn,
    walker: Dir.SelectiveWalker,
    root: Dir,
    arena: std.heap.ArenaAllocator,

    pub const Error = error{
        RootMustBeAbsolute,
    } || Dir.OpenError || std.mem.Allocator.Error;
    const Self = @This();

    /// NOTE: `root` must have been opened with `OpenOptions.iterate` set to true
    pub fn init(
        allocator: std.mem.Allocator,
        root: Dir,
        predicate: ?PredicateFn,
    ) Error!FilteredWalker {
        const arena = std.heap.ArenaAllocator.init(allocator);
        const walker = try Dir.walkSelectively(root, allocator);
        return .{
            .predicateFn = predicate,
            .walker = walker,
            .root = root,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        self.walker.deinit();
    }

    pub fn next(self: *Self, io: std.Io) Error!?Dir.Walker.Entry {
        while (try self.walker.next(io)) |entry| {
            // TODO resolve symlinks for files
            const include = if (self.predicateFn) |predicateFn|
                predicateFn(entry)
            else
                true;

            if (include) {
                if (entry.kind == .directory) {
                    try self.walker.enter(io, entry);
                    continue;
                }

                return entry;
            }
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

    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e);
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io)) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.path);
        try actual.append(testing.allocator, pathCopy);
    }

    // TODO order independence
    try helpers.expectEqualStringSlices(&[_][]const u8{
        "bar/foo",
        "bar/xer/file.txt",
        "foo",
    }, actual.items);
}

fn testPredicate(entry: Dir.Walker.Entry) bool {
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

    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |e| {
            testing.allocator.free(e);
        }
        actual.deinit(testing.allocator);
    }

    while (try walker.next(io)) |entry| {
        const pathCopy = try testing.allocator.dupe(u8, entry.path);
        try actual.append(testing.allocator, pathCopy);
    }

    try helpers.expectEqualStringSlices(&[_][]const u8{
        "bar/xer/file.txt",
    }, actual.items);
}
