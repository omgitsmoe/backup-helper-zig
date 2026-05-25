const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;

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
