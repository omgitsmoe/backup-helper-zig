const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Collection = @import("collection.zig").Collection;
const PathStore = @import("store.zig").PathStore;
const File = @import("file.zig").File;
const HashType = @import("hash.zig").HashType;

pub const Serializer = struct {
    writer: *Io.Writer,
    collection: *const Collection,
    header_written: bool = false,
    path_buf: [Io.Dir.max_path_bytes]u8,

    pub fn init(writer: *Io.Writer, collection: *const Collection) @This() {
        return .{
            .writer = writer,
            .collection = collection,
            .path_buf = undefined,
        };
    }

    pub fn flush(self: *@This()) !void {
        if (self.collection.count() == 0) {
            return;
        }

        if (!self.header_written) {
            try self.write_header();
        }

        var iter = self.collection.iterator();
        while (iter.next()) |entry| {
            const file = entry.value_ptr;
            std.debug.assert(std.mem.eql(u8, entry.key_ptr.*, file.path));

            if (file.mtime) |value| {
                try self.writer.print("{}", .{timestampToF64(value)});
            }
            try self.writer.writeByte(',');

            if (file.size) |value| {
                try self.writer.print("{}", .{value});
            }
            try self.writer.writeByte(',');

            try self.writer.print("{s},", .{file.hash_type.str()});

            var fixed_alloc = std.heap.FixedBufferAllocator.init(&self.path_buf);
            const relative = try std.fs.path.relative(
                fixed_alloc.allocator(),
                "",
                null,
                self.collection.root_path,
                file.path,
            );

            try self.writer.print("{x} {s}\n", .{ file.hash_bytes, relative });
        }

        try self.writer.flush();
    }

    fn write_header(self: *@This()) !void {
        try self.writer.writeAll("# version 1\n");
        self.header_written = true;
    }
};

fn timestampToF64(timestamp: Io.Timestamp) f64 {
    const ns = timestamp.nanoseconds;

    const billion: i96 = 1_000_000_000;

    const secs: i96 = @divTrunc(ns, billion);
    const rem_ns: i96 = @mod(ns, billion);

    return @as(f64, @floatFromInt(secs)) +
        @as(f64, @floatFromInt(rem_ns)) * 1e-9;
}

test "serialize" {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];

    const expected =
        \\# version 1
        \\1337.00133,42069,md5,deadbeef foo/bar/file.txt
        \\,,sha512,abcdef01 other/bak.bin
        \\
    ;

    const collection_root = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(collection_root);

    var input_path_to_file = std.StringHashMap(File).init(testing.allocator);
    defer input_path_to_file.deinit();

    const path1 = try std.fs.path.join(testing.allocator, &[_][]const u8{
        collection_root,
        "foo",
        "bar",
        "file.txt",
    });
    defer testing.allocator.free(path1);
    try input_path_to_file.put(path1, File{
        .path = path1,
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)).addDuration(
            .fromNanoseconds(1_330_000),
        ),
        .size = 42069,
        .hash_type = .md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });

    const path2 = try std.fs.path.join(testing.allocator, &[_][]const u8{
        collection_root,
        "other",
        "bak.bin",
    });
    defer testing.allocator.free(path2);
    try input_path_to_file.put(path2, File{
        .path = path2,
        .mtime = null,
        .size = null,
        .hash_type = .sha512,
        .hash_bytes = &[_]u8{ 0xab, 0xcd, 0xef, 0x01 },
    });
    const input = Collection{
        .mtime = null,
        .root_path = collection_root,
        .name = "baz.cshd",
        .path_to_file = input_path_to_file,
        .arena = undefined,
    };

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        collection_root,
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var w = Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var ser = Serializer.init(&w.writer, &input);
    try ser.flush();

    try testing.expectEqualStrings(expected, w.written());
}

test "Serializer only writes header once" {
    const helpers = @import("test_helpers.zig");
    const expected =
        \\# version 1
        \\,,md5,deadbeef foo/bar
        \\,,md5,deadbeef foo/bar
        \\
    ;

    var input = try Collection.init(
        testing.allocator,
        helpers.dummyAbsolutePathDir(),
        "baz.cshd",
    );
    defer input.deinit();
    try input.putNoClobber(
        .{
            .path = comptime helpers.dummyAbsolutePathDir() ++ "/foo/bar",
            .mtime = null,
            .size = null,
            .hash_bytes = &.{ 0xde, 0xad, 0xbe, 0xef },
            .hash_type = .md5,
        },
    );

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        input.root_path,
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var w = Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var ser = Serializer.init(&w.writer, &input);
    try ser.flush();
    try ser.flush();

    try testing.expectEqualStrings(expected, w.written());
}

test "Serializer skips writing if empty" {
    const helpers = @import("test_helpers.zig");
    const expected = "";

    var input_path_to_file = std.StringHashMap(File).init(testing.allocator);
    defer input_path_to_file.deinit();

    const input = Collection{
        .mtime = null,
        .root_path = helpers.dummyAbsolutePathDir(),
        .name = "baz.cshd",
        .path_to_file = input_path_to_file,
        .arena = undefined,
    };

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        input.root_path,
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var w = Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var ser = Serializer.init(&w.writer, &input);
    try ser.flush();
    try ser.flush();

    try testing.expectEqualStrings(expected, w.written());
}
