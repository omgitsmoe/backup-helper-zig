const std = @import("std");
const std_path = std.fs.path;
const HashType = @import("hash.zig").HashType;
const Io = std.Io;

const prog = @import("progress.zig");
const mc = @import("most_current.zig");

const PathMatcher = @import("matcher.zig").PathMatcher;
const PathStore = @import("store.zig").PathStore;
const Collection = @import("collection.zig").Collection;
const Serializer = @import("serializer.zig").Serializer;
const Incremental = @import("incremental.zig").Incremental;

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

        return .{
            .io = io,
            .allocator = allocator,
            .root = use_root,
            .store = PathStore.init(allocator, 64 * 1024),
            .options = options,
            .most_current = null,
        };
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
        var inc = Incremental.init(
            self.io,
            self.allocator,
            self.root,
            &self.store,
            &most_current,
            .{},
        );
        return inc.generate(progress, context);
    }

    /// Generate a [`HashCollection`], which only contains the hashes of
    /// files that do not have checksum in any matched hash file yet.
    pub fn fillMissing(
        self: *ChecksumHelper,
        progress: ?prog.IncrementalProgressFn,
        context: *anyopaque,
    ) !Collection {
        _ = self; // autofix
        _ = progress; // autofix
        _ = context; // autofix
    }

    /// Returns a result object containing all individual files that do not have checksums
    /// in `self.root` yet.
    /// If a directory has files and is completely missing it will be listed
    /// in `directories`.
    /// Note: The files of that directory will not appear in the file list.
    pub fn checkMissing(
        self: *ChecksumHelper,
        progress: ?prog.MostCurrentProgressFn,
        context: *anyopaque,
    ) !CheckMissingResult {
        _ = self; // autofix
        _ = progress; // autofix
        _ = context; // autofix
    }

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
                self.options,
                progress,
                context,
            );
        }

        return &self.most_current.?;
    }

    pub fn clearMostCurrent(self: *ChecksumHelper) !void {
        if (self.most_current) |most_current| {
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
        var ser = Serializer.init(writer, collection);
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
        progress: ?prog.VerifyProgressFn,
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
        progress: ?prog.VerifyRootProgressFn,
        context: *anyopaque,
    ) !void {
        const mapper = prog.VerifyRootMapper{
            .progress = progress,
            .context = context,
        };

        const most_current = try self.mostCurrent(
            &prog.VerifyRootMapper.cbMostCurrent,
            &mapper,
        );

        try most_current.verify(
            self.io,
            include,
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

    // YYYY-MM-DDTHHMMSS
    //                  ^ 18
    const time_string_bytes_max = 20;
    var buf: [Io.Dir.max_name_bytes + time_string_bytes_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);

    try writer.print("{s}_{s}", .{ base, infix });
    try now.formatNumber(&writer, .{});

    const dupe = allocator.dupe(u8, writer.buffered());
    return dupe;
}
