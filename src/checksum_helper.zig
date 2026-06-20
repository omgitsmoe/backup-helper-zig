const std = @import("std");
const std_path = std.fs.path;
const HashType = @import("hash.zig").HashType;
const Io = std.Io;
const testing = std.testing;

const prog = @import("progress.zig");
const mc = @import("most_current.zig");

const PathMatcher = @import("matcher.zig").PathMatcher;
const PathStore = @import("store.zig").PathStore;
const Collection = @import("collection.zig").Collection;
const File = @import("file.zig").File;
const Serializer = @import("serializer.zig").Serializer;
const Incremental = @import("incremental.zig").Incremental;
const IncrementalOptions = @import("incremental.zig").Options;
const discoverFiles = @import("discover.zig").discoverFiles;
const FilteredWalker = @import("discover.zig").FilteredWalker;

pub const Options = struct {
    /// Which hash algorithm to use for generating new hashes.
    hash_type: HashType,

    /// Whether to include files in the output, which did not change compared
    /// to the previous latest available hash found.
    incremental_include_unchanged_files: bool,

    /// Whether to skip files when computing hashes if that files has the same
    /// modification time as in the latest available hash found.
    incremental_skip_unchanged: bool,

    /// If Some, periodically flushes the incremental hash collection
    /// to disk upon the next modification after the specified time interval.
    incremental_periodic_write_interval: ?Io.Duration,

    /// Up to which depth should the root and its subdirectories be searched
    /// for hash files (*.cshd, *.md5, *.sha512, etc.) to determine the
    /// current state of hashes.
    /// Zero means only files in the root directory will be considered.
    /// One means at most one subdirectory will be allowed.
    /// None means no depth limit.
    discover_hash_files_depth: ?u32,

    /// Whether the most_current hash file should filter out all files that are
    /// not found on disk at the time of generation.
    most_current_filter_deleted: bool,

    /// Allow/block list like matching for hash files which will be used
    /// for building the most current state of hashes.
    /// These hashes will be used when e.g. using the `incremental`
    /// method.
    hash_files_matcher: PathMatcher,

    /// Allow/block list like matching for all files.
    /// Affects all file discovery behaviour: which files get included
    /// in an incremental hash file, which files are ignored when checking
    /// for files that don't have checksums in `check_missing`, etc.
    all_files_matcher: PathMatcher,

    pub fn default() Options {
        return .{
            .hash_type = .sha512,
            .incremental_include_unchanged_files = true,
            .incremental_skip_unchanged = false,
            .incremental_periodic_write_interval = null,
            .discover_hash_files_depth = null,
            .most_current_filter_deleted = true,
            .hash_files_matcher = .{
                .allow = &.{},
                .block = &.{},
            },
            .all_files_matcher = .{
                .allow = &.{},
                .block = &.{},
            },
        };
    }
};

// TODO find a better way to do progress reporting or
//      include predicates
//      the current callback-based approach doesn't seem idiomatic
//      ("no hidden control flow"),
//      prefer explicit iterator-approach, like Dir.SelectiveWalker.enter
//      or emitting progress events as well
//      option 1): small improvement use comptime-known callbacks
//      `fn incremental(self: *ChecksumHelper, comptime context: anytype, comptime progress: fn (@TypeOf(context), IncrementalProgress) CallbackError!void) !Collection`
//
//      option 2): use an explicit event writer/sink
//      fn incremental(self: *ChecksumHelper, progress_writer: ?*const EventWriter(IncrementalProgress)) !Collection
//      kind of similar to a callback, but easier to use
//
//      option 3): full iterator-approach, which makes sense for file iteration,
//      but unnecessarily complicates operations like file hashing etc.
pub const ChecksumHelper = struct {
    io: Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    store: PathStore,
    options: Options,
    most_current: ?Collection,

    pub fn init(io: Io, allocator: std.mem.Allocator, root: []const u8) !ChecksumHelper {
        return withOptions(io, allocator, root, Options.default());
    }

    pub fn withOptions(
        io: Io,
        allocator: std.mem.Allocator,
        root: []const u8,
        options: Options,
    ) !ChecksumHelper {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const use_root = if (!std_path.isAbsolute(root)) blk: {
            const size = try std.process.currentPath(io, &path_buf);
            const abs = try std_path.join(
                allocator,
                &.{
                    path_buf[0..size],
                    root,
                },
            );
            break :blk abs;
        } else try allocator.dupe(u8, root);
        defer allocator.free(use_root);

        const normalized = try std_path.resolve(allocator, &.{use_root});
        return .{
            .io = io,
            .allocator = allocator,
            .root = normalized,
            .store = PathStore.init(allocator, 64 * 1024),
            .options = options,
            .most_current = null,
        };
    }

    pub fn deinit(self: *ChecksumHelper) void {
        if (self.most_current) |*most_current| {
            most_current.deinit();
        }
        self.allocator.free(self.root);
        self.store.deinit();
    }

    /// Generate a `Collection`, while comparing the resulting hashes
    /// to the hashes in the *most current* hash file.
    ///
    /// Depending on `Options.incremental_include_unchanged_files`
    /// only the changed files are kept.
    ///
    /// To skip checking "unchanged" files: set
    /// `Options.incremental_skip_unchanged`.
    pub fn incremental(
        self: *ChecksumHelper,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) !Collection {
        var mapper = prog.IncrementalProgressMapper{
            .progress = progress,
            .context = context,
        };

        const most_current = try self.mostCurrent(
            &prog.IncrementalProgressMapper.cbMostCurrent,
            &mapper,
        );
        var inc = try Incremental.init(
            self.io,
            self.allocator,
            self.root,
            &self.store,
            most_current,
            IncrementalOptions.from(self.options),
        );
        defer inc.deinit();

        return inc.generate(progress, context);
    }

    /// Generate a [`HashCollection`], which only contains the hashes of
    /// files that do not have checksums in any matched hash file yet.
    pub fn fillMissing(
        self: *ChecksumHelper,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) !Collection {
        var mapper = prog.IncrementalProgressMapper{
            .progress = progress,
            .context = context,
        };
        const most_current = try self.mostCurrent(
            prog.IncrementalProgressMapper.cbMostCurrent,
            &mapper,
        );

        const all_files = try discoverFiles(
            self.allocator,
            self.io,
            &self.store,
            .{ .root = self.root, .matcher = &self.options.all_files_matcher },
            progress,
            context,
        );
        // no need to free contained paths, since they're stored in self.store
        // and are used in the result
        defer self.allocator.free(all_files);

        const name = try defaultHashFileName(
            self.io,
            self.allocator,
            self.root,
            "missing",
            "missing_",
        );
        defer self.allocator.free(name);

        var collection = try Collection.init(self.allocator, self.root, name);
        errdefer collection.deinit();
        const alloc = collection.arena.allocator();
        for (all_files) |p| {
            if (most_current.get(p) != null) {
                continue;
            }

            const file = try File.from_disk(
                self.io,
                alloc,
                p,
                self.options.hash_type,
                &prog.IncrementalProgressMapper.cbHashProgress,
                &mapper,
            );
            try collection.putNoClobber(file);
        }

        return collection;
    }

    /// Returns a result object containing all individual files that do not have checksums
    /// in `self.root` yet.
    /// If a directory has files and is completely missing it will be listed
    /// in `directories`.
    /// Note: The files of that directory will not appear in the file list.
    pub fn checkMissing(
        self: *ChecksumHelper,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) !CheckMissingResult {
        var mapper = prog.IncrementalProgressMapper{
            .progress = progress,
            .context = context,
        };
        const most_current = try self.mostCurrent(
            prog.IncrementalProgressMapper.cbMostCurrent,
            &mapper,
        );

        var helper = CheckMissing{
            .directories_with_hashed_files = .init(self.allocator),
            .progress = progress,
            .context = context,
            .last_was_missing = false,
            .matcher = &self.options.all_files_matcher,
        };
        // don't free keys, since they point into the keys of most_current
        defer helper.deinit();

        // build a set of directories that have at least one hashed file
        var iter = most_current.iterator();
        while (iter.next()) |entry| {
            const relative = std.mem.cutPrefix(u8, entry.key_ptr.*, self.root) orelse
                @panic("bug: all most_current paths must be prefixed by " ++
                    "ChecksumHelper.root");

            const trimmed = if (relative.len > 0 and std.fs.path.isSep(relative[0]))
                relative[1..]
            else
                relative;
            var dirpath = std_path.dirname(trimmed);
            while (dirpath) |dp| : (dirpath = std_path.dirname(dp)) {
                try helper.directories_with_hashed_files.put(dp, {});
            }
        }

        var missing_files = std.ArrayList([]const u8).empty;
        defer missing_files.deinit(self.allocator);
        var missing_directories = std.ArrayList([]const u8).empty;
        defer missing_directories.deinit(self.allocator);
        var store = PathStore.init(self.allocator, Io.Dir.max_path_bytes);
        errdefer store.deinit();

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&path_buf);
        const fba = fixed.allocator();

        const dir = try Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer dir.close(self.io);
        var walker = try FilteredWalker.init(
            self.allocator,
            dir,
            0,
            &CheckMissing.pred,
        );
        defer walker.deinit();

        var files_found: u64 = 0;
        var files_ignored: u64 = 0;
        while (try walker.next(self.io, &helper)) |entry| : (fixed.reset()) {
            switch (entry.status) {
                .ok => {},
                .ignored_predicate, .ignored_special_file, .ignored_max_depth => {
                    if (progress) |progress_fn| {
                        try progress_fn(.{
                            .build_most_current = .{
                                .ignored_path = entry.inner.path,
                            },
                        }, context);
                    }

                    if (entry.status == .ignored_predicate and helper.last_was_missing) {
                        const stored = try store.store(entry.inner.path);
                        try missing_directories.append(self.allocator, stored);
                    } else {
                        files_ignored += 1;
                    }

                    continue;
                },
            }

            files_found += 1;
            if (progress) |progress_fn| {
                try progress_fn(.{
                    .discover_files_found = files_found,
                }, context);
            }

            const abs = try std_path.join(fba, &.{ self.root, entry.inner.path });
            if (most_current.get(abs) == null) {
                const stored = try store.store(entry.inner.path);
                try missing_files.append(self.allocator, stored);
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

        return .{
            .directories = try missing_directories.toOwnedSlice(self.allocator),
            .files = try missing_files.toOwnedSlice(self.allocator),
            .store = store,
        };
    }

    const CheckMissing = struct {
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
        directories_with_hashed_files: std.StringHashMap(void),
        matcher: *const PathMatcher,
        // whether the last entry ignored by the predicate was a missing directory
        last_was_missing: bool,

        pub fn deinit(self: *CheckMissing) void {
            self.directories_with_hashed_files.deinit();
        }

        fn pred(userdata: *anyopaque, entry: Io.Dir.Walker.Entry) prog.CallbackError!bool {
            const self: *CheckMissing = @ptrCast(@alignCast(userdata));

            if (entry.kind == .directory) {
                // ignored directories don't count as missing, so early exit
                if (self.matcher.isBlocked(entry.path)) {
                    return false;
                }

                if (self.directories_with_hashed_files.get(entry.path) == null) {
                    self.last_was_missing = true;
                    return false;
                }

                return true;
            }

            self.last_was_missing = false;
            return self.match(entry);
        }

        fn match(self: *const CheckMissing, entry: Io.Dir.Walker.Entry) bool {
            if (entry.kind == .directory) {
                if (self.matcher.isBlocked(entry.path)) {
                    return false;
                }

                return true;
            }

            return self.matcher.isMatch(entry.path);
        }
    };

    /// Build a checksum file containing all the most current hashes found in all
    /// checksum files under [`ChecksumHelper.root`] if it isn't available yet.
    ///
    /// The received `&HashCollection` can be conveniently written by using
    /// [`ChecksumHelper::write_collection`]
    /// or [`ChecksumHelper::write_into`].
    /// Alternatively `Serializer` can be used directly.
    ///
    /// - `progress`: Progress callback that receives a [`MostCurrentProgress`]
    ///   when progress is made.
    /// - `context`: Pointer that will be passed to the `progress` callback.
    pub fn mostCurrent(
        self: *ChecksumHelper,
        progress: ?prog.MostCurrentProgressFn,
        context: *anyopaque,
    ) !*const Collection {
        if (self.most_current == null) {
            self.most_current = try mc.buildMostCurrent(
                self.io,
                self.allocator,
                &self.store,
                mc.Options.from(self.root, self.options),
                progress,
                context,
            );
        }

        return &self.most_current.?;
    }

    pub fn clearMostCurrent(self: *ChecksumHelper) !void {
        if (self.most_current) |*most_current| {
            // @Memory allocations in store aren't cleared
            most_current.deinit();
        }

        self.most_current = null;
    }

    /// The resulting `Collection` depends on `ChecksumHelper`,
    /// thus `ChecksumHelper` needs to live at least as long as `Collection`.
    pub fn readCollection(self: *ChecksumHelper, path: []const u8) !Collection {
        return Collection.fromDisk(self.io, self.allocator, &self.store, path);
    }

    pub fn writeCollection(self: ChecksumHelper, collection: Collection) !void {
        const path = try std_path.join(self.allocator, &.{
            collection.root(),
            collection.filename(),
        });
        defer self.allocator.free(path);

        const file = try Io.Dir.cwd().createFile(self.io, path, .{});
        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(self.io, &buf);

        try self.writeInto(collection, &w.interface);
    }

    pub fn writeInto(
        self: ChecksumHelper,
        collection: Collection,
        writer: *Io.Writer,
    ) !void {
        _ = self;
        var ser = Serializer.init(writer, &collection);
        try ser.flush();
    }

    /// Verify all files matching predicate `include` in the [`HashCollection`]
    ///
    /// - `include`: Predicate function which determines whether to include the
    ///   Path passed to it in verification. The path is relative
    ///   to the `file_tree.root()`.
    /// - `progress`: Progress callback that receives a [`VerifyProgress`]
    ///   before and after processing the file.
    pub fn verify(
        self: ChecksumHelper,
        collection: Collection,
        include: ?Collection.IncludeFn,
        progress: prog.VerifyProgressFn,
        context: *anyopaque,
    ) !void {
        try collection.verify(self.io, include, progress, context);
    }

    /// Verify all found checksum files found in the [`ChecksumHelper::root`].
    ///
    /// Verification results and progress in general is communicated via
    /// the [`progress`] callback.
    ///
    /// - `include`: Predicate function which determines whether to include the
    ///   Path passed to it in verification. The path is relative
    ///   to the `file_tree.root()`.
    /// - `progress`: Progress callback that receives a [`VerifyRootProgress`]
    ///   when building the most current checksum file
    ///   and on verification progress.
    pub fn verifyRoot(
        self: *ChecksumHelper,
        include: ?Collection.IncludeFn,
        progress: prog.VerifyRootProgressFn,
        context: *anyopaque,
    ) !void {
        var mapper = prog.VerifyRootMapper{
            .progress = progress,
            .context = context,
            .include = include,
            .include_context = context,
        };

        const most_current = try self.mostCurrent(
            &prog.VerifyRootMapper.cbMostCurrent,
            &mapper,
        );

        try most_current.verify(
            self.io,
            prog.VerifyRootMapper.cbInclude,
            &prog.VerifyRootMapper.cbVerify,
            &mapper,
        );
    }
};

pub const CheckMissingResult = struct {
    /// Directories containing matched files, but which are completely missing
    /// from any hash collection.
    /// Files from directories in that list will not be listed in `files`.
    directories: [][]const u8,
    /// Matched files completely missing a hash. Does not contain files in
    /// directories that are completely missing.
    files: [][]const u8,
    /// Store holding all paths that `directories` and `files` point to.
    store: PathStore,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.directories);
        allocator.free(self.files);
        self.store.deinit();
    }
};

pub fn defaultHashFileName(
    io: Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    default: []const u8,
    infix: []const u8,
) (std.mem.Allocator.Error || Io.Writer.Error)![]u8 {
    const dirname = std.fs.path.basename(directory);
    const base = if (dirname.len == 0 or std.mem.eql(u8, dirname, "."))
        default
    else
        dirname;

    const now = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(now.toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var buf: [Io.Dir.max_name_bytes]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);

    try writer.print("{s}_{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}{d:0>2}{d:0>2}.cshd", .{
        base,
        infix,
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });

    const dupe = allocator.dupe(u8, writer.buffered());
    return dupe;
}

test "checkMissing" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;

    const HashEntry = struct {
        relative_path: []const u8,
    };

    const TestCase = struct {
        name: []const u8,
        test_files: []const helpers.TestFile,
        hash_entries: []const HashEntry,
        build_matcher: ?*const fn (builder: *PathMatcherBuilder) anyerror!void,
        expected_directories: []const []const u8,
        expected_files: []const []const u8,
        expected_progress: ?[]const prog.IncrementalProgress,
    };

    const tests = &[_]TestCase{
        .{
            .name = "all files at root missing",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "a.txt", .mtime = null, .content = "a.txt" },
                .{ .relativePath = "b.txt", .mtime = null, .content = "b.txt" },
            },
            .hash_entries = &.{},
            .build_matcher = null,
            .expected_directories = &.{},
            .expected_files = &.{ "a.txt", "b.txt" },
            .expected_progress = null,
        },
        .{
            .name = "some files have hashes",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "a.txt", .mtime = null, .content = "a.txt" },
                .{ .relativePath = "b.txt", .mtime = null, .content = "b.txt" },
                .{ .relativePath = "c.txt", .mtime = null, .content = "c.txt" },
            },
            .hash_entries = &[_]HashEntry{
                .{ .relative_path = "a.txt" },
            },
            .build_matcher = null,
            .expected_directories = &.{},
            .expected_files = &.{ "b.txt", "c.txt" },
            .expected_progress = null,
        },
        .{
            .name = "directory completely missing",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "hashed.txt", .mtime = null, .content = "hashed.txt" },
                .{ .relativePath = "missing/b.txt", .mtime = null, .content = "missing/b.txt" },
            },
            .hash_entries = &[_]HashEntry{
                .{ .relative_path = "hashed.txt" },
            },
            .build_matcher = null,
            .expected_directories = &.{"missing"},
            .expected_files = &.{},
            .expected_progress = null,
        },
        .{
            .name = "directory partially missing",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "partial/hashed.txt", .mtime = null, .content = "partial/hashed.txt" },
                .{ .relativePath = "partial/missing.txt", .mtime = null, .content = "partial/missing.txt" },
            },
            .hash_entries = &[_]HashEntry{
                .{ .relative_path = "partial/hashed.txt" },
            },
            .build_matcher = null,
            .expected_directories = &.{},
            .expected_files = &.{"partial/missing.txt"},
            .expected_progress = null,
        },
        .{
            .name = "blocked directory ignored",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "a.txt", .mtime = null, .content = "a.txt" },
                .{ .relativePath = "ignored/b.txt", .mtime = null, .content = "ignored/b.txt" },
                .{ .relativePath = "included/hashed.txt", .mtime = null, .content = "included/hashed.txt" },
                .{ .relativePath = "included/missing.txt", .mtime = null, .content = "included/missing.txt" },
            },
            .hash_entries = &[_]HashEntry{
                .{ .relative_path = "a.txt" },
                .{ .relative_path = "included/hashed.txt" },
            },
            .build_matcher = &struct {
                fn build(builder: *PathMatcherBuilder) anyerror!void {
                    try builder.block("ignored");
                }
            }.build,
            .expected_directories = &.{},
            .expected_files = &.{"included/missing.txt"},
            .expected_progress = null,
        },
        .{
            .name = "progress events fire",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "a.txt", .mtime = null, .content = "a.txt" },
            },
            .hash_entries = &.{},
            .build_matcher = null,
            .expected_directories = &.{},
            .expected_files = &.{"a.txt"},
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_found = 1 },
                .{ .discover_files_done = .{ .files = 1, .ignored = 0 } },
            },
        },
    };

    for (tests) |tt| {
        var tmp = helpers.tmpDirWithPath(.{});
        defer tmp.cleanup();

        try helpers.createTestFiles(testing.io, tmp.tmp.dir, tt.test_files);

        var matcher: ?PathMatcher = null;
        if (tt.build_matcher) |build_fn| {
            var builder = PathMatcherBuilder.init(testing.allocator);
            try build_fn(&builder);
            matcher = try builder.build();
        }
        defer if (matcher) |*m| m.deinit(testing.allocator);

        const options = Options{
            .hash_type = .md5,
            .incremental_include_unchanged_files = true,
            .incremental_skip_unchanged = false,
            .incremental_periodic_write_interval = null,
            .discover_hash_files_depth = null,
            .most_current_filter_deleted = false,
            .hash_files_matcher = .{ .allow = &.{}, .block = &.{} },
            .all_files_matcher = matcher orelse .{ .allow = &.{}, .block = &.{} },
        };

        var helper = try ChecksumHelper.withOptions(
            testing.io,
            testing.allocator,
            tmp.absolute_path,
            options,
        );
        defer helper.deinit();

        var mc_coll = try Collection.init(
            testing.allocator,
            tmp.absolute_path,
            "test_most_current",
        );
        for (tt.hash_entries) |entry| {
            const full_path = try std.fs.path.join(
                mc_coll.arena.allocator(),
                &[_][]const u8{ tmp.absolute_path, entry.relative_path },
            );
            try mc_coll.putNoClobber(.{
                .path = full_path,
                .mtime = null,
                .size = null,
                .hash_type = .md5,
                .hash_bytes = &[_]u8{0} ** 16,
            });
        }
        helper.most_current = mc_coll;

        const Capture = helpers.CallbackCapture(prog.IncrementalProgress);
        var capture = Capture.init(testing.allocator);
        defer capture.deinit();

        var result = try helper.checkMissing(
            if (tt.expected_progress != null) &Capture.cb else null,
            &capture,
        );
        defer {
            testing.allocator.free(result.directories);
            testing.allocator.free(result.files);
            result.store.deinit();
        }

        if (result.directories.len > 0) {
            std.mem.sortUnstable([]const u8, result.directories, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }
        if (result.files.len > 0) {
            std.mem.sortUnstable([]const u8, result.files, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        try helpers.expectEqualStringSlices(tt.expected_directories, result.directories);
        try helpers.expectEqualStringSlices(tt.expected_files, result.files);

        if (tt.expected_progress) |ep| {
            try testing.expectEqual(ep.len, capture.captures.items.len);
            for (ep, capture.captures.items) |e, a| {
                try testing.expectEqualDeep(e, a);
            }
        }
    }
}

test "fillMissing" {
    const helpers = @import("test_helpers.zig");
    const PathMatcherBuilder = @import("matcher.zig").PathMatcherBuilder;

    const TestCase = struct {
        name: []const u8,
        test_files: []const helpers.TestFile,
        hash_file_content: []const u8,
        build_matcher: ?*const fn (builder: *PathMatcherBuilder) anyerror!void,
        expected_paths: []const []const u8,
        expected_progress: ?[]const prog.IncrementalProgress,
        check_build_most_current: bool,
    };

    const tests = &[_]TestCase{
        .{
            .name = "basic fill missing",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "file.rs", .mtime = null, .content = "file.rs" },
                .{ .relativePath = "root.mp4", .mtime = null, .content = "root.mp4" },
                .{ .relativePath = "foo/foo.bin", .mtime = null, .content = "foo/foo.bin" },
                .{ .relativePath = "foo/foo.txt", .mtime = null, .content = "foo/foo.txt" },
                .{ .relativePath = "foo/bar/bar.test", .mtime = null, .content = "foo/bar/bar.test" },
                .{ .relativePath = "foo/bar/bar.mp4", .mtime = null, .content = "foo/bar/bar.mp4" },
                .{ .relativePath = "foo/bar/baz/file.bin", .mtime = null, .content = "foo/bar/baz/file.bin" },
                .{ .relativePath = "foo/bar/baz/file.txt", .mtime = null, .content = "foo/bar/baz/file.txt" },
                .{ .relativePath = "bar/other.txt", .mtime = null, .content = "bar/other.txt" },
                .{ .relativePath = "bar/baz/baz_2025-06-28.foo", .mtime = null, .content = "bar/baz/baz_2025-06-28.foo" },
                .{ .relativePath = "bar/baz/save.sav", .mtime = null, .content = "bar/baz/save.sav" },
            },
            .hash_file_content =
            \\e37276a93ac1e99188340e3f61e3673b foo/bar/baz/file.bin
            \\e37276a93ac1e99188340e3f61e3673b foo/bar/bar.test
            \\e37276a93ac1e99188340e3f61e3673b foo/bar/bar.mp4
            \\e37276a93ac1e99188340e3f61e3673b bar/baz_2025-06-28.foo
            \\e37276a93ac1e99188340e3f61e3673b bar/other.txt
            \\e37276a93ac1e99188340e3f61e3673b file.rs
            \\
            ,
            .build_matcher = null,
            .expected_paths = &.{
                "bar/baz/baz_2025-06-28.foo",
                "bar/baz/save.sav",
                "foo/bar/baz/file.txt",
                "foo/foo.bin",
                "foo/foo.txt",
                "root.mp4",
                "test.md5",
            },
            .expected_progress = null,
            .check_build_most_current = false,
        },
        .{
            .name = "fill missing respects filters",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "file.rs", .mtime = null, .content = "file.rs" },
                .{ .relativePath = "root.mp4", .mtime = null, .content = "root.mp4" },
                .{ .relativePath = "foo/foo.bin", .mtime = null, .content = "foo/foo.bin" },
                .{ .relativePath = "foo/foo.txt", .mtime = null, .content = "foo/foo.txt" },
                .{ .relativePath = "foo/bar/bar.test", .mtime = null, .content = "foo/bar/bar.test" },
                .{ .relativePath = "foo/bar/bar.mp4", .mtime = null, .content = "foo/bar/bar.mp4" },
                .{ .relativePath = "foo/bar/baz/file.bin", .mtime = null, .content = "foo/bar/baz/file.bin" },
                .{ .relativePath = "foo/bar/baz/file.txt", .mtime = null, .content = "foo/bar/baz/file.txt" },
                .{ .relativePath = "bar/other.txt", .mtime = null, .content = "bar/other.txt" },
                .{ .relativePath = "bar/baz/baz_2025-06-28.foo", .mtime = null, .content = "bar/baz/baz_2025-06-28.foo" },
                .{ .relativePath = "bar/baz/save.sav", .mtime = null, .content = "bar/baz/save.sav" },
            },
            .hash_file_content =
            \\e37276a93ac1e99188340e3f61e3673b bar/baz_2025-06-28.foo
            \\e37276a93ac1e99188340e3f61e3673b bar/other.txt
            \\e37276a93ac1e99188340e3f61e3673b file.rs
            \\
            ,
            .build_matcher = &struct {
                fn build(builder: *PathMatcherBuilder) anyerror!void {
                    try builder.block("foo/bar/");
                    try builder.allow("**/*.md5");
                    try builder.allow("**/*.bin");
                    try builder.allow("**/*.foo");
                    try builder.allow("**/*.txt");
                }
            }.build,
            .expected_paths = &.{
                "bar/baz/baz_2025-06-28.foo",
                "foo/foo.bin",
                "foo/foo.txt",
                "test.md5",
            },
            .expected_progress = null,
            .check_build_most_current = false,
        },
        .{
            .name = "progress events fire",
            .test_files = &[_]helpers.TestFile{
                .{ .relativePath = "file.rs", .mtime = null, .content = "file.rs" },
                .{ .relativePath = "root.mp4", .mtime = null, .content = "root.mp4" },
                .{ .relativePath = "foo/foo.bin", .mtime = null, .content = "foo/foo.bin" },
                .{ .relativePath = "foo/foo.txt", .mtime = null, .content = "foo/foo.txt" },
                .{ .relativePath = "foo/bar/bar.test", .mtime = null, .content = "foo/bar/bar.test" },
                .{ .relativePath = "foo/bar/bar.mp4", .mtime = null, .content = "foo/bar/bar.mp4" },
                .{ .relativePath = "foo/bar/baz/file.bin", .mtime = null, .content = "foo/bar/baz/file.bin" },
                .{ .relativePath = "foo/bar/baz/file.txt", .mtime = null, .content = "foo/bar/baz/file.txt" },
                .{ .relativePath = "bar/other.txt", .mtime = null, .content = "bar/other.txt" },
                .{ .relativePath = "bar/baz/baz_2025-06-28.foo", .mtime = null, .content = "bar/baz/baz_2025-06-28.foo" },
                .{ .relativePath = "bar/baz/save.sav", .mtime = null, .content = "bar/baz/save.sav" },
            },
            .hash_file_content =
            \\e37276a93ac1e99188340e3f61e3673b bar/baz_2025-06-28.foo
            \\e37276a93ac1e99188340e3f61e3673b bar/other.txt
            \\e37276a93ac1e99188340e3f61e3673b file.rs
            \\
            ,
            .build_matcher = &struct {
                fn build(builder: *PathMatcherBuilder) anyerror!void {
                    try builder.block("foo/bar/");
                    try builder.allow("**/*.md5");
                    try builder.allow("**/*.bin");
                    try builder.allow("**/*.foo");
                    try builder.allow("**/*.txt");
                }
            }.build,
            .expected_paths = &.{
                "bar/baz/baz_2025-06-28.foo",
                "foo/foo.bin",
                "foo/foo.txt",
                "test.md5",
            },
            .expected_progress = &[_]prog.IncrementalProgress{
                .{ .discover_files_done = .{ .files = 5, .ignored = 4 } },
                .{ .discover_files_ignored = "file.rs" },
                .{ .discover_files_ignored = "root.mp4" },
                .{ .discover_files_ignored = "bar/baz/save.sav" },
                .{ .discover_files_ignored = "foo/bar" },
                .{ .discover_files_found = 1 },
                .{ .discover_files_found = 2 },
                .{ .discover_files_found = 3 },
                .{ .discover_files_found = 4 },
                .{ .discover_files_found = 5 },
            },
            .check_build_most_current = true,
        },
    };

    for (tests) |tt| {
        var tmp = helpers.tmpDirWithPath(.{ .iterate = true });
        defer tmp.cleanup();

        try helpers.createTestFiles(testing.io, tmp.tmp.dir, tt.test_files);
        try tmp.tmp.dir.writeFile(testing.io, .{
            .sub_path = "test.md5",
            .data = tt.hash_file_content,
        });

        var matcher: ?PathMatcher = null;
        if (tt.build_matcher) |build_fn| {
            var builder = PathMatcherBuilder.init(testing.allocator);
            try build_fn(&builder);
            matcher = try builder.build();
        }
        defer if (matcher) |*m| m.deinit(testing.allocator);

        const options = Options{
            .hash_type = .md5,
            .incremental_include_unchanged_files = true,
            .incremental_skip_unchanged = false,
            .incremental_periodic_write_interval = null,
            .discover_hash_files_depth = null,
            .most_current_filter_deleted = true,
            .hash_files_matcher = .{ .allow = &.{}, .block = &.{} },
            .all_files_matcher = matcher orelse .{ .allow = &.{}, .block = &.{} },
        };

        var helper = try ChecksumHelper.withOptions(
            testing.io,
            testing.allocator,
            tmp.absolute_path,
            options,
        );
        defer helper.deinit();

        const Capture = helpers.CallbackCapture(prog.IncrementalProgress);
        var capture = Capture.init(testing.allocator);
        defer capture.deinit();

        var result = try helper.fillMissing(&Capture.cb, &capture);
        defer result.deinit();

        // collect and sort relative paths from result collection
        var rel_paths = std.ArrayList([]const u8).empty;
        defer rel_paths.deinit(testing.allocator);

        var iter = result.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const rel = std.mem.cutPrefix(u8, key, result.root()) orelse key;
            const trimmed = if (rel.len > 0 and std.fs.path.isSep(rel[0])) rel[1..] else rel;
            try rel_paths.append(testing.allocator, trimmed);
        }

        std.mem.sortUnstable([]const u8, rel_paths.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        try helpers.expectEqualStringSlices(tt.expected_paths, rel_paths.items);

        if (tt.expected_progress) |ep| {
            for (ep) |e| {
                var found = false;
                for (capture.captures.items) |a| {
                    if (helpers.deepEql(e, a)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    std.debug.print("expected event not found: {any}\n", .{e});
                    return error.TestExpectedEqual;
                }
            }
        }

        if (tt.check_build_most_current) {
            var found_found_file = false;
            var found_merge_hash = false;
            for (capture.captures.items) |a| {
                if (a == .build_most_current) {
                    switch (a.build_most_current) {
                        .found_file => found_found_file = true,
                        .merge_hash_file => found_merge_hash = true,
                        else => {},
                    }
                }
            }
            try testing.expect(found_found_file);
            try testing.expect(found_merge_hash);
        }
    }
}
