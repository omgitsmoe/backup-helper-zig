const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;

const PathMatcher = @import("matcher.zig").PathMatcher;
const prog = @import("progress.zig");
const PathStore = @import("store.zig").PathStore;

pub const PredicateFn = *const fn (context: *anyopaque, entry: Dir.Walker.Entry) bool;

/// NOTE: the memory `relativePath` that the PredicateFn receives will only
///       remain valid for the duration of the PredicateFn call.
pub const FilteredWalker = struct {
    predicateFn: ?PredicateFn,
    walker: Dir.SelectiveWalker,
    max_depth: u32,

    pub const Error = Dir.OpenError || Dir.StatFileError || std.mem.Allocator.Error;
    const Self = @This();

    pub const Status = enum {
        ok,
        ignored_predicate,
        ignored_special_file,
        ignored_max_depth,
    };

    pub const Entry = struct {
        inner: Dir.Walker.Entry,
        status: Status,
    };

    /// NOTE: `root` must have been opened with `OpenOptions.iterate` set to true
    pub fn init(
        allocator: std.mem.Allocator,
        root: Dir,
        /// 0 no limit, 1 only direct children of root, ...
        max_depth: u32,
        predicate: ?PredicateFn,
    ) Error!FilteredWalker {
        const walker = try Dir.walkSelectively(root, allocator);
        return .{
            .predicateFn = predicate,
            .walker = walker,
            .max_depth = max_depth,
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
                    if (entry.depth() == self.max_depth) {
                        return .{ .inner = entry, .status = .ignored_max_depth };
                    }

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
    matcher: *const PathMatcher,

    /// NOTE: `root` must have been opened with `OpenOptions.iterate` set to true
    pub fn init(
        allocator: std.mem.Allocator,
        root: Dir,
        /// 0 no limit, 1 only direct children of root, ...
        max_depth: u32,
        matcher: *const PathMatcher,
    ) FilteredWalker.Error!MatcherWalker {
        return .{
            .inner = try .init(allocator, root, max_depth, &MatcherWalker.pred),
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

            return true;
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

pub const DiscoverHashFilesOptions = struct {
    root: []const u8,
    max_depth: ?u32,
    matcher: *const PathMatcher,
};

pub const DiscoverHashFilesResult = struct {
    arena: std.heap.ArenaAllocator,
    hash_files: [][]const u8,
};

pub fn discoverHashFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverHashFilesOptions,
    progress: ?prog.MostCurrentProgressFn,
    context: *anyopaque,
) !DiscoverHashFilesResult {
    // there is openDirAbsolute, but openDir also supports an absolute
    // path, openDirAbsolute just dispatches to openDir(.cwd(), ...)
    var root_dir = try Dir.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root_dir.close(io);

    // NOTE: our max_depth is 0 for direct children, whereas Dir.Entry
    //       and our wrappers use 1 for direct children of root
    const dir_entry_max_depth = if (options.max_depth) |depth| depth + 1 else 0;
    var iter = try MatcherWalker.init(
        allocator,
        root_dir,
        dir_entry_max_depth,
        options.matcher,
    );
    defer iter.deinit();

    const prefix = try std.fs.path.resolve(allocator, &[_][]const u8{
        options.root,
    });
    defer allocator.free(prefix);

    var arena = std.heap.ArenaAllocator.init(allocator);
    const alloc = arena.allocator();
    var result: std.ArrayList([]const u8) = .empty;

    // TODO how to handle permission errors etc?
    while (try iter.next(io)) |entry| {
        switch (entry.status) {
            .ok => {},
            .ignored_predicate, .ignored_special_file, .ignored_max_depth => {
                if (progress) |progress_fn| {
                    try progress_fn(.{
                        .ignored_path = entry.inner.path,
                    }, context);
                }

                continue;
            },
        }

        const ext = path.extension(entry.inner.basename);
        if (!isHashFile(ext)) {
            continue;
        }

        const abs = try path.join(alloc, &[_][]const u8{
            prefix,
            entry.inner.path,
        });
        try result.append(alloc, abs);

        if (progress) |progress_fn| {
            try progress_fn(.{
                .found_file = entry.inner.path,
            }, context);
        }
    }

    return .{
        .arena = arena,
        .hash_files = try result.toOwnedSlice(alloc),
    };
}

fn isHashFile(ext: []const u8) bool {
    for (hash_file_extensions) |hash_ext| {
        if (std.mem.eql(u8, ext, hash_ext)) {
            return true;
        }
    }

    return false;
}

// TODO add support for the rest
const hash_file_extensions = [_][]const u8{
    ".cshd",
    ".md5",
    // ".sha1",
    // ".sha224",
    ".sha256",
    // ".sha384",
    ".sha512",
    // ".sha3_224",
    ".sha3_256",
    // ".sha3_384",
    ".sha3_512",
    // ".shake_128",
    // ".shake_256",
    // ".blake2b",
    // ".blake2s",
};

pub const DiscoverFilesOptions = struct {
    root: []const u8,
    matcher: *const PathMatcher,
};

/// Returns a list of discovered file paths to hash, where each of those
/// is a slice pointing into the passed `store`.
/// Only the returned slice was allocated with `allocator` and the
/// caller takes ownership.
pub fn discoverFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *PathStore,
    options: DiscoverFilesOptions,
    progress: ?prog.IncrementalProgressFn,
    context: *anyopaque,
) ![][]const u8 {
    // there is openDirAbsolute, but openDir also supports an absolute
    // path, openDirAbsolute just dispatches to openDir(.cwd(), ...)
    var root_dir = try Dir.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root_dir.close(io);

    // NOTE: our max_depth is 0 for direct children, whereas Dir.Entry
    //       and our wrappers use 1 for direct children of root
    var iter = try MatcherWalker.init(
        allocator,
        root_dir,
        0,
        options.matcher,
    );
    defer iter.deinit();

    const prefix = try std.fs.path.resolve(allocator, &[_][]const u8{
        options.root,
    });
    defer allocator.free(prefix);

    var result: std.ArrayList([]const u8) = .empty;

    var files_found: usize = 0;
    var files_ignored: usize = 0;
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&path_buf);
    const fba = fixed.allocator();
    // TODO how to handle permission errors etc?
    while (try iter.next(io)) |entry| : (fixed.reset()) {
        switch (entry.status) {
            .ok => {},
            .ignored_predicate, .ignored_special_file, .ignored_max_depth => {
                if (progress) |progress_fn| {
                    try progress_fn(.{
                        .discover_files_ignored = entry.inner.path,
                    }, context);
                }

                files_ignored += 1;

                continue;
            },
        }

        const abs = try path.join(fba, &[_][]const u8{
            prefix,
            entry.inner.path,
        });
        const stored = try store.store(abs);
        try result.append(allocator, stored);

        files_found += 1;
        if (progress) |progress_fn| {
            try progress_fn(.{
                .discover_files_found = files_found,
            }, context);
        }
    }

    if (progress) |progress_fn| {
        try progress_fn(.{
            .discover_files_done = .{
                .files = files_found,
                .ignored = files_ignored,
            },
        }, context);
    }

    return try result.toOwnedSlice(allocator);
}

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
        0,
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
        0,
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
        0,
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
        0,
        null,
    );
    defer walker.deinit();

    while (try walker.next(io, &.{})) |_| {}
}

test "MatcherWalker" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*.txt");
    try builder.allow("*/foo");
    try builder.allow("bar/**");
    try builder.block("bar/xer/**/*");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    var walker = try MatcherWalker.init(
        testing.allocator,
        tmp.dir,
        0,
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

test "MatcherWalker enters directory even though no explict allow match" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*.txt");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    var walker = try MatcherWalker.init(
        testing.allocator,
        tmp.dir,
        0,
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
            .{ .ignored_predicate, "bar/foo" },
            .{ .ok, "bar/xer/file.txt" },
            .{ .ignored_predicate, "foo" },
        },
        actual.items,
    );
}

test "MatcherWalker respects max_depth" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "bar/xer/file.txt",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    var walker = try MatcherWalker.init(
        testing.allocator,
        tmp.dir,
        2,
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
            .{ .ignored_max_depth, "bar/xer" },
            .{ .ok, "foo" },
        },
        actual.items,
    );
}

test "discoverHashFiles max_depth" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = helpers.tmpDirWithPath(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "file.md5",
        "baz.cshd",
        "bar/foo",
        "bar/file.sha256",
        "bar/xer/file.txt",
        "bar/xer/baz.sha512",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    const CbCapture = helpers.CallbackCapture(prog.MostCurrentProgress);
    var actual_callbacks: CbCapture = .init(testing.allocator);
    defer actual_callbacks.deinit();

    const actual = try discoverHashFiles(
        testing.allocator,
        testing.io,
        .{
            .matcher = &matcher,
            .max_depth = 1,
            .root = tmp.absolute_path,
        },
        &CbCapture.cb,
        &actual_callbacks,
    );
    defer actual.arena.deinit();

    const expected_relative = &[_][]const u8{
        "bar/file.sha256",
        "baz.cshd",
        "file.md5",
    };
    var expected: std.ArrayList([]const u8) = .empty;
    for (expected_relative) |rel| {
        const abs = try path.join(
            testing.allocator,
            &[_][]const u8{ tmp.absolute_path, rel },
        );

        try expected.append(testing.allocator, abs);
    }
    defer {
        for (expected.items) |s| {
            testing.allocator.free(s);
        }
        expected.deinit(testing.allocator);
    }

    // TODO order independence
    try helpers.expectEqualStringSlices(
        expected.items,
        actual.hash_files,
    );

    var test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer test_arena.deinit();

    try helpers.expectEqualSlicesDeep(
        prog.MostCurrentProgress,
        &[_]prog.MostCurrentProgress{
            .{ .found_file = "bar/file.sha256" },
            .{ .ignored_path = "bar/xer" },
            .{ .found_file = "baz.cshd" },
            .{ .found_file = "file.md5" },
        },
        actual_callbacks.captures.items,
    );
}

test "discoverHashFiles matcher" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = helpers.tmpDirWithPath(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.tmp.dir, &[_][]const u8{
        "foo",
        "bar/foo",
        "file.md5",
        "baz.cshd",
        "bar/file.sha256",
        "bar/xer/file.txt",
        "bar/xer/baz.sha512",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*.sha*");
    try builder.block("**/*.sha256");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    const CbCapture = helpers.CallbackCapture(prog.MostCurrentProgress);
    var actual_callbacks: CbCapture = .init(testing.allocator);
    defer actual_callbacks.deinit();

    const actual = try discoverHashFiles(
        testing.allocator,
        testing.io,
        .{
            .matcher = &matcher,
            .max_depth = null,
            .root = tmp.absolute_path,
        },
        &CbCapture.cb,
        &actual_callbacks,
    );
    defer actual.arena.deinit();

    const expected_relative = &[_][]const u8{
        "bar/xer/baz.sha512",
    };
    var expected: std.ArrayList([]const u8) = .empty;
    for (expected_relative) |rel| {
        const abs = try path.join(
            testing.allocator,
            &[_][]const u8{ tmp.absolute_path, rel },
        );

        try expected.append(testing.allocator, abs);
    }
    defer {
        for (expected.items) |s| {
            testing.allocator.free(s);
        }
        expected.deinit(testing.allocator);
    }

    // TODO order independence
    try helpers.expectEqualStringSlices(
        expected.items,
        actual.hash_files,
    );

    var test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer test_arena.deinit();

    try helpers.expectEqualSlicesDeep(
        prog.MostCurrentProgress,
        &[_]prog.MostCurrentProgress{
            .{ .ignored_path = "bar/file.sha256" },
            .{ .ignored_path = "bar/foo" },
            .{ .found_file = "bar/xer/baz.sha512" },
            .{ .ignored_path = "bar/xer/file.txt" },
            .{ .ignored_path = "baz.cshd" },
            .{ .ignored_path = "file.md5" },
            .{ .ignored_path = "foo" },
        },
        actual_callbacks.captures.items,
    );
}

test "discoverFiles" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;
    const io = testing.io;

    var tmp = helpers.tmpDirWithPath(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createFilesFromList(io, tmp.tmp.dir, &[_][]const u8{
        "foo.txt",
        "foo.bin",
        "bar/foo.bin",
        "bar/baz.txt",
        "bar/xer/file.txt",
    });

    var builder = PathMatcherBuilder.init(testing.allocator);
    try builder.allow("**/*.txt");
    try builder.block("bar/xer/**");
    var matcher = try builder.build();
    defer matcher.deinit(testing.allocator);

    var store = PathStore.init(testing.allocator, std.Io.Dir.max_path_bytes);
    defer store.deinit();

    const CbCapture = helpers.CallbackCapture(prog.IncrementalProgress);
    var actual_callbacks: CbCapture = .init(testing.allocator);
    defer actual_callbacks.deinit();

    const actual = try discoverFiles(
        testing.allocator,
        testing.io,
        &store,
        .{
            .matcher = &matcher,
            .root = tmp.absolute_path,
        },
        &CbCapture.cb,
        &actual_callbacks,
    );
    defer testing.allocator.free(actual);

    const expected_relative = &[_][]const u8{
        "bar/baz.txt",
        "foo.txt",
    };
    var expected: std.ArrayList([]const u8) = .empty;
    for (expected_relative) |rel| {
        const abs = try path.join(
            testing.allocator,
            &[_][]const u8{ tmp.absolute_path, rel },
        );

        try expected.append(testing.allocator, abs);
    }
    defer {
        for (expected.items) |s| {
            testing.allocator.free(s);
        }
        expected.deinit(testing.allocator);
    }

    // TODO order independence
    try helpers.expectEqualStringSlices(
        expected.items,
        actual,
    );

    var test_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer test_arena.deinit();

    try helpers.expectEqualSlicesDeep(
        prog.IncrementalProgress,
        &[_]prog.IncrementalProgress{
            .{ .discover_files_found = 1 },
            .{ .discover_files_ignored = "bar/foo.bin" },
            .{ .discover_files_ignored = "bar/xer" },
            .{ .discover_files_ignored = "foo.bin" },
            .{ .discover_files_found = 2 },
            .{ .discover_files_done = .{ .files = 2, .ignored = 3 } },
        },
        actual_callbacks.captures.items,
    );

    try testing.expectEqual(2, store.len());
}
