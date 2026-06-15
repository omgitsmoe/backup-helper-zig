const std = @import("std");
const Io = std.Io;
const std_path = std.fs.path;
const testing = std.testing;

const prog = @import("progress.zig");
const Collection = @import("collection.zig").Collection;
const PathStore = @import("store.zig").PathStore;
const PathMatcher = @import("matcher.zig").PathMatcher;
const HashType = @import("hash.zig").HashType;
const Serializer = @import("serializer.zig").Serializer;
const File = @import("file.zig").File;
const discoverFiles = @import("discover.zig").discoverFiles;
const defaultHashFileName = @import("checksum_helper.zig").defaultHashFileName;

pub const Options = struct {
    /// Which hash algorithm to use for generating new hashes.
    hash_type: HashType,

    /// Whether to include files in the output, which did not change compared
    /// to the previous latest available hash found.
    include_unchanged_files: bool,

    /// Whether to skip files when computing hashes if that files has the same
    /// modification time as in the latest available hash found.
    skip_unchanged: bool,

    /// If Some, periodically flushes the incremental hash collection
    /// to disk upon the next modification after the specified time interval.
    periodic_write_interval: ?Io.Duration,

    /// Allow/block list like matching for all files.
    /// Affects all file discovery behaviour: which files get included
    /// in an incremental hash file, which files are ignored when checking
    /// for files that don't have checksums in `check_missing`, etc.
    all_files_matcher: PathMatcher,
};

pub const Incremental = struct {
    io: Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    store: *PathStore,
    most_current: *const Collection,
    options: Options,
    files_to_checksum: [][]const u8,

    pub const Error = error{} ||
        std.mem.Allocator.Error ||
        Io.Dir.StatFileError ||
        Io.Writer.Error ||
        Collection.Error ||
        PathStore.Error ||
        prog.CallbackError;

    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        root: []const u8,
        store: *PathStore,
        most_current: *const Collection,
        options: Options,
    ) std.mem.Allocator.Error!Incremental {
        return .{
            .io = io,
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .store = store,
            .most_current = most_current,
            .options = options,
            .files_to_checksum = &.{},
        };
    }

    pub fn deinit(self: *Incremental) void {
        self.allocator.free(self.root);
        self.allocator.free(self.files_to_checksum);
    }

    pub fn generate(
        self: *Incremental,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) Error!Collection {
        self.files_to_checksum = try discoverFiles(self.allocator, self.io, self.store, .{
            .matcher = &self.options.all_files_matcher,
            .root = self.root,
        }, progress, context);
        return self.checksumFiles(progress, context);
    }

    const MapCallback = struct {
        inner: *Incremental,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,

        pub fn cb(p: prog.HashProgress, context: *anyopaque) prog.CallbackError!void {
            const self: *@This() = @ptrCast(@alignCast(context));

            if (self.progress) |progress_fn| {
                try progress_fn(.{
                    .read = .{ .read = p.bytes_read, .total = p.bytes_total },
                }, self.context);
            }
        }
    };

    fn checksumFiles(
        self: *Incremental,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) Error!Collection {
        // TODO pull parts out into separate functions
        const name = try defaultHashFileName(
            self.io,
            self.allocator,
            self.root,
            "incremental",
            "",
        );
        defer self.allocator.free(name);

        var result = try Collection.init(self.allocator, self.root, name);
        const collection_alloc = result.arena.allocator();
        errdefer result.deinit();

        var dir = try Io.Dir.openDirAbsolute(self.io, self.root, .{});
        defer dir.close(self.io);
        var file = try dir.createFile(self.io, result.name, .{});
        defer file.close(self.io);

        var buf: [65536]u8 = undefined;
        var writer = file.writer(self.io, &buf);

        var last_flush = Io.Timestamp.now(self.io, .real);
        var serializer = Serializer.init(&writer.interface, &result);

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&path_buf);
        const fba = fixed.allocator();

        for (self.files_to_checksum) |file_path| {
            defer fixed.reset();

            const relative_path = try std_path.relative(fba, "", null, self.root, file_path);
            var on_disk = File{
                .path = file_path,
                .mtime = null,
                .size = null,
                .hash_type = self.options.hash_type,
                .hash_bytes = &.{},
            };

            const previous = self.most_current.get(file_path);

            if (progress) |progress_fn| {
                try progress_fn(.{
                    .pre_read = relative_path,
                }, context);
            }

            const open_file = try Io.Dir.openFileAbsolute(
                self.io,
                file_path,
                .{ .allow_directory = false },
            );
            defer open_file.close(self.io);

            const st = try open_file.stat(self.io);
            on_disk.mtime = st.mtime;
            on_disk.size = st.size;

            if (self.options.skip_unchanged and previous != null and
                previous.?.mtime != null)
            {
                const prev_mtime = previous.?.mtime.?;
                // metadata_from_disk would've errored if it couldn't read mtime
                const on_disk_mtime = on_disk.mtime.?;

                if (File.mtimeEqual(on_disk_mtime, prev_mtime)) {
                    if (self.options.include_unchanged_files) {
                        on_disk.size = previous.?.size;
                        on_disk.hash_bytes = previous.?.hash_bytes;
                        try result.putNoClobber(on_disk);
                    }

                    if (progress) |progress_fn| {
                        try progress_fn(.{
                            .file_unchanged_skipped = relative_path,
                        }, context);
                    }

                    continue;
                }
            }

            var mapper = MapCallback{
                .inner = self,
                .progress = progress,
                .context = context,
            };
            on_disk.hash_bytes = try on_disk.hash_from_disk(
                self.io,
                collection_alloc,
                open_file,
                MapCallback.cb,
                &mapper,
            );

            var include = true;
            if (previous) |prev| {
                include = try self.compare_and_include(
                    open_file,
                    on_disk,
                    prev,
                    relative_path,
                    progress,
                    context,
                );
            } else {
                if (progress) |progress_fn| {
                    try progress_fn(.{
                        .file_new = relative_path,
                    }, context);
                }
            }

            if (include) {
                try result.putNoClobber(on_disk);

                if (self.options.periodic_write_interval) |write_interval| {
                    const now = Io.Timestamp.now(self.io, .real);
                    if (last_flush.durationTo(now).nanoseconds >=
                        write_interval.nanoseconds)
                    {
                        try serializer.flush();
                        last_flush = now;
                    }
                }
            }
        }

        if (self.options.periodic_write_interval) |_| {
            try serializer.flush();
        }

        if (progress) |progress_fn| {
            try self.notify_missing(&fixed, result, progress_fn, context);
            try progress_fn(prog.IncrementalProgress.finished, context);
        }

        return result;
    }

    // TODO must include if previous mtime none
    fn compare_and_include(
        self: *Incremental,
        open_file: Io.File,
        on_disk: File,
        previous: File,
        relative_path: []const u8,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) Error!bool {
        const is_match = if (on_disk.hash_type != previous.hash_type) blk: {
            var mapper = MapCallback{
                .inner = self,
                .progress = progress,
                .context = context,
            };
            const on_disk_hash = try on_disk.hash_from_disk(
                self.io,
                self.allocator,
                open_file,
                MapCallback.cb,
                &mapper,
            );
            defer self.allocator.free(on_disk_hash);

            break :blk std.mem.eql(u8, on_disk_hash, previous.hash_bytes);
        } else std.mem.eql(u8, on_disk.hash_bytes, previous.hash_bytes);

        if (is_match) {
            if (progress) |progress_fn| {
                try progress_fn(.{ .file_match = relative_path }, context);
            }
            return self.options.include_unchanged_files;
        }

        if (progress) |progress_fn| {
            if (previous.mtime == null or on_disk.mtime == null) {
                try progress_fn(.{ .file_changed = relative_path }, context);
                return true;
            }

            const prev_mtime = previous.mtime.?;
            const on_disk_mtime = on_disk.mtime.?;
            if (File.mtimeEqual(on_disk_mtime, prev_mtime)) {
                try progress_fn(.{ .file_changed_corrupted = relative_path }, context);
            } else {
                const diff = on_disk_mtime.durationTo(prev_mtime);
                if (diff.nanoseconds > 0) {
                    try progress_fn(.{ .file_changed_older = relative_path }, context);
                } else {
                    try progress_fn(.{ .file_changed = relative_path }, context);
                }
            }
        }

        return true;
    }

    fn notify_missing(
        self: *Incremental,
        fba: *std.heap.FixedBufferAllocator,
        on_disk: Collection,
        progress: prog.IncrementalProgressFn,
        context: *anyopaque,
    ) Error!void {
        fba.reset();

        const alloc = fba.allocator();
        var iter = self.most_current.iterator();
        while (iter.next()) |previous_entry| : (fba.reset()) {
            const found = on_disk.get(previous_entry.key_ptr.*) != null;
            if (!found) {
                const relative_path = try std_path.relative(
                    alloc,
                    "",
                    null,
                    self.root,
                    previous_entry.key_ptr.*,
                );

                try progress(.{
                    .file_removed = relative_path,
                }, context);
            }
        }
    }
};

test "Incremental generate" {
    const helpers = @import("test_helpers.zig");
    const empty_matcher = PathMatcher{ .allow = &.{}, .block = &.{} };

    const MostCurrentEntry = struct {
        relative_path: []const u8,
        mtime: Io.Timestamp,
        size: ?u64,
        hash_bytes: []const u8,
    };

    const TestCase = struct {
        name: []const u8,
        test_files: []const helpers.TestFile,
        most_current: []const MostCurrentEntry,
        skip_unchanged: bool,
        include_unchanged_files: bool,
        expected: []const u8,
        expected_progress: ?[]const prog.IncrementalProgress,
    };

    const tests = &[_]TestCase{
        .{
            .name = "empty dir",
            .test_files = &.{},
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "foo/bar/linux.iso",
                    .mtime = Io.Timestamp.zero,
                    .size = null,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
            },
            .skip_unchanged = false,
            .include_unchanged_files = false,
            .expected = "",
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_done = .{ .files = 0, .ignored = 0 } },
                .{ .file_removed = "foo/bar/linux.iso" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "all",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "abc.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)).addDuration(.fromNanoseconds(1_330_000)),
                    .content = "abc.txt",
                },
                .{
                    .relativePath = "foo.cshd",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
                    .content = "foo.cshd",
                },
                .{
                    .relativePath = "foo/bar/file.bin",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
                    .content = "foo/bar/file.bin",
                },
                .{
                    .relativePath = "foo/bar/vid.mp4",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .content = "foo/bar/vid.mp4",
                },
                .{
                    .relativePath = "nested/dir/a.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(500)),
                    .content = "nested/dir/a.txt",
                },
                .{
                    .relativePath = "nested/dir/sub/foo.doc",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(600)),
                    .content = "nested/dir/sub/foo.doc",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "foo/bar/linux.iso",
                    .mtime = Io.Timestamp.zero,
                    .size = null,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
            },
            .skip_unchanged = false,
            .include_unchanged_files = false,
            .expected =
            \\# version 1
            \\100.00133,7,md5,56b6f09c50bfb4706563cdf3463a6cc3 abc.txt
            \\200,8,md5,4874627865d0464347cbaca03fdbe0f5 foo.cshd
            \\300,16,md5,e52e909b8f3a42f43244843ec29e15da foo/bar/file.bin
            \\400,15,md5,87ae905d8f1fe92704f8e41cac4b81e2 foo/bar/vid.mp4
            \\500,16,md5,2f95b10ff8bbc6367edd718cc8eba062 nested/dir/a.txt
            \\600,22,md5,b05ea47eeb9a9aa7a6a7c751ed34bccc nested/dir/sub/foo.doc
            \\
            ,
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_found = 2 },
                .{ .discover_files_found = 3 },
                .{ .discover_files_found = 4 },
                .{ .discover_files_found = 5 },
                .{ .discover_files_found = 6 },
                .{ .discover_files_done = .{ .files = 6, .ignored = 0 } },
                .{ .pre_read = "abc.txt" },
                .{ .file_new = "abc.txt" },
                .{ .pre_read = "foo.cshd" },
                .{ .file_new = "foo.cshd" },
                .{ .pre_read = "foo/bar/file.bin" },
                .{ .file_new = "foo/bar/file.bin" },
                .{ .pre_read = "foo/bar/vid.mp4" },
                .{ .file_new = "foo/bar/vid.mp4" },
                .{ .pre_read = "nested/dir/a.txt" },
                .{ .file_new = "nested/dir/a.txt" },
                .{ .pre_read = "nested/dir/sub/foo.doc" },
                .{ .file_new = "nested/dir/sub/foo.doc" },
                .{ .file_removed = "foo/bar/linux.iso" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "mixed unchanged/skipped/changed/new with skipUnchanged=true",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "abc.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(101)),
                    .content = "abc.txt",
                },
                .{
                    .relativePath = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content = "file.txt changed",
                },
                .{
                    .relativePath = "foo/bar/vid.mp4",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(401)),
                    .content = "foo/bar/vid.mp4 changed",
                },
                .{
                    .relativePath = "nested/dir/sub/foo.doc",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(600)),
                    .content = "nested/dir/sub/foo.doc",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "abc.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 7,
                    .hash_bytes = &[_]u8{ 0x56, 0xb6, 0xf0, 0x9c, 0x50, 0xbf, 0xb4, 0x70, 0x65, 0x63, 0xcd, 0xf3, 0x46, 0x3a, 0x6c, 0xc3 },
                },
                .{
                    .relative_path = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 8,
                    .hash_bytes = &[_]u8{ 0x3d, 0x8e, 0x57, 0x7b, 0xdd, 0xb1, 0x7d, 0xb3, 0x39, 0xea, 0xe0, 0xb3, 0xd9, 0xbc, 0xf1, 0x80 },
                },
                .{
                    .relative_path = "foo/bar/vid.mp4",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(400)),
                    .size = 15,
                    .hash_bytes = &[_]u8{ 0x87, 0xae, 0x90, 0x5d, 0x8f, 0x1f, 0xe9, 0x27, 0x04, 0xf8, 0xe4, 0x1c, 0xac, 0x4b, 0x81, 0xe2 },
                },
            },
            .skip_unchanged = true,
            .include_unchanged_files = false,
            .expected =
            \\# version 1
            \\401,23,md5,8785a5fc676e75cd98062644c8ecd2ec foo/bar/vid.mp4
            \\600,22,md5,b05ea47eeb9a9aa7a6a7c751ed34bccc nested/dir/sub/foo.doc
            \\
            ,
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_found = 2 },
                .{ .discover_files_found = 3 },
                .{ .discover_files_found = 4 },
                .{ .discover_files_done = .{ .files = 4, .ignored = 0 } },
                .{ .pre_read = "abc.txt" },
                .{ .file_match = "abc.txt" },
                .{ .pre_read = "file.txt" },
                .{ .file_unchanged_skipped = "file.txt" },
                .{ .pre_read = "foo/bar/vid.mp4" },
                .{ .file_changed = "foo/bar/vid.mp4" },
                .{ .pre_read = "nested/dir/sub/foo.doc" },
                .{ .file_new = "nested/dir/sub/foo.doc" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "includeUnchanged=false drops unchanged file",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(101)),
                    .content = "file.txt",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 8,
                    .hash_bytes = &[_]u8{ 0x3d, 0x8e, 0x57, 0x7b, 0xdd, 0xb1, 0x7d, 0xb3, 0x39, 0xea, 0xe0, 0xb3, 0xd9, 0xbc, 0xf1, 0x80 },
                },
            },
            .skip_unchanged = true,
            .include_unchanged_files = false,
            .expected = "",
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_done = .{ .files = 1, .ignored = 0 } },
                .{ .pre_read = "file.txt" },
                .{ .file_match = "file.txt" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "includeUnchanged=true keeps unchanged file",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(101)),
                    .content = "file.txt",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 8,
                    .hash_bytes = &[_]u8{ 0x3d, 0x8e, 0x57, 0x7b, 0xdd, 0xb1, 0x7d, 0xb3, 0x39, 0xea, 0xe0, 0xb3, 0xd9, 0xbc, 0xf1, 0x80 },
                },
            },
            .skip_unchanged = false,
            .include_unchanged_files = true,
            .expected =
            \\# version 1
            \\101,8,md5,3d8e577bddb17db339eae0b3d9bcf180 file.txt
            \\
            ,
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_done = .{ .files = 1, .ignored = 0 } },
                .{ .pre_read = "file.txt" },
                .{ .file_match = "file.txt" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "changed file included even with includeUnchanged=false",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(101)),
                    .content = "file.txt changed",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 8,
                    .hash_bytes = &[_]u8{ 0x3d, 0x8e, 0x57, 0x7b, 0xdd, 0xb1, 0x7d, 0xb3, 0x39, 0xea, 0xe0, 0xb3, 0xd9, 0xbc, 0xf1, 0x80 },
                },
            },
            .skip_unchanged = false,
            .include_unchanged_files = false,
            .expected =
            \\# version 1
            \\101,16,md5,984d5fc81394a6c1236876296699dafc file.txt
            \\
            ,
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_done = .{ .files = 1, .ignored = 0 } },
                .{ .pre_read = "file.txt" },
                .{ .file_changed = "file.txt" },
                .{ .finished = {} },
            },
        },
        .{
            .name = "skipUnchanged reuses previous hash when mtime unchanged",
            .test_files = &[_]helpers.TestFile{
                .{
                    .relativePath = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .content = "file.txt changed",
                },
            },
            .most_current = &[_]MostCurrentEntry{
                .{
                    .relative_path = "file.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
                    .size = 8,
                    .hash_bytes = &[_]u8{ 0x3d, 0x8e, 0x57, 0x7b, 0xdd, 0xb1, 0x7d, 0xb3, 0x39, 0xea, 0xe0, 0xb3, 0xd9, 0xbc, 0xf1, 0x80 },
                },
            },
            .skip_unchanged = true,
            .include_unchanged_files = true,
            .expected =
            \\# version 1
            \\100,8,md5,3d8e577bddb17db339eae0b3d9bcf180 file.txt
            \\
            ,
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_done = .{ .files = 1, .ignored = 0 } },
                .{ .pre_read = "file.txt" },
                .{ .file_unchanged_skipped = "file.txt" },
                .{ .finished = {} },
            },
        },
    };

    for (tests) |tt| {
        var tmp = helpers.tmpDirWithPath(.{});
        defer tmp.cleanup();

        try helpers.createTestFiles(testing.io, tmp.tmp.dir, tt.test_files);

        var store = PathStore.init(testing.allocator, Io.Dir.max_path_bytes);
        defer store.deinit();

        var most_current = try Collection.init(testing.allocator, tmp.absolute_path, "most_current");
        defer most_current.deinit();

        for (tt.most_current) |entry| {
            const full_path = try std_path.join(
                most_current.arena.allocator(),
                &[_][]const u8{ tmp.absolute_path, entry.relative_path },
            );
            try most_current.putNoClobber(.{
                .path = full_path,
                .mtime = entry.mtime,
                .size = entry.size,
                .hash_type = .md5,
                .hash_bytes = entry.hash_bytes,
            });
        }

        var inc = try Incremental.init(testing.io, testing.allocator, tmp.absolute_path, &store, &most_current, .{
            .hash_type = .md5,
            .skip_unchanged = tt.skip_unchanged,
            .include_unchanged_files = tt.include_unchanged_files,
            .periodic_write_interval = null,
            .all_files_matcher = empty_matcher,
        });
        defer inc.deinit();

        const Capture = helpers.CallbackCapture(prog.IncrementalProgress);
        var capture = Capture.init(testing.allocator);
        defer capture.deinit();

        var result = try inc.generate(&Capture.cb, &capture);
        defer result.deinit();

        var w = Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        var ser = Serializer.init(&w.writer, &result);
        try ser.flush();

        const got = w.written();
        if (tt.expected.len == 0) {
            try testing.expectEqualStrings("", got);
        } else {
            const sorted_got = try helpers.sortSerialized(testing.allocator, got);
            defer testing.allocator.free(sorted_got);
            const sorted_expected = try helpers.sortSerialized(testing.allocator, tt.expected);
            defer testing.allocator.free(sorted_expected);
            try testing.expectEqualStrings(sorted_expected, sorted_got);
        }

        if (tt.expected_progress) |ep| {
            var actual = std.ArrayList(prog.IncrementalProgress).empty;
            defer actual.deinit(testing.allocator);
            for (capture.captures.items) |a| if (a != .read) try actual.append(testing.allocator, a);

            // Check discover_files_done at same position
            if (ep.len > 0 and ep[0] == .discover_files_done) {
                try testing.expect(actual.items.len > 0 and actual.items[0] == .discover_files_done);
                try testing.expectEqual(ep[0].discover_files_done, actual.items[0].discover_files_done);
            }

            // Check finished at last position
            if (ep.len > 0 and ep[ep.len - 1] == .finished) {
                try testing.expect(actual.items.len > 0 and actual.items[actual.items.len - 1] == .finished);
            }

            // For remaining events, do multiset comparison
            for (ep) |e| {
                if (e == .discover_files_done or e == .finished) continue;
                var found = false;
                for (actual.items) |a| {
                    if (helpers.deepEql(e, a)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    std.debug.print("\nexpected event not found: {any}\n", .{e});
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "Incremental generate with matcher" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;

    var tmp = helpers.tmpDirWithPath(.{ .iterate = true });
    defer tmp.cleanup();

    try helpers.createTestFiles(testing.io, tmp.tmp.dir, &[_]helpers.TestFile{
        .{
            .relativePath = "file.txt",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .content = "file.txt",
        },
        .{
            .relativePath = "foo/bar/vid.mp4",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
            .content = "foo/bar/vid.mp4",
        },
        .{
            .relativePath = "baz/omg.doc",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
            .content = "baz/omg.doc",
        },
    });

    var store = PathStore.init(testing.allocator, Io.Dir.max_path_bytes);
    defer store.deinit();

    var most_current = try Collection.init(testing.allocator, tmp.absolute_path, "most_current");
    defer most_current.deinit();

    var matcher_builder = PathMatcherBuilder.init(testing.allocator);
    try matcher_builder.allow("foo/**/*");
    var matcher = try matcher_builder.build();

    var inc = try Incremental.init(testing.io, testing.allocator, tmp.absolute_path, &store, &most_current, .{
        .hash_type = .md5,
        .skip_unchanged = false,
        .include_unchanged_files = true,
        .periodic_write_interval = null,
        .all_files_matcher = matcher,
    });
    defer inc.deinit();

    const Capture = helpers.CallbackCapture(prog.IncrementalProgress);
    var capture = Capture.init(testing.allocator);
    defer capture.deinit();

    var result = try inc.generate(&Capture.cb, &capture);
    defer result.deinit();

    var w = Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    var ser = Serializer.init(&w.writer, &result);
    try ser.flush();

    const expected =
        \\# version 1
        \\200,15,md5,87ae905d8f1fe92704f8e41cac4b81e2 foo/bar/vid.mp4
        \\
    ;
    try testing.expectEqualStrings(expected, w.written());

    {
        var actual = std.ArrayList(prog.IncrementalProgress).empty;
        defer actual.deinit(testing.allocator);
        for (capture.captures.items) |a| if (a != .read) try actual.append(testing.allocator, a);

        const ep = &[_]prog.IncrementalProgress{
            .{ .discover_files_ignored = "file.txt" },
            .{ .discover_files_ignored = "baz/omg.doc" },
            .{ .discover_files_found = 1 },
            .{ .discover_files_done = .{ .files = 1, .ignored = 2 } },
            .{ .pre_read = "foo/bar/vid.mp4" },
            .{ .file_new = "foo/bar/vid.mp4" },
            .{ .finished = {} },
        };

        // Multiset check for all events except read
        for (ep) |e| {
            var found = false;
            for (actual.items) |a| {
                if (helpers.deepEql(e, a)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("\nexpected event not found: {any}\n", .{e});
                return error.TestExpectedEqual;
            }
        }
    }

    matcher.deinit(testing.allocator);
}
