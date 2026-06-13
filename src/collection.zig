const std = @import("std");
const Io = std.Io;
const std_path = std.fs.path;
const testing = std.testing;

const file = @import("file.zig");
const prog = @import("progress.zig");
const hash = @import("hash.zig");
const builtin = @import("builtin");

pub const Collection = struct {
    root_path: []const u8,
    name: []const u8,
    arena: *std.heap.ArenaAllocator,
    path_to_file: std.StringHashMap(file.File),
    mtime: ?Io.Timestamp,

    const Iterator = std.StringHashMap(file.File).Iterator;

    pub const SortedIterator = struct {
        pub const Entry = struct {
            key_ptr: *const []const u8,
            value_ptr: *file.File,
        };

        map: *const std.StringHashMap(file.File),
        keys: []const []const u8,
        index: usize,

        pub fn next(self: *@This()) ?Entry {
            if (self.index >= self.keys.len) return null;
            defer self.index += 1;
            return .{
                .key_ptr = &self.keys[self.index],
                .value_ptr = self.map.getPtr(self.keys[self.index]).?,
            };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.keys);
        }
    };

    pub const Error = error{
        PathNotAbsolute,
        WouldClobber,
        OutOfMemory,
        MissingHash,
    } || prog.CallbackError;

    /// Collection does not take ownership of `path`
    pub fn init(allocator: std.mem.Allocator, path: []const u8) Error!Collection {
        if (!std_path.isAbsolute(path)) {
            return Error.PathNotAbsolute;
        }

        const normalized = try std_path.resolve(allocator, &[_][]const u8{
            path,
        });
        defer allocator.free(normalized);

        const name = std_path.basename(normalized);
        // if path is absolute, then dirname will always succeed
        const dirpath = std_path.dirname(normalized) orelse unreachable;
        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const alloc = arena.allocator();
        return .{
            .root_path = try alloc.dupe(u8, dirpath),
            .name = try alloc.dupe(u8, name),
            .arena = arena,
            .path_to_file = .init(alloc),
            .mtime = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.path_to_file.deinit();
        const child_allocator = self.arena.child_allocator;
        self.arena.deinit();
        child_allocator.destroy(self.arena);
    }

    pub fn root(self: *@This()) []const u8 {
        return self.root_path;
    }

    pub fn filename(self: *@This()) []const u8 {
        return self.name;
    }

    /// `to_add` must've been allocated by `Collection.arena`,
    /// otherwise the caller is responsible for freeing it
    pub fn put(self: *@This(), to_add: file.File) Error!void {
        try self.path_to_file.put(to_add.path, to_add);
    }

    /// `to_add` must've been allocated by `Collection.arena`,
    /// otherwise the caller is responsible for freeing it
    pub fn putNoClobber(self: *@This(), to_add: file.File) Error!void {
        // StringHashMap.putNoClobber only asserts, no error return :/
        if (self.path_to_file.contains(to_add.path)) {
            return Error.WouldClobber;
        }

        try self.path_to_file.put(to_add.path, to_add);
    }

    pub fn get(self: *@This(), path: []const u8) ?file.File {
        return self.path_to_file.get(path);
    }

    pub fn getPtr(self: *@This(), path: []const u8) ?*file.File {
        return self.path_to_file.getPtr(path);
    }

    pub fn iterator(self: *const @This()) Iterator {
        return self.path_to_file.iterator();
    }

    pub fn sortedIterator(self: *const @This(), alloc: std.mem.Allocator) !SortedIterator {
        var keys: std.ArrayList([]const u8) = .empty;
        var iter = self.iterator();
        while (iter.next()) |entry| {
            try keys.append(alloc, entry.key_ptr.*);
        }
        std.sort.pdq([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        const owned = try alloc.dupe([]const u8, keys.items);
        keys.deinit(alloc);
        return .{ .map = &self.path_to_file, .keys = owned, .index = 0 };
    }

    fn known_size_bytes(self: *const @This()) u64 {
        var iter = self.iterator();
        var bytes: u64 = 0;
        while (iter.next()) |entry| {
            bytes += entry.value_ptr.*.size orelse 0;
        }

        return bytes;
    }

    pub const IncludeFn = *const fn (relative_path: []const u8, context: *anyopaque) bool;

    pub fn verify(
        self: *const @This(),
        io: Io,
        include: ?IncludeFn,
        progress: prog.VerifyProgressFn,
        context: *anyopaque,
    ) (Error || prog.CallbackError || Io.File.OpenError || Io.File.StatError)!void {
        const alloc = self.arena.child_allocator;

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&path_buf);
        const fba = fixed.allocator();

        var file_number_processed: u64 = 0;
        const file_number_total: u64 = self.path_to_file.count();
        var size_processed_bytes: u64 = 0;
        const size_total_bytes: u64 = self.known_size_bytes();

        const V = struct {
            fba: std.mem.Allocator,
            root_path: []const u8,
            include: ?IncludeFn,
            context: *anyopaque,
            progress: prog.VerifyProgressFn,
            io: Io,
            alloc: std.mem.Allocator,
            file_number_processed: *u64,
            size_processed_bytes: *u64,
            file_number_total: u64,
            size_total_bytes: u64,

            fn entry(st: @This(), kv: anytype) (Error || prog.CallbackError || Io.File.OpenError || Io.File.StatError)!void {
                const key = kv.key_ptr.*;
                const f_entry = kv.value_ptr;
                const relative_path = try std_path.relative(
                    st.fba, "", null, st.root_path, key,
                );
                const is_included = if (st.include) |include_fn|
                    include_fn(relative_path, st.context)
                else
                    true;

                if (!is_included) return;

                var pre = prog.VerifyProgressCommon{
                    .tree_root = st.root_path,
                    .relative_path = relative_path,
                    .file_number_processed = st.file_number_processed.*,
                    .file_number_total = st.file_number_total,
                    .size_processed_bytes = st.size_processed_bytes.*,
                    .size_total_bytes = st.size_total_bytes,
                };

                try st.progress(&.{ .pre = pre }, st.context);

                const Ctx = struct {
                    progress: prog.VerifyProgressFn,
                    context: *anyopaque,

                    fn callback(p: prog.HashProgress, c: *anyopaque) prog.CallbackError!void {
                        const s: *@This() = @ptrCast(@alignCast(c));
                        try s.progress(&.{ .during = p }, s.context);
                    }
                };
                var ctx = Ctx{ .context = st.context, .progress = st.progress };
                const result = try f_entry.verify(
                    st.io, st.alloc, &Ctx.callback, &ctx,
                );

                st.size_processed_bytes.* += f_entry.*.size orelse 0;
                st.file_number_processed.* += 1;

                pre.size_processed_bytes = st.size_processed_bytes.*;
                pre.file_number_processed = st.file_number_processed.*;

                try st.progress(
                    &.{ .post = .{ .progress = pre, .result = result } },
                    st.context,
                );
            }
        };

        var verifier = V{
            .fba = fba,
            .root_path = self.root_path,
            .include = include,
            .context = context,
            .progress = progress,
            .io = io,
            .alloc = alloc,
            .file_number_processed = &file_number_processed,
            .size_processed_bytes = &size_processed_bytes,
            .file_number_total = file_number_total,
            .size_total_bytes = size_total_bytes,
        };

        if (comptime builtin.is_test) {
            var iter = try self.sortedIterator(alloc);
            defer iter.deinit(alloc);
            while (iter.next()) |kv| try verifier.entry(kv);
        } else {
            var iter = self.iterator();
            while (iter.next()) |kv| try verifier.entry(kv);
        }
    }
};

test "Collection.init does not borrow path" {
    const expected_root = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
    const expected_name = "bar";
    const path = try std_path.join(testing.allocator, &[_][]const u8{
        expected_root,
        expected_name,
    });
    defer testing.allocator.free(path);

    var collection = try Collection.init(testing.allocator, path);
    defer collection.deinit();

    path[3] = 'x';
    path[7] = 'y';

    try testing.expectEqualStrings(expected_root, collection.root_path);
    try testing.expectEqualStrings(expected_name, collection.name);
}

test "Collection.init relative path error" {
    const buf = [_]u8{ 'f', 'o', 'o', std_path.sep, 'b', 'a', 'r' };
    const collection = Collection.init(testing.allocator, &buf);

    try testing.expectError(Collection.Error.PathNotAbsolute, collection);
}

test "Collection.put" {
    const path = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";

    var collection = try Collection.init(testing.allocator, path);
    defer collection.deinit();

    const expected = file.File{
        .path = path,
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
        .size = 1337,
        .hash_type = .md5,
        .hash_bytes = &.{},
    };
    try collection.put(expected);

    const actual = collection.get(path) orelse @panic("must succeed");

    try testing.expectEqualDeep(expected, actual);
}

test "Collection.putNoClobber" {
    const path = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";

    var collection = try Collection.init(testing.allocator, path);
    defer collection.deinit();

    const expected = file.File{
        .path = path,
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
        .size = 1337,
        .hash_type = .md5,
        .hash_bytes = &.{},
    };
    try collection.putNoClobber(expected);

    const actual = collection.get(path) orelse @panic("must succeed");
    try testing.expectEqualDeep(expected, actual);

    const err = collection.putNoClobber(expected);
    try testing.expectError(Collection.Error.WouldClobber, err);
}

test "Collection normalizes path" {
    const path = if (builtin.target.os.tag == .windows)
        "C:\\foo/bar/..\\./file.cshd"
    else
        "/foo/bar/../././file.cshd";

    var collection = try Collection.init(testing.allocator, path);
    defer collection.deinit();

    const expected = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
    try testing.expectEqualStrings(collection.root_path, expected);
}

test "Collection verify" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    const collection_path = try std_path.join(testing.allocator, &[_][]const u8{
        tmp.absolute_path,
        "foo.cshd",
    });
    defer testing.allocator.free(collection_path);

    var collection = try Collection.init(testing.allocator, collection_path);
    defer collection.deinit();

    const test_files = &[_]helpers.TestFile{
        .{
            .relativePath = "bar/xer/vid.mp4",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
            .content = "vid123",
        },
        .{
            .relativePath = "foo/bar/file.txt",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .content = "hello world!",
        },
        .{
            .relativePath = "xer.bin",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
            .content = "onetwothree",
        },
    };

    try helpers.createTestFiles(testing.io, tmp.tmp.dir, test_files);

    const absolute_paths = &[_][]const u8{
        try std_path.join(testing.allocator, &[_][]const u8{
            tmp.absolute_path,
            test_files[0].relativePath,
        }),
        try std_path.join(testing.allocator, &[_][]const u8{
            tmp.absolute_path,
            test_files[1].relativePath,
        }),
        try std_path.join(testing.allocator, &[_][]const u8{
            tmp.absolute_path,
            test_files[2].relativePath,
        }),
    };
    defer {
        for (absolute_paths) |p| {
            testing.allocator.free(p);
        }
    }

    try collection.putNoClobber(.{
        .path = absolute_paths[0],
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
        .size = 11111,
        .hash_type = hash.HashType.md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });
    try collection.putNoClobber(.{
        .path = absolute_paths[1],
        .mtime = null,
        .size = null,
        .hash_type = hash.HashType.md5,
        .hash_bytes = &[_]u8{
            0xfc, 0x3f, 0xf9, 0x8e, 0x8c, 0x6a, 0x0d, 0x30, 0x87, 0xd5,
            0x15, 0xc0, 0x47, 0x3f, 0x86, 0x77,
        },
    });
    try collection.putNoClobber(.{
        .path = absolute_paths[2],
        .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(300)),
        .size = 11,
        .hash_type = hash.HashType.md5,
        .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    });

    const expected_callbacks = &[_]*const prog.VerifyProgress{
        &.{
            .pre = .{
                .file_number_processed = 0,
                .file_number_total = 3,
                .size_processed_bytes = 0,
                .size_total_bytes = 11122,
                .relative_path = test_files[0].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        &.{
            .post = .{
                .result = .mismatch_size,
                .progress = .{
                    .file_number_processed = 1,
                    .file_number_total = 3,
                    .size_processed_bytes = 11111,
                    .size_total_bytes = 11122,
                    .relative_path = test_files[0].relativePath,
                    .tree_root = tmp.absolute_path,
                },
            },
        },
        &.{
            .pre = .{
                .file_number_processed = 1,
                .file_number_total = 3,
                .size_processed_bytes = 11111,
                .size_total_bytes = 11122,
                .relative_path = test_files[1].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        &.{ .during = .{ .bytes_read = 12, .bytes_total = 12 } },
        &.{
            .post = .{
                .result = .ok,
                .progress = .{
                    .file_number_processed = 2,
                    .file_number_total = 3,
                    .size_processed_bytes = 11111,
                    .size_total_bytes = 11122,
                    .relative_path = test_files[1].relativePath,
                    .tree_root = tmp.absolute_path,
                },
            },
        },
        &.{
            .pre = .{
                .file_number_processed = 2,
                .file_number_total = 3,
                .size_processed_bytes = 11111,
                .size_total_bytes = 11122,
                .relative_path = test_files[2].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        &.{ .during = .{ .bytes_read = 11, .bytes_total = 11 } },
        &.{
            .post = .{
                .result = .mismatch_corrupted,
                .progress = .{
                    .file_number_processed = 3,
                    .file_number_total = 3,
                    .size_processed_bytes = 11122,
                    .size_total_bytes = 11122,
                    .relative_path = test_files[2].relativePath,
                    .tree_root = tmp.absolute_path,
                },
            },
        },
    };

    const CaptureType = helpers.CallbackCapture(*const prog.VerifyProgress);
    var capture: CaptureType = .init(testing.allocator);
    defer capture.deinit();

    try collection.verify(
        testing.io,
        null,
        &CaptureType.cb,
        &capture,
    );

    try helpers.expectEqualSlicesDeep(
        *const prog.VerifyProgress,
        expected_callbacks,
        capture.captures.items,
    );
}
