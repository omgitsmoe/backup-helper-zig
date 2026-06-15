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
        var result = try Collection.init(self.allocator, self.root, name);

        var dir = try Io.Dir.openDirAbsolute(self.io, self.root, .{});
        defer dir.close(self.io);
        var file = try dir.openFile(self.io, result.name, .{ .allow_directory = false });
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
                self.allocator,
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

test "Incremental" {
    _ = testing.refAllDecls(Incremental);
}
