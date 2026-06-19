const std = @import("std");
const bh = @import("backup_helper_zig");
const prog = bh.progress;
const File = std.Io.File;
const CallbackError = prog.CallbackError;

pub const ProgressReporter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    checksum_files_found: u64 = 0,
    checksum_files_ignored: u64 = 0,
    files_found: u64 = 0,
    files_ignored: u64 = 0,
    current_file: ?[]const u8 = null,

    pub fn deinit(self: *ProgressReporter) void {
        if (self.current_file) |f| self.allocator.free(f);
    }

    pub fn reportMostCurrent(self: *ProgressReporter, progress: prog.MostCurrentProgress) CallbackError!void {
        switch (progress) {
            .merge_hash_file => |path| {
                try self.print("\n[MERGE] {s}\n", .{path});
            },
            .found_file => {
                self.checksum_files_found += 1;
                try self.print("\rMost current: {d:0>3} files (+ {d:0>3} ignored)", .{
                    self.checksum_files_found,
                    self.checksum_files_ignored,
                });
            },
            .ignored_path => |path| {
                self.checksum_files_ignored += 1;
                try self.print("\n[IGN  ] {s}\n", .{path});
            },
        }
    }

    pub fn reportIncremental(self: *ProgressReporter, progress: prog.IncrementalProgress) CallbackError!void {
        switch (progress) {
            .build_most_current => |p| {
                try self.reportMostCurrent(p);
            },
            .discover_files_found => |found| {
                self.files_found = found;
                try self.print("\rFound files: {d:0>3} (+ {d:0>3} ignored)", .{
                    self.files_found,
                    self.files_ignored,
                });
            },
            .discover_files_ignored => {
                self.files_ignored += 1;
            },
            .discover_files_done => |info| {
                try self.print("\nIncremental: Discovering done, found {} (+ {} ignored)\n", .{
                    info.files,
                    info.ignored,
                });
            },
            .pre_read => |path| {
                if (self.current_file) |f| self.allocator.free(f);
                self.current_file = try self.allocator.dupe(u8, path);
                try self.print("\n[READ ] {s}\n", .{path});
            },
            .read => |info| {
                if (self.current_file) |path| {
                    const basename = std.fs.path.basename(path);
                    try self.print("\r[READ ] {s} {d:>8} / {d:>8} bytes", .{
                        basename,
                        info.read,
                        info.total,
                    });
                } else {
                    try self.print("\r[READ ] {d:>8} / {d:>8} bytes", .{
                        info.read,
                        info.total,
                    });
                }
            },
            .file_match => |path| {
                try self.print("\r[OK   ] {s} unchanged\n", .{path});
            },
            .file_unchanged_skipped => |path| {
                try self.print("\r[SKIP ] {s} (unchanged, skipped)\n", .{path});
            },
            .file_changed => |path| {
                try self.print("\r[CHG  ] {s} modified\n", .{path});
            },
            .file_changed_corrupted => |path| {
                try self.print("\r[CORR ] {s} corrupted\n", .{path});
            },
            .file_changed_older => |path| {
                try self.print("\r[OLD  ] {s} local newer than hash\n", .{path});
            },
            .file_new => |path| {
                try self.print("\r[NEW  ] {s}\n", .{path});
            },
            .file_removed => |path| {
                try self.print("\r[DEL  ] {s}\n", .{path});
            },
            .finished => {
                try self.print("\nDone.\n", .{});
            },
        }
    }

    pub fn reportVerify(self: *ProgressReporter, progress: prog.VerifyProgress) CallbackError!void {
        switch (progress) {
            .pre => |common| {
                if (self.current_file) |f| self.allocator.free(f);
                self.current_file = try self.allocator.dupe(u8, common.relative_path);

                try self.print("\n[VERIFY] ({d:>4}/{d:>4}) {s}\n", .{
                    common.file_number_processed,
                    common.file_number_total,
                    common.relative_path,
                });
                try self.print("[PROG ] bytes {d:>10} / {d:>10}\n", .{
                    common.size_processed_bytes,
                    common.size_total_bytes,
                });
            },
            .during => |hash| {
                const percent: f64 = if (hash.bytes_total > 0)
                    @as(f64, @floatFromInt(hash.bytes_read)) / @as(f64, @floatFromInt(hash.bytes_total)) * 100.0
                else
                    0.0;

                if (self.current_file) |path| {
                    const basename = std.fs.path.basename(path);
                    try self.print("\r[HASH ] {s:<30} {d:>8}/{d:>8} bytes ({d:>5.1}%)", .{
                        basename,
                        hash.bytes_read,
                        hash.bytes_total,
                        percent,
                    });
                } else {
                    try self.print("\r[HASH ] {d:>8}/{d:>8} bytes", .{
                        hash.bytes_read,
                        hash.bytes_total,
                    });
                }
            },
            .post => |post| {
                const status = switch (post.result) {
                    .ok => "[OK        ]",
                    .file_missing => "[ERR MISS  ]",
                    .mismatch => "[ERR HASH  ]",
                    .mismatch_size => "[ERR SIZE  ]",
                    .mismatch_corrupted => "[ERR CORR  ]",
                    .mismatch_outdated_hash => "[WARN STALE]",
                };
                try self.print("\r{s} {s}\n", .{ status, post.progress.relative_path });
            },
        }
    }

    pub fn reportVerifyRoot(self: *ProgressReporter, progress: prog.VerifyRootProgress) CallbackError!void {
        switch (progress) {
            .most_current => |p| try self.reportMostCurrent(p),
            .verify => |p| try self.reportVerify(p),
        }
    }

    pub fn cbMostCurrent(p: prog.MostCurrentProgress, ctx: *anyopaque) CallbackError!void {
        const self: *ProgressReporter = @ptrCast(@alignCast(ctx));
        try self.reportMostCurrent(p);
    }

    pub fn cbIncremental(p: prog.IncrementalProgress, ctx: *anyopaque) CallbackError!void {
        const self: *ProgressReporter = @ptrCast(@alignCast(ctx));
        try self.reportIncremental(p);
    }

    pub fn cbVerify(p: prog.VerifyProgress, ctx: *anyopaque) CallbackError!void {
        const self: *ProgressReporter = @ptrCast(@alignCast(ctx));
        try self.reportVerify(p);
    }

    pub fn cbVerifyRoot(p: prog.VerifyRootProgress, ctx: *anyopaque) CallbackError!void {
        const self: *ProgressReporter = @ptrCast(@alignCast(ctx));
        try self.reportVerifyRoot(p);
    }

    fn print(self: *ProgressReporter, comptime fmt: []const u8, args: anytype) CallbackError!void {
        var buf: [2048]u8 = undefined;
        var w = File.stderr().writer(self.io, &buf);
        w.interface.print(fmt, args) catch return error.CallbackFailed;
        w.interface.flush() catch return error.CallbackFailed;
    }
};
