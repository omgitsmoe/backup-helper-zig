const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const PathStore = @import("store.zig").PathStore;
const Collection = @import("collection.zig").Collection;
const PathMatcher = @import("matcher.zig").PathMatcher;
const defaultHashFileName = @import("checksum_helper.zig").defaultHashFileName;
const discover = @import("discover.zig");
const prog = @import("progress.zig");

const ChecksumHelperOptions = @import("checksum_helper.zig").Options;

pub const Options = struct {
    root: []const u8,
    discover_hash_files_depth: ?u32,
    most_current_filter_deleted: bool,
    hash_files_matcher: PathMatcher,

    pub fn from(root: []const u8, options: ChecksumHelperOptions) Options {
        return .{
            .root = root,
            .discover_hash_files_depth = options.discover_hash_files_depth,
            .most_current_filter_deleted = options.most_current_filter_deleted,
            .hash_files_matcher = options.hash_files_matcher,
        };
    }
};

pub fn buildMostCurrent(
    io: Io,
    allocator: std.mem.Allocator,
    store: *PathStore,
    options: Options,
    progress: ?prog.MostCurrentProgressFn,
    context: *anyopaque,
) !Collection {
    const discover_result = try discover.discoverHashFiles(
        allocator,
        io,
        .{
            .root = options.root,
            .max_depth = options.discover_hash_files_depth,
            .matcher = &options.hash_files_matcher,
        },
        progress,
        context,
    );
    defer discover_result.arena.deinit();

    // Sort by ascending mtime so newer collections overwrite older entries during merge.
    try sortPathsByAscendingMTime(io, allocator, discover_result.hash_files);

    const name = try defaultHashFileName(
        io,
        allocator,
        options.root,
        "most_current",
        "",
    );
    defer allocator.free(name);

    var most_current = try Collection.init(allocator, options.root, name);
    errdefer most_current.deinit();

    for (discover_result.hash_files) |hash_file_path| {
        if (progress) |progress_fn| {
            try progress_fn(.{ .merge_hash_file = hash_file_path }, context);
        }

        // TODO catch error and inform via callback instead of aborting
        var hash_file = try Collection.fromDisk(io, allocator, store, hash_file_path);
        defer hash_file.deinit();
        // NOTE: merge will always keep hash_file's entries, since
        //       most_current.mtime is null
        try most_current.merge(hash_file);
    }

    if (options.most_current_filter_deleted) {
        try most_current.filter_missing(io);
    }

    return most_current;
}

fn sortPathsByAscendingMTime(
    io: Io,
    allocator: std.mem.Allocator,
    paths: [][]const u8,
) (error{OutOfMemory} || Io.Dir.StatFileError)!void {
    var mtimes = try allocator.alloc(Io.Timestamp, paths.len);
    defer allocator.free(mtimes);

    for (paths, 0..) |hash_file_path, i| {
        const st = try Io.Dir.cwd().statFile(
            io,
            hash_file_path,
            .{ .follow_symlinks = true },
        );
        mtimes[i] = st.mtime;
    }

    const indices = try allocator.alloc(usize, paths.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;

    std.sort.pdq(usize, indices, mtimes, struct {
        fn lessThan(ctx_mtimes: []Io.Timestamp, a: usize, b: usize) bool {
            return ctx_mtimes[a].durationTo(ctx_mtimes[b]).nanoseconds > 0;
        }
    }.lessThan);

    const reordered = try allocator.alloc([]const u8, paths.len);
    defer allocator.free(reordered);
    for (indices, 0..) |idx, i| {
        reordered[i] = paths[idx];
    }

    @memmove(paths, reordered);
}

test "buildMostCurrent" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;

    const empty_matcher = PathMatcher{ .allow = &.{}, .block = &.{} };
    const tests = &[_]struct {
        name: []const u8,
        discover_hash_files_depth: ?u32,
        filter_deleted: bool,
        hash_files_matcher: PathMatcher,
        test_files: []const helpers.TestFile,
        expected: []const u8,
        expected_error: ?anyerror,
    }{
        .{
            .name = "empty dir",
            .discover_hash_files_depth = null,
            .filter_deleted = false,
            .hash_files_matcher = empty_matcher,
            .test_files = &.{},
            .expected = "",
            .expected_error = null,
        },
        .{
            .name = "all",
            .discover_hash_files_depth = null,
            .filter_deleted = false,
            .hash_files_matcher = empty_matcher,
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content =
                    \\# version 1
                    \\1337.00133,42069,sha512,deadbeef abc.txt
                    \\33779,2233,md5,abababab foo/bar/file.bin
                    \\3500.25,888,sha256,5577 foo/data/vid.mp4
                    \\15999.50001,0,sha256,1111 empty.dat
                    \\60000.6,2048,sha256,8888 nested/dir/sub/deep.bin
                    \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
                    \\10000.0,64,md5,3333 root.txt
                    \\
                    ,
                },
                .{
                    .relativePath = "file.md5",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
                    .content =
                    \\5577 foo/data/vid.mp4
                    \\1111 empty.dat
                    \\3344 root.txt
                    \\6666 tiny.flag
                    \\4444 deep/inside/file.log
                    \\
                    ,
                },
                .{
                    .relativePath = "foo/file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
                    .content =
                    \\# version 1
                    \\1133779,112233,md5,abababab bar/file.bin
                    \\112500.25,11777,sha256,5555 data/blob.bin
                    \\113500.25,11888,sha256,5577 data/vid.mp4
                    \\
                    ,
                },
                .{
                    .relativePath = "nested/dir/file.sha256",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .content =
                    \\2222 a.txt
                    \\8877 sub/deep.bin
                    \\
                    ,
                },
            },
            .expected =
            \\# version 1
            \\1337.00133,42069,sha512,deadbeef abc.txt
            \\,,md5,4444 deep/inside/file.log
            \\,,md5,1111 empty.dat
            \\1133779,112233,md5,abababab foo/bar/file.bin
            \\112500.25,11777,sha256,5555 foo/data/blob.bin
            \\113500.25,11888,sha256,5577 foo/data/vid.mp4
            \\,,sha256,2222 nested/dir/a.txt
            \\,,sha256,8877 nested/dir/sub/deep.bin
            \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
            \\,,md5,3344 root.txt
            \\,,md5,6666 tiny.flag
            \\
            ,
            .expected_error = null,
        },
        .{
            .name = "filter deleted",
            .discover_hash_files_depth = null,
            .filter_deleted = true,
            .hash_files_matcher = empty_matcher,
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content =
                    \\# version 1
                    \\1337.00133,42069,sha512,deadbeef abc.txt
                    \\33779,2233,md5,abababab foo/bar/file.bin
                    \\3500.25,888,sha256,5577 foo/data/vid.mp4
                    \\15999.50001,0,sha256,1111 empty.dat
                    \\60000.6,2048,sha256,8888 nested/dir/sub/deep.bin
                    \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
                    \\10000.0,64,md5,3333 root.txt
                    \\
                    ,
                },
                .{
                    .relativePath = "nested/dir/file.sha256",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .content =
                    \\2222 a.txt
                    \\8877 sub/deep.bin
                    \\
                    ,
                },
                .{ .relativePath = "abc.txt", .mtime = null, .content = "" },
                .{ .relativePath = "foo/bar/file.bin", .mtime = null, .content = "" },
                .{ .relativePath = "nested/dir/a.txt", .mtime = null, .content = "" },
                .{ .relativePath = "nested/dir/sub/foo.doc", .mtime = null, .content = "" },
            },
            .expected =
            \\# version 1
            \\1337.00133,42069,sha512,deadbeef abc.txt
            \\33779,2233,md5,abababab foo/bar/file.bin
            \\,,sha256,2222 nested/dir/a.txt
            \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
            \\
            ,
            .expected_error = null,
        },
        .{
            .name = "discover depth",
            .discover_hash_files_depth = 1,
            .filter_deleted = false,
            .hash_files_matcher = empty_matcher,
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content =
                    \\# version 1
                    \\1337.00133,42069,sha512,deadbeef abc.txt
                    \\33779,2233,md5,abababab foo/bar/file.bin
                    \\3500.25,888,sha256,5577 foo/data/vid.mp4
                    \\15999.50001,0,sha256,1111 empty.dat
                    \\60000,2048,sha256,8888 nested/dir/sub/deep.bin
                    \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
                    \\10000.0,64,md5,3333 root.txt
                    \\
                    ,
                },
                .{
                    .relativePath = "file.md5",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
                    .content =
                    \\5577 foo/data/vid.mp4
                    \\1111 empty.dat
                    \\3344 root.txt
                    \\6666 tiny.flag
                    \\4444 deep/inside/file.log
                    \\
                    ,
                },
                .{
                    .relativePath = "foo/file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
                    .content =
                    \\# version 1
                    \\1133779,112233,md5,abababab bar/file.bin
                    \\112500.25,11777,sha256,5555 data/blob.bin
                    \\113500.25,11888,sha256,5577 data/vid.mp4
                    \\
                    ,
                },
                .{
                    .relativePath = "nested/dir/file.sha256",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .content =
                    \\2222 a.txt
                    \\8877 sub/deep.bin
                    \\
                    ,
                },
            },
            .expected =
            \\# version 1
            \\1337.00133,42069,sha512,deadbeef abc.txt
            \\,,md5,4444 deep/inside/file.log
            \\,,md5,1111 empty.dat
            \\1133779,112233,md5,abababab foo/bar/file.bin
            \\112500.25,11777,sha256,5555 foo/data/blob.bin
            \\113500.25,11888,sha256,5577 foo/data/vid.mp4
            \\60000,2048,sha256,8888 nested/dir/sub/deep.bin
            \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
            \\,,md5,3344 root.txt
            \\,,md5,6666 tiny.flag
            \\
            ,
            .expected_error = null,
        },
        .{
            .name = "discover depth + only .cshd",
            .discover_hash_files_depth = 1,
            .filter_deleted = false,
            .hash_files_matcher = blk: {
                var build = PathMatcherBuilder.init(testing.allocator);
                try build.allow("**/*.cshd");
                break :blk try build.build();
            },
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content =
                    \\# version 1
                    \\1337.00133,42069,sha512,deadbeef abc.txt
                    \\33779,2233,md5,abababab foo/bar/file.bin
                    \\3500.25,888,sha256,5577 foo/data/vid.mp4
                    \\15999.5,,sha256,1111 empty.dat
                    \\60000,2048,sha256,8888 nested/dir/sub/deep.bin
                    \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
                    \\10000,64,md5,3333 root.txt
                    \\
                    ,
                },
                .{
                    .relativePath = "file.md5",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
                    .content =
                    \\5577 foo/data/vid.mp4
                    \\1111 empty.dat
                    \\3344 root.txt
                    \\6666 tiny.flag
                    \\4444 deep/inside/file.log
                    \\
                    ,
                },
                .{
                    .relativePath = "foo/file.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
                    .content =
                    \\# version 1
                    \\1133779,112233,md5,abababab bar/file.bin
                    \\112500.25,11777,sha256,5555 data/blob.bin
                    \\113500.25,11888,sha256,5577 data/vid.mp4
                    \\
                    ,
                },
                .{
                    .relativePath = "nested/dir/file.sha256",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .content =
                    \\2222 a.txt
                    \\8877 sub/deep.bin
                    \\
                    ,
                },
            },
            .expected =
            \\# version 1
            \\1337.00133,42069,sha512,deadbeef abc.txt
            \\15999.5,,sha256,1111 empty.dat
            \\1133779,112233,md5,abababab foo/bar/file.bin
            \\112500.25,11777,sha256,5555 foo/data/blob.bin
            \\113500.25,11888,sha256,5577 foo/data/vid.mp4
            \\60000,2048,sha256,8888 nested/dir/sub/deep.bin
            \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
            \\10000,64,md5,3333 root.txt
            \\
            ,
            .expected_error = null,
        },
    };
    defer {
        // free test data allocations
        for (tests) |tt| {
            // hack to free the const matcher contents
            var copy = tt.hash_files_matcher;
            copy.deinit(testing.allocator);
        }
    }

    for (tests) |tt| {
        std.log.info("test-case: {s}\n", .{tt.name});

        var tmp = helpers.tmpDirWithPath(.{});
        defer tmp.cleanup();

        try helpers.createTestFiles(testing.io, tmp.tmp.dir, tt.test_files);

        var store = PathStore.init(testing.allocator, Io.Dir.max_path_bytes);
        defer store.deinit();

        const result = buildMostCurrent(
            testing.io,
            testing.allocator,
            &store,
            .{
                .hash_files_matcher = tt.hash_files_matcher,
                .discover_hash_files_depth = tt.discover_hash_files_depth,
                .most_current_filter_deleted = tt.filter_deleted,
                .root = tmp.absolute_path,
            },
            null,
            &.{},
        );

        if (tt.expected_error) |err| {
            try testing.expectError(err, result);
        }

        var collection = try result;
        defer collection.deinit();

        var writer = Io.Writer.Allocating.init(testing.allocator);
        defer writer.deinit();
        const Serializer = @import("serializer.zig").Serializer;

        var serializer = Serializer.init(&writer.writer, &collection);
        try serializer.flush();

        const actual_unsorted = writer.written();
        const actual = try helpers.sortSerialized(testing.allocator, actual_unsorted);
        defer testing.allocator.free(actual);

        try testing.expectEqualStrings(tt.expected, actual);
    }
}

test "buildMostCurrent callbacks" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;

    const discover_hash_files_depth = 1;
    const filter_deleted = false;
    var matcher = blk: {
        var build = PathMatcherBuilder.init(testing.allocator);
        try build.allow("**/*.cshd");
        break :blk try build.build();
    };
    defer matcher.deinit(testing.allocator);
    const test_files = &[_]helpers.TestFile{
        .{
            .relativePath = "file.cshd",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .content =
            \\# version 1
            \\1337.00133,42069,sha512,deadbeef abc.txt
            \\33779,2233,md5,abababab foo/bar/file.bin
            \\3500.25,888,sha256,5577 foo/data/vid.mp4
            \\15999.5,,sha256,1111 empty.dat
            \\60000,2048,sha256,8888 nested/dir/sub/deep.bin
            \\6666.6,4096,sha256,9999 nested/dir/sub/foo.doc
            \\10000,64,md5,3333 root.txt
            \\
            ,
        },
        .{
            .relativePath = "file.md5",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
            .content =
            \\5577 foo/data/vid.mp4
            \\1111 empty.dat
            \\3344 root.txt
            \\6666 tiny.flag
            \\4444 deep/inside/file.log
            \\
            ,
        },
        .{
            .relativePath = "foo/file.cshd",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
            .content =
            \\# version 1
            \\1133779,112233,md5,abababab bar/file.bin
            \\112500.25,11777,sha256,5555 data/blob.bin
            \\113500.25,11888,sha256,5577 data/vid.mp4
            \\
            ,
        },
        .{
            .relativePath = "nested/dir/file.sha256",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
            .content =
            \\2222 a.txt
            \\8877 sub/deep.bin
            \\
            ,
        },
    };

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();
    try helpers.createTestFiles(testing.io, tmp.tmp.dir, test_files);

    const expected_callbacks = &[_]prog.MostCurrentProgress{
        .{
            .found_file = try std.fs.path.join(testing.allocator, &[_][]const u8{
                "file.cshd",
            }),
        },
        .{
            .ignored_path = try std.fs.path.join(testing.allocator, &[_][]const u8{
                "file.md5",
            }),
        },
        .{
            .found_file = try std.fs.path.join(testing.allocator, &[_][]const u8{
                "foo",
                "file.cshd",
            }),
        },
        .{
            .ignored_path = try std.fs.path.join(testing.allocator, &[_][]const u8{
                "nested",
                "dir",
            }),
        },
        .{
            .merge_hash_file = try std.fs.path.join(testing.allocator, &[_][]const u8{
                tmp.absolute_path,
                "file.cshd",
            }),
        },
        .{
            .merge_hash_file = try std.fs.path.join(testing.allocator, &[_][]const u8{
                tmp.absolute_path,
                "foo",
                "file.cshd",
            }),
        },
    };
    defer {
        for (expected_callbacks) |p| {
            switch (p) {
                .found_file, .merge_hash_file, .ignored_path => |path| {
                    testing.allocator.free(path);
                },
            }
        }
    }

    var store = PathStore.init(testing.allocator, Io.Dir.max_path_bytes);
    defer store.deinit();

    const CaptureType = helpers.CallbackCapture(prog.MostCurrentProgress);
    var capture = CaptureType.init(testing.allocator);
    defer capture.deinit();

    const result = buildMostCurrent(
        testing.io,
        testing.allocator,
        &store,
        .{
            .hash_files_matcher = matcher,
            .discover_hash_files_depth = discover_hash_files_depth,
            .most_current_filter_deleted = filter_deleted,
            .root = tmp.absolute_path,
        },
        CaptureType.cb,
        &capture,
    );

    var collection = try result;
    defer collection.deinit();

    try helpers.expectEqualSlicesDeep(
        prog.MostCurrentProgress,
        expected_callbacks,
        capture.captures.items,
    );
}
