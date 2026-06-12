const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;
const testing = std.testing;
const path = std.fs.path;

const hash = @import("hash.zig");
const prog = @import("progress.zig");

pub const VerifyResult = enum {
    /// The hashes matched.
    ok,

    /// Could not compare hashes, since the file on disk was not found
    /// or there were permission errors. Inspect the `std::io::ErrorKind`
    /// to find the concrete reason.
    file_missing, // TODO io error kind?

    /// The file on disk did not match the stored hash. There was no stored
    /// modification time, so it is unknown whether the file is corrupted.
    mismatch,

    /// The size of the file on disk did not match. No hashes were computed!
    mismatch_size,

    /// The file on disk did not match the stored hash. Since the modification
    /// time matches with the file on disk, we can assume that the file has
    /// very likely been corrupted.
    mismatch_corrupted,

    /// The file on disk did not match the stored hash, but the modification
    /// time of the file on disk is newer or older compared to the stored
    /// modification time. The stored hash might be outdated.
    mismatch_outdated_hash,
};

pub const File = struct {
    // owned by PathStore
    path: []const u8,
    mtime: ?Io.Timestamp,
    size: ?u64,
    hash_type: hash.HashType,
    hash_bytes: []const u8,

    pub fn metadata_from_disk(self: *@This(), io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(
            io,
            self.path,
            .{ .allow_directory = false, .path_only = true },
        );
        defer file.close(io);

        const st = try file.stat(io);
        self.mtime = st.mtime;
        self.size = st.size;
    }

    const hashFileCbContext = struct {
        bytes_total: u64,
        progress: ?prog.HashProgressFn,
        context: *anyopaque,
    };

    fn hashFileCb(bytes_read: u64, context: *anyopaque) anyerror!void {
        const cb_context: *hashFileCbContext = @ptrCast(@alignCast(context));

        if (cb_context.progress) |progress_fn| {
            try progress_fn(.{
                .bytes_read = bytes_read,
                .bytes_total = cb_context.bytes_total,
            }, cb_context.context);
        }
    }

    pub fn hash_from_disk(
        self: *@This(),
        io: Io,
        allocator: std.mem.Allocator,
        progress: ?prog.HashProgressFn,
        context: *anyopaque,
    ) !void {
        const file = try Io.Dir.openFileAbsolute(
            io,
            self.path,
            .{ .allow_directory = false },
        );
        defer file.close(io);

        const stat = try file.stat(io);
        var cb_context = hashFileCbContext{
            .bytes_total = stat.size,
            .progress = progress,
            .context = context,
        };

        inline for (std.meta.fields(hash.HashType)) |f| {
            if (self.hash_type == @field(hash.HashType, f.name)) {
                const ht = @field(hash.HashType, f.name);

                const hash_bytes = try hash.hashFile(io, file, ht, &hashFileCb, &cb_context);
                self.hash_bytes = try allocator.dupe(u8, &hash_bytes);
                return;
            }
        }

        unreachable;
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.hash_bytes.len > 0) {
            allocator.free(self.hash_bytes);
        }
    }

    // pub fn verify(self: *@This(), progress: ?prog.HashProgressFn) VerifyResult {
    // }
};

test "metadata_from_disk" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    const expectedMtime = Io.Timestamp.zero.addDuration(.fromSeconds(100));
    const expectedSize = 3;
    try helpers.createTestFiles(testing.io, tmp.tmp.dir, &[_]helpers.TestFile{
        .{
            .relativePath = "foo/bar/file.txt",
            .mtime = expectedMtime,
            .content = "foo",
        },
    });

    const file_path = try path.join(testing.allocator, &[_][]const u8{
        tmp.absolute_path,
        "foo",
        "bar",
        "file.txt",
    });
    defer testing.allocator.free(file_path);
    var file = File{
        .path = file_path,
        .mtime = null,
        .size = null,
        .hash_type = hash.HashType.md5,
        .hash_bytes = &.{},
    };
    defer file.deinit(testing.allocator);

    try file.metadata_from_disk(testing.io);

    try testing.expectEqual(file_path, file.path);
    try testing.expectEqual(expectedMtime, file.mtime);
    try testing.expectEqual(expectedSize, file.size);
}

test "metadata_from_disk: FileNotFound" {
    const helpers = @import("test_helpers.zig");
    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    const file_path = try path.join(testing.allocator, &[_][]const u8{
        tmp.absolute_path,
        "this",
        "path",
        "does",
        "not",
        "exit",
    });
    defer testing.allocator.free(file_path);
    var file = File{
        .path = file_path,
        .mtime = null,
        .size = null,
        .hash_type = hash.HashType.md5,
        .hash_bytes = &.{},
    };
    defer file.deinit(testing.allocator);

    const actual = file.metadata_from_disk(testing.io);
    if (actual != error.FileNotFound) {
        try std.testing.expect(false);
    }
}

test "hash_from_disk" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    const expectedMd5 = [_]u8{
        0xfc, 0x3f, 0xf9, 0x8e, 0x8c, 0x6a, 0x0d, 0x30, 0x87, 0xd5,
        0x15, 0xc0, 0x47, 0x3f, 0x86, 0x77,
    };
    const expectedSha256 = [_]u8{
        0x75, 0x09, 0xe5, 0xbd, 0xa0, 0xc7, 0x62, 0xd2, 0xba, 0xc7, 0xf9,
        0x0d, 0x75, 0x8b, 0x5b, 0x22, 0x63, 0xfa, 0x01, 0xcc, 0xbc, 0x54,
        0x2a, 0xb5, 0xe3, 0xdf, 0x16, 0x3b, 0xe0, 0x8e, 0x6c, 0xa9,
    };
    try helpers.createTestFiles(testing.io, tmp.tmp.dir, &[_]helpers.TestFile{
        .{
            .relativePath = "foo/bar/file.txt",
            .mtime = null,
            .content = "hello world!",
        },
    });

    const file_path = try path.join(testing.allocator, &[_][]const u8{
        tmp.absolute_path,
        "foo",
        "bar",
        "file.txt",
    });
    defer testing.allocator.free(file_path);

    {
        const CaptureType = helpers.CallbackCapture(prog.HashProgress);
        var capture: CaptureType = .init(testing.allocator);
        defer capture.deinit();

        var file = File{
            .path = file_path,
            .mtime = null,
            .size = null,
            .hash_type = hash.HashType.md5,
            .hash_bytes = &.{},
        };
        defer file.deinit(testing.allocator);

        try file.hash_from_disk(
            testing.io,
            testing.allocator,
            &CaptureType.cb,
            &capture,
        );

        try testing.expectEqualSlices(u8, &expectedMd5, file.hash_bytes);
        try helpers.expectEqualSlicesDeep(
            prog.HashProgress,
            &[_]prog.HashProgress{
                .{ .bytes_read = 12, .bytes_total = 12 },
            },
            capture.captures.items,
        );
    }

    {
        const CaptureType = helpers.CallbackCapture(prog.HashProgress);
        var capture: CaptureType = .init(testing.allocator);
        defer capture.deinit();

        var file = File{
            .path = file_path,
            .mtime = null,
            .size = null,
            .hash_type = hash.HashType.sha256,
            .hash_bytes = &.{},
        };
        defer file.deinit(testing.allocator);

        try file.hash_from_disk(
            testing.io,
            testing.allocator,
            &CaptureType.cb,
            &capture,
        );

        try testing.expectEqualSlices(u8, &expectedSha256, file.hash_bytes);
        try helpers.expectEqualSlicesDeep(
            prog.HashProgress,
            &[_]prog.HashProgress{
                .{ .bytes_read = 12, .bytes_total = 12 },
            },
            capture.captures.items,
        );
    }
}
