const std = @import("std");
const VerifyResult = @import("file.zig").VerifyResult;

pub const MostCurrentProgressFn = *const fn (
    progress: MostCurrentProgress,
    context: *anyopaque,
) anyerror!void;

pub const IncrementalProgressFn = *const fn (
    progress: IncrementalProgress,
    context: *anyopaque,
) anyerror!void;

pub const VerifyProgressFn = *const fn (
    progress: VerifyProgress,
    context: *anyopaque,
) anyerror!void;

pub const HashProgressFn = *const fn (
    progress: HashProgress,
    context: *anyopaque,
) anyerror!void;

pub const MostCurrentProgress = union(enum) {
    /// Found a hash file that will be included in the most current hash file.
    found_file: []const u8,
    /// Ignored a file or directory path. Not used when pre-filtering known hash file
    /// extensions.
    ignored_path: []const u8,
    /// Load and merge hash file into most current.
    merge_hash_file: []const u8,

    pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This() {
        return switch (self) {
            .found_file => |v| .{
                .found_file = try allocator.dupe(u8, v),
            },
            .ignored_path => |v| .{
                .ignored_path = try allocator.dupe(u8, v),
            },
            .merge_hash_file => |v| .{
                .merge_hash_file = try allocator.dupe(u8, v),
            },
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        const active_tag = std.meta.activeTag(self);
        try writer.print("MostCurrentProgress{{ .{s} = {s} }}", .{
            @tagName(active_tag),
            switch (self) {
                .ignored_path, .found_file, .merge_hash_file => |v| v,
            },
        });
    }
};

pub const IncrementalProgress = union(enum) {
    build_most_current: MostCurrentProgress,
    /// Found a file that will be included in check summing.
    discover_files_found: u64,
    /// Ignored a path (file or directory).
    discover_files_ignored: []const u8,
    /// Finished discovering files to hash: number of files to hash, number of ignored files or
    /// directories. Note that the number of ignored files does not contain
    /// the amount of ignored files, which would be discovered in ignored directories.
    discover_files_done: struct { files: usize, ignored: usize },
    /// Path relative to the ChecksumHelper root of the file that is going to be hashed next.
    pre_read: []const u8,
    /// Read progress in bytes: read, total.
    read: struct { read: u64, total: u64 },
    /// File matched the recorded hash. The path is relative to the ChecksumHelper root.
    file_match: []const u8,
    /// Skipped a file, which matched the recorded `mtime`.
    /// Turn this behaviour on or off using `ChecksumHelperOptions::incremental_skip_unchanged`.
    /// The path is relative to the ChecksumHelper root.
    file_unchanged_skipped: []const u8,
    /// File changed with a newer `mtime` compared to the recorded one or there
    /// was no recorded `mtime`.
    /// The path is relative to the ChecksumHelper root.
    file_changed: []const u8,
    /// File matched the recorded `mtime`, but the computed hash was different.
    /// The path is relative to the ChecksumHelper root.
    file_changed_corrupted: []const u8,
    /// File changed, where the `mtime` of the file on disk is __older__ than the
    /// recorded `mtime`.
    /// The path is relative to the ChecksumHelper root.
    file_changed_older: []const u8,
    /// The path is relative to the ChecksumHelper root.
    file_new: []const u8,
    /// The path is relative to the ChecksumHelper root.
    file_removed: []const u8,
    finished,

    pub fn clone(self: @This(), allocator: std.mem.Allocator) anyerror!@This() {
        return switch (self) {
            .build_most_current => |v| .{
                .build_most_current = try v.clone(allocator),
            },

            .discover_files_found => |v| .{
                .discover_files_found = v,
            },

            .discover_files_ignored => |v| .{
                .discover_files_ignored = try allocator.dupe(u8, v),
            },

            .discover_files_done => |v| .{
                .discover_files_done = v,
            },

            .pre_read => |v| .{
                .pre_read = try allocator.dupe(u8, v),
            },

            .read => |v| .{
                .read = v,
            },

            .file_match => |v| .{
                .file_match = try allocator.dupe(u8, v),
            },

            .file_unchanged_skipped => |v| .{
                .file_unchanged_skipped = try allocator.dupe(u8, v),
            },

            .file_changed => |v| .{
                .file_changed = try allocator.dupe(u8, v),
            },

            .file_changed_corrupted => |v| .{
                .file_changed_corrupted = try allocator.dupe(u8, v),
            },

            .file_changed_older => |v| .{
                .file_changed_older = try allocator.dupe(u8, v),
            },

            .file_new => |v| .{
                .file_new = try allocator.dupe(u8, v),
            },

            .file_removed => |v| .{
                .file_removed = try allocator.dupe(u8, v),
            },

            .finished => .finished,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        const tag = std.meta.activeTag(self);

        try writer.print("IncrementalProgress{{ .{s} = ", .{@tagName(tag)});

        switch (self) {
            .build_most_current => |v| {
                try v.format(writer);
            },

            .discover_files_found => |v| {
                try writer.print("{}", .{v});
            },

            .discover_files_ignored => |v| {
                try writer.print("{s}", .{v});
            },

            .discover_files_done => |v| {
                try writer.print("{{ files = {}, ignored = {} }}", .{
                    v.files,
                    v.ignored,
                });
            },

            .pre_read => |v| {
                try writer.print("{s}", .{v});
            },

            .read => |v| {
                try writer.print("{{ read = {}, total = {} }}", .{
                    v.read,
                    v.total,
                });
            },

            .file_match,
            .file_unchanged_skipped,
            .file_changed,
            .file_changed_corrupted,
            .file_changed_older,
            .file_new,
            .file_removed,
            => |v| {
                try writer.print("{s}", .{v});
            },

            .finished => {
                try writer.writeAll("finished");
            },
        }

        try writer.writeAll(" }");
    }
};

pub const HashProgress = struct {
    bytes_read: u64,
    bytes_total: u64,
};

pub const VerifyProgress = struct {
    pre: VerifyProgressCommon,
    during: HashProgress,
    post: VerifyProgressPost,
};

pub const VerifyProgressCommon = struct {
    tree_root: []const u8,
    relative_path: []const u8,
    file_number_processed: u64,
    file_number_total: u64,
    /// The number of bytes processed so far.
    ///
    /// Note that only files which have size information stored in the
    /// checksum file count towards the processed bytes.
    size_processed_bytes: u64,
    /// The number of bytes to process in total.
    ///
    /// Note that only files which have size information stored in the
    /// checksum file count towards the total bytes to process.
    size_total_bytes: u64,
};

pub const VerifyProgressPost = struct {
    progress: VerifyProgressCommon,
    result: VerifyResult,
};
