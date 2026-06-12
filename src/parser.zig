const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Collection = @import("collection.zig").Collection;
const PathStore = @import("store.zig").PathStore;
const File = @import("file.zig").File;
const HashType = @import("hash.zig").HashType;

pub const ParseResult = struct {
    result: Collection,
};

pub const Error = error{
    MalformedHeader,
    Malformed,
    MissingHashType,
    MissingHash,
    MissingPath,
    OutOfMemory,
} || PathStore.Error || Collection.Error || Io.Reader.Error || Io.Reader.DelimiterError || std.fmt.ParseFloatError || std.fmt.ParseIntError || HashType.Error || std.fmt.BufPrintError || error{InvalidLength};

pub fn parse(
    allocator: std.mem.Allocator,
    store: *PathStore,
    reader: *Io.Reader,
    collection_path: []const u8,
) Error!ParseResult {
    var seen_header = false;
    var version: u32 = 0;
    var collection = try Collection.init(allocator, collection_path);
    const alloc = collection.arena.allocator();
    errdefer collection.deinit();
    while (try reader.takeDelimiter('\n')) |line| {
        if (!seen_header) {
            seen_header = true;
            if (line.len > 0 and line[0] == '#') {
                version = try parseHeader(line);
                continue;
            }
        }

        if (line.len == 0) {
            continue;
        }

        if (line[0] == '#') {
            // skip comment
            continue;
        }

        const file = try parseLine(alloc, store, collection.root_path, version, line);
        try collection.putNoClobber(file);
    }

    return .{
        .result = collection,
    };
}

fn parseHeader(input: []const u8) Error!u32 {
    if (!std.mem.startsWith(u8, input, "# version ")) {
        return 0;
    }

    const version_str = std.mem.trim(u8, input[10..], " ");
    const version = std.fmt.parseInt(u32, version_str, 10) catch {
        return Error.MalformedHeader;
    };
    return version;
}

fn parseLine(
    allocator: std.mem.Allocator,
    store: *PathStore,
    path_prefix: []const u8,
    version: u32,
    line: []const u8,
) Error!File {
    // 0: mtime?,htype,hash path
    // 1: mtime?,size?,htype,hash path
    var current = line;
    const mtime = try parseMTime(&current);

    var size: ?u64 = null;
    if (version > 0) {
        size = try parseSize(&current);
    }

    const hash_type = try parseHashType(&current);
    const hash_bytes = try parseHash(allocator, &current);

    if (current.len == 0) {
        return Error.MissingPath;
    }

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var fixed_alloc = std.heap.FixedBufferAllocator.init(&buf);
    const joined = try std.fs.path.join(
        fixed_alloc.allocator(),
        &[_][]const u8{
            path_prefix,
            current,
        },
    );

    const path = try store.store(joined);

    const file = File{
        .path = path,
        .mtime = mtime,
        .size = size,
        .hash_type = hash_type,
        .hash_bytes = hash_bytes,
    };

    return file;
}

fn parseMTime(line: *[]const u8) Error!?Io.Timestamp {
    const end_index = std.mem.findScalar(u8, line.*, ',') orelse return Error.Malformed;
    const mtime_str = line.*[0..end_index];
    if (mtime_str.len == 0) {
        line.* = line.*[end_index + 1 ..];
        return null;
    }

    const mtimef = try std.fmt.parseFloat(f64, mtime_str);
    const ts = timeStampFromF64(mtimef);

    line.* = line.*[end_index + 1 ..];

    return ts;
}

fn timeStampFromF64(timestamp: f64) Io.Timestamp {
    const secs_f = @floor(timestamp);
    const frac = timestamp - secs_f;

    const seconds = @trunc(timestamp);

    // convert fractional part -> nanoseconds
    const sec_to_nanos = 1_000_000_000.0;
    const nanos_f = frac * sec_to_nanos;
    const nanos: u32 = @intFromFloat(@round(nanos_f));

    // handle rounding overflow (e.g. 0.9999999996 -> 1e9)
    if (nanos == 1_000_000_000) {
        return Io.Timestamp{
            .nanoseconds = @round((seconds + 1) * sec_to_nanos),
        };
    }

    return Io.Timestamp{
        .nanoseconds = @round(seconds * sec_to_nanos + nanos),
    };
}

fn parseSize(line: *[]const u8) Error!?u64 {
    const end_index = std.mem.findScalar(u8, line.*, ',') orelse return Error.Malformed;
    const size_str = line.*[0..end_index];
    if (size_str.len == 0) {
        line.* = line.*[end_index + 1 ..];
        return null;
    }

    const size = try std.fmt.parseInt(u64, size_str, 10);

    line.* = line.*[end_index + 1 ..];

    return size;
}

fn parseHashType(line: *[]const u8) Error!HashType {
    const end_index = std.mem.findScalar(u8, line.*, ',') orelse return Error.Malformed;
    const hash_type_str = line.*[0..end_index];
    if (hash_type_str.len == 0) {
        return Error.MissingHashType;
    }

    line.* = line.*[end_index + 1 ..];

    const hash_type = try HashType.from(hash_type_str);
    return hash_type;
}

fn parseHash(allocator: std.mem.Allocator, line: *[]const u8) Error![]const u8 {
    const end_index = std.mem.findScalar(u8, line.*, ' ') orelse return Error.Malformed;
    const hash_bytes_str = line.*[0..end_index];
    if (hash_bytes_str.len == 0) {
        return Error.MissingHash;
    }

    const bytes_len = hash_bytes_str.len / 2;
    const buf = try allocator.alloc(u8, bytes_len);
    errdefer allocator.free(buf);
    _ = try std.fmt.hexToBytes(buf, hash_bytes_str);

    line.* = line.*[end_index + 1 ..];

    return buf;
}

test "version 1: full" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input =
        \\# version 1
        \\1337.00133,42069,md5,deadbeef foo/bar/file.txt
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
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)).addDuration(
            .fromNanoseconds(1_330_000),
        ),
        .size = 42069,
        .hash_type = .md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });
    const expected = Collection{
        .mtime = null,
        .root_path = collection_root,
        .name = "baz.cshd",
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
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection);
    defer actual.result.deinit();
    try helpers.exepectEqualCollection(expected, actual.result);
}

test "version 1: optional fields missing" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input =
        \\# version 1
        \\,,md5,deadbeef foo/bar/file.txt
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
        .name = "baz.cshd",
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
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection);
    defer actual.result.deinit();
    try helpers.exepectEqualCollection(expected, actual.result);
}

test "version 0: full" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input =
        \\1337.00133,md5,deadbeef foo/bar/file.txt
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
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)).addDuration(
            .fromNanoseconds(1_330_000),
        ),
        .size = null,
        .hash_type = .md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });
    const expected = Collection{
        .mtime = null,
        .root_path = collection_root,
        .name = "baz.cshd",
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
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection);
    defer actual.result.deinit();
    try helpers.exepectEqualCollection(expected, actual.result);
}

test "version 0: optional fields missing" {
    const helpers = @import("test_helpers.zig");

    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_end_idx = try std.process.currentPath(testing.io, &buf);
    const abs = buf[0..abs_end_idx];
    const input =
        \\,md5,deadbeef foo/bar/file.txt
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
        .name = "baz.cshd",
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
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection);
    defer actual.result.deinit();
    try helpers.exepectEqualCollection(expected, actual.result);
}

test "empty" {
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
        .name = "baz.cshd",
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
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    var actual = try parse(testing.allocator, &store, &reader, path_collection);
    defer actual.result.deinit();
    try helpers.exepectEqualCollection(expected, actual.result);
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
            \\# version 1
            \\,,,deadbeef foo/bar/file.txt
            \\
            ,
            .expected_error = Error.MissingHashType,
        },
        .{
            .input =
            \\,,deadbeef foo/bar/file.txt
            \\
            ,
            .expected_error = Error.MissingHashType,
        },
        .{
            .input =
            \\# version 1
            \\,,foohash,deadbeef foo/bar/file.txt
            \\
            ,
            .expected_error = Error.UnknownHashType,
        },
        .{
            .input =
            \\,foohash,deadbeef foo/bar/file.txt
            \\
            ,
            .expected_error = Error.UnknownHashType,
        },
        .{
            .input =
            \\# version 1
            \\,,md5, foo/bar/file.txt
            \\
            ,
            .expected_error = Error.MissingHash,
        },
        .{
            .input =
            \\,md5, foo/bar/file.txt
            \\
            ,
            .expected_error = Error.MissingHash,
        },
        .{
            .input =
            \\# version 1
            \\,,md5,deadbeef 
            \\
            ,
            .expected_error = Error.MissingPath,
        },
        .{
            .input =
            \\,md5,deadbeef 
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
        .{
            .input =
            \\# version    foo
            \\
            ,
            .expected_error = Error.MalformedHeader,
        },
    };

    const path_collection = try std.fs.path.join(testing.allocator, &[_][]const u8{
        abs,
        "xer",
        "baz",
        "baz.cshd",
    });
    defer testing.allocator.free(path_collection);

    for (input_expected_error) |tt| {
        std.log.debug("parse input:\n---\n{s}\n---\n", .{tt.input});
        std.log.debug("expect error: {}\n", .{tt.expected_error});
        var store = PathStore.init(testing.allocator, 100);
        defer store.deinit();

        var reader = Io.Reader.fixed(tt.input);

        const err = parse(testing.allocator, &store, &reader, path_collection);
        try testing.expectError(tt.expected_error, err);
    }
}
