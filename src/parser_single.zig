const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Collection = @import("collection.zig").Collection;
const PathStore = @import("store.zig").PathStore;
const File = @import("file.zig").File;
const HashType = @import("hash.zig").HashType;

pub const Error = error{
    Malformed,
    MissingHash,
    MissingPath,
    OutOfMemory,
} || PathStore.Error || Collection.Error || Io.Reader.Error || Io.Reader.DelimiterError || std.fmt.BufPrintError || error{ InvalidLength, InvalidCharacter };

pub fn parse(
    allocator: std.mem.Allocator,
    store: *PathStore,
    reader: *Io.Reader,
    collection_root: []const u8,
    collection_name: []const u8,
    hash_type: HashType,
) Error!Collection {
    var collection = try Collection.init(allocator, collection_root, collection_name);
    const alloc = collection.arena.allocator();
    errdefer collection.deinit();
    while (try reader.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) {
            continue;
        }

        if (std.mem.cutScalar(u8, trimmed, ' ')) |hash_and_path| {
            const hash_bytes_str = hash_and_path.@"0";
            const relative_path = hash_and_path.@"1";

            if (hash_bytes_str.len == 0) {
                return Error.MissingHash;
            }

            if (relative_path.len == 0) {
                return Error.MissingPath;
            }

            const bytes_len = hash_bytes_str.len / 2;
            const hash_bytes = try alloc.alloc(u8, bytes_len);
            errdefer alloc.free(hash_bytes);
            _ = try std.fmt.hexToBytes(hash_bytes, hash_bytes_str);

            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            var fixed_alloc = std.heap.FixedBufferAllocator.init(&buf);
            const joined = try std.fs.path.join(
                fixed_alloc.allocator(),
                &[_][]const u8{
                    collection.root_path,
                    relative_path,
                },
            );

            const path = try store.store(joined);

            const file = File{
                .path = path,
                .mtime = null,
                .size = null,
                .hash_type = hash_type,
                .hash_bytes = hash_bytes,
            };
            try collection.putNoClobber(file);
        } else {
            return Error.Malformed;
        }
    }

    return collection;
}

test "single" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input =
        \\deadbeef foo/bar/file.txt
        \\
    ;

    var expected_path_to_file = std.StringHashMap(File).init(testing.allocator);
    defer expected_path_to_file.deinit();

    const path = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
        "foo",
        "bar",
        "file.txt",
    });
    defer testing.allocator.free(path);
    const collection_root = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(collection_root);

    try expected_path_to_file.put(path, File{
        .path = path,
        .mtime = null,
        .size = null,
        .hash_type = .md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });
    const expected = Collection{
        .mtime = null,
        .root_path = collection_root,
        .name = "baz.md5",
        .path_to_file = expected_path_to_file,
        .arena = undefined,
    };

    var store = PathStore.init(testing.allocator, 100);
    defer store.deinit();

    var reader = Io.Reader.fixed(input);

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection, "baz.md5", .md5);
    defer actual.deinit();
    try helpers.expectEqualCollection(expected, actual);
}

test "single empty" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input = "";

    var expected_path_to_file = std.StringHashMap(File).init(testing.allocator);
    defer expected_path_to_file.deinit();

    const collection_root = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(collection_root);

    const expected = Collection{
        .mtime = null,
        .root_path = collection_root,
        .name = "baz.md5",
        .path_to_file = expected_path_to_file,
        .arena = undefined,
    };

    var store = PathStore.init(testing.allocator, 100);
    defer store.deinit();

    var reader = Io.Reader.fixed(input);

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection, "baz.md5", .md5);
    defer actual.deinit();
    try helpers.expectEqualCollection(expected, actual);
}

test "parse errors" {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input_expected_error = [_]struct {
        input: []const u8,
        expected_error: Error,
    }{
        .{
            .input =
            \\abcd 
            \\
            ,
            .expected_error = Error.MissingPath,
        },
        .{
            .input =
            \\foo
            \\
            ,
            .expected_error = Error.Malformed,
        },
    };

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
    });
    defer testing.allocator.free(path_collection);

    for (input_expected_error) |tt| {
        std.log.debug("parse input:\n---\n{s}\n---\n", .{tt.input});
        std.log.debug("expect error: {}\n", .{tt.expected_error});
        var store = PathStore.init(testing.allocator, 100);
        defer store.deinit();

        var reader = Io.Reader.fixed(tt.input);

        const err = parse(testing.allocator, &store, &reader, path_collection, "baz.md5", .md5);
        try testing.expectError(tt.expected_error, err);
    }
}
