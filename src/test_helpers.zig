const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;

pub fn createFilesFromList(io: std.Io, root: Dir, fileList: []const []const u8) !void {
    for (fileList) |relativePath| {
        const dirPath = path.dirname(relativePath);
        const filename = path.basename(relativePath);

        const dir = if (dirPath) |p| blk: {
            break :blk try root.createDirPathOpen(io, p, .{});
        } else root;
        try dir.writeFile(io, .{ .sub_path = filename, .data = relativePath });
    }
}

pub const TestFile = struct {
    relativePath: []const u8,
    mtime: ?std.Io.Timestamp,
    content: []const u8,
};

pub fn createTestFiles(io: std.Io, root: Dir, files: []const TestFile) !void {
    for (files) |file| {
        const dirPath = path.dirname(file.relativePath);
        const filename = path.basename(file.relativePath);

        const dir = if (dirPath) |p| blk: {
            break :blk try root.createDirPathOpen(io, p, .{});
        } else root;
        try dir.writeFile(io, .{ .sub_path = filename, .data = file.content });

        if (file.mtime) |mtime| {
            try dir.setTimestamps(io, filename, .{ .modify_timestamp = .init(mtime) });
        }
    }
}

pub const TmpDirWithPath = struct {
    absolute_path: [:0]const u8,
    tmp: testing.TmpDir,

    pub fn cleanup(self: *@This()) void {
        testing.allocator.free(self.absolute_path);
        self.tmp.cleanup();
    }
};

pub fn tmpDirWithPath(opts: Dir.OpenOptions) TmpDirWithPath {
    comptime std.debug.assert(builtin.is_test);
    const io = testing.io;

    const tmp = testing.tmpDir(opts);

    const absolute_path = tmp.parent_dir.realPathFileAlloc(
        io,
        &tmp.sub_path,
        testing.allocator,
    ) catch
        @panic("failed to get absolute path for tmpDir");

    return .{
        .absolute_path = absolute_path,
        .tmp = tmp,
    };
}

pub fn expectEqualStringSlices(
    expected: []const []const u8,
    actual: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, actual, 0..) |e, a, i| {
        if (!std.mem.eql(u8, e, a)) {
            std.debug.print(
                "mismatch at index {}:\n  expected: {s}\n  actual:   {s}\n",
                .{ i, e, a },
            );
            return error.TestExpectedEqual;
        }
    }
}
