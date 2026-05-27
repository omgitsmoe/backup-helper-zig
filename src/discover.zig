const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;

pub const PredicateFn = *const fn (entry: Dir.Walker.Entry) bool;

/// NOTE: the memory `relativePath` that the PredicateFn receives will only
///       remain valid for the duration of the PredicateFn call.
/// NOTE: skips symlinks to directories
pub const FilteredWalker = struct {
    predicateFn: ?PredicateFn,
    walker: Dir.SelectiveWalker,

    pub const Error = Dir.OpenError || Dir.StatFileError || std.mem.Allocator.Error;
    const Self = @This();

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

    pub fn next(self: *Self, io: std.Io) Error!?Dir.Walker.Entry {
        while (try self.walker.next(io)) |entry| {
            if (entry.kind == .sym_link) {
                const stat = entry.dir.statFile(io, entry.basename, .{
                    .follow_symlinks = true,
                });

                if (stat) |value| {
                    if (value.kind == .directory) {
                        // skip symlinks to directories
                        continue;
                    }
                } else |err| {
                    // TODO better handling
                    if (err == .FileNotFound) {
                        std.debug.print(
                            "WARN skipped faulty symlink at {s}\n",
                            .{entry.path},
                        );

                        continue;
                    }
                    if (err == .SymLinkLoop) {
                        std.debug.print(
                            "WARN skipped symlink loop at {s}\n",
                            .{entry.path},
                        );

                        continue;
                    }

                    return err;
                }
            }

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

test "FilteredWalker skips symlinks to directories" {
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
        "link-file",
        "regular-dir/file",
        "regular-file",
    }, actual.items);
}

test "FilteredWalker error on symlink not found" {
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

    const got = walker.next(io);
    try testing.expectEqual(Dir.StatFileError.FileNotFound, got);
}
