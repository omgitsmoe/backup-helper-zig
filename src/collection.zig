const std = @import("std");
const Io = std.Io;
const std_path = std.fs.path;
const testing = std.testing;

const file = @import("file.zig");
const prog = @import("progress.zig");
const hash = @import("hash.zig");
const builtin = @import("builtin");
const PathStore = @import("store.zig").PathStore;
const parse = @import("parser.zig").parse;
const ParseError = @import("parser.zig").Error;
const parseSingle = @import("parser_single.zig").parse;
const ParseSingleError = @import("parser_single.zig").Error;

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
        MissingExtension,
        MergeRootsIncompatible,
    } || prog.CallbackError || hash.HashType.Error;

    /// Collection does not take ownership of `path`
    pub fn init(
        allocator: std.mem.Allocator,
        root_path: []const u8,
        name: []const u8,
    ) Error!Collection {
        if (!std_path.isAbsolute(root_path)) {
            return Error.PathNotAbsolute;
        }

        const normalized = try std_path.resolve(allocator, &[_][]const u8{
            root_path,
        });
        defer allocator.free(normalized);

        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const alloc = arena.allocator();
        return .{
            .root_path = try alloc.dupe(u8, normalized),
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

    pub fn fromDisk(
        io: Io,
        allocator: std.mem.Allocator,
        store: *PathStore,
        path: []const u8,
    ) (Error || Io.File.OpenError || Io.File.StatError || ParseError || ParseSingleError)!Collection {
        if (!std_path.isAbsolute(path)) {
            return Error.PathNotAbsolute;
        }

        const root_path = std_path.dirname(path) orelse
            @panic("bug: must have dirname if absolute path");
        const name = std_path.basename(path);
        const ext = std_path.extension(name);
        if (ext.len == 0) {
            return Error.MissingExtension;
        }

        var buf: [65536]u8 = undefined;
        const open_file = try Io.Dir.openFileAbsolute(io, path, .{
            .allow_directory = false,
            .follow_symlinks = true,
        });
        defer open_file.close(io);

        const st = try open_file.stat(io);

        var reader = open_file.reader(io, &buf);

        const ext_without_dot = ext[1..];
        if (std.mem.eql(u8, ext_without_dot, "cshd")) {
            var result = try parse(allocator, store, &reader.interface, root_path, name);
            result.mtime = st.mtime;
            return result;
        }

        const hash_type = try hash.HashType.from(ext_without_dot);
        var result = try parseSingle(
            allocator,
            store,
            &reader.interface,
            root_path,
            name,
            hash_type,
        );
        result.mtime = st.mtime;
        return result;
    }

    pub fn root(self: @This()) []const u8 {
        return self.root_path;
    }

    pub fn filename(self: @This()) []const u8 {
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

    pub fn get(self: @This(), path: []const u8) ?file.File {
        return self.path_to_file.get(path);
    }

    pub fn getPtr(self: *@This(), path: []const u8) ?*file.File {
        return self.path_to_file.getPtr(path);
    }

    pub fn count(self: *const @This()) u32 {
        return self.path_to_file.count();
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

    fn knownSizeBytes(self: *const @This()) u64 {
        var iter = self.iterator();
        var bytes: u64 = 0;
        while (iter.next()) |entry| {
            bytes += entry.value_ptr.*.size orelse 0;
        }

        return bytes;
    }

    pub const IncludeFn = *const fn (relative_path: []const u8, context: *anyopaque) bool;

    fn verifyImpl(
        self: *const @This(),
        comptime IteratorType: type,
        iter: *IteratorType,
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
        const size_total_bytes: u64 = self.knownSizeBytes();

        while (iter.next()) |kv| : (fixed.reset()) {
            const key = kv.key_ptr.*;
            const f_entry = kv.value_ptr;
            const relative_path = try std_path.relative(
                fba,
                "",
                null,
                self.root_path,
                key,
            );
            const is_included = if (include) |include_fn|
                include_fn(relative_path, context)
            else
                true;

            if (!is_included) {
                size_processed_bytes += f_entry.*.size orelse 0;
                file_number_processed += 1;
                continue;
            }

            var pre = prog.VerifyProgressCommon{
                .tree_root = self.root_path,
                .relative_path = relative_path,
                .file_number_processed = file_number_processed,
                .file_number_total = file_number_total,
                .size_processed_bytes = size_processed_bytes,
                .size_total_bytes = size_total_bytes,
            };

            try progress(.{ .pre = pre }, context);

            const Ctx = struct {
                progress: prog.VerifyProgressFn,
                context: *anyopaque,

                fn callback(p: prog.HashProgress, c: *anyopaque) prog.CallbackError!void {
                    const s: *@This() = @ptrCast(@alignCast(c));
                    try s.progress(.{ .during = p }, s.context);
                }
            };
            var ctx = Ctx{ .context = context, .progress = progress };
            const result = try f_entry.verify(
                io,
                alloc,
                &Ctx.callback,
                &ctx,
            );

            size_processed_bytes += f_entry.*.size orelse 0;
            file_number_processed += 1;

            pre.size_processed_bytes = size_processed_bytes;
            pre.file_number_processed = file_number_processed;

            try progress(
                .{ .post = .{ .progress = pre, .result = result } },
                context,
            );
        }
    }

    pub fn verify(
        self: *const @This(),
        io: Io,
        include: ?IncludeFn,
        progress: prog.VerifyProgressFn,
        context: *anyopaque,
    ) (Error || prog.CallbackError || Io.File.OpenError || Io.File.StatError)!void {
        if (comptime builtin.is_test) {
            const alloc = self.arena.child_allocator;
            var iter = try self.sortedIterator(alloc);
            defer iter.deinit(alloc);
            try self.verifyImpl(SortedIterator, &iter, io, include, progress, context);
        } else {
            var iter = self.iterator();
            try self.verifyImpl(Iterator, &iter, io, include, progress, context);
        }
    }

    fn ensureMergeRootsAreCompatible(self: *@This(), other: @This()) Error!void {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buf);
        const fba = fixed.allocator();
        const to_other = try std_path.relative(
            fba,
            "",
            null,
            self.root_path,
            other.root_path,
        );

        var iter = std_path.componentIterator(to_other);
        while (iter.next()) |component| {
            if (std.mem.eql(u8, component.name, "..")) {
                return Error.MergeRootsIncompatible;
            }
        }
    }

    /// Merges all entries in `other` into `self`. If there are conflicts:
    /// Keep the data from the __collection__ with the more recent mtime.
    /// An mtime of null is always considered older.
    /// If both mtimes are null then our entries are preferred.
    pub fn merge(self: *@This(), other: @This()) Error!void {
        try self.ensureMergeRootsAreCompatible(other);

        const keep_ours = if (self.mtime) |our_mtime| blk: {
            break :blk if (other.mtime) |other_mtime|
                our_mtime.durationTo(other_mtime).nanoseconds <= 0
            else
                true;
        } else blk: {
            break :blk if (other.mtime) |_| false else true;
        };

        var iter = other.iterator();
        const alloc = self.arena.allocator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const has_key = self.getPtr(key) != null;

            if (has_key and keep_ours) {
                continue;
            }

            const cloned = try entry.value_ptr.clone(alloc);
            try self.put(cloned);
        }
    }

    pub fn filter_missing(self: *@This(), io: Io) (Io.Dir.StatFileError || error{OutOfMemory})!void {
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(self.arena.child_allocator);

        var iter = self.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            _ = Io.Dir.cwd().statFile(
                io,
                path,
                .{ .follow_symlinks = true },
            ) catch |err| switch (err) {
                Io.Dir.StatFileError.FileNotFound => {
                    try to_remove.append(self.arena.child_allocator, path);
                },
                else => return err,
            };
        }

        for (to_remove.items) |remove_path| {
            _ = self.path_to_file.remove(remove_path);
        }
    }
};

test "Collection.init does not borrow path" {
    const expected_root = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
    const expected_name = "bar";

    var root = try testing.allocator.dupe(u8, expected_root);
    defer testing.allocator.free(root);
    var name = try testing.allocator.dupe(u8, expected_name);
    defer testing.allocator.free(name);

    var collection = try Collection.init(testing.allocator, root, name);
    defer collection.deinit();

    root[3] = 'x';
    name[1] = 'y';

    try testing.expectEqualStrings(expected_root, collection.root_path);
    try testing.expectEqualStrings(expected_name, collection.name);
}

test "Collection.init relative path error" {
    const root = "foo";
    const name = "bar";
    const collection = Collection.init(testing.allocator, root, name);

    try testing.expectError(Collection.Error.PathNotAbsolute, collection);
}

test "Collection.put" {
    const root = if (builtin.target.os.tag == .windows) "C:\\" else "/";
    const name = "foo";

    var collection = try Collection.init(testing.allocator, root, name);
    defer collection.deinit();

    const path = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
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
    const root = if (builtin.target.os.tag == .windows) "C:\\" else "/";
    const name = "foo";

    var collection = try Collection.init(testing.allocator, root, name);
    defer collection.deinit();

    const path = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
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
    const root = if (builtin.target.os.tag == .windows)
        "C:\\foo/bar/..\\./"
    else
        "/foo/bar/../././";
    const name = "file.cshd";

    var collection = try Collection.init(testing.allocator, root, name);
    defer collection.deinit();

    const expected = if (builtin.target.os.tag == .windows) "C:\\foo" else "/foo";
    try testing.expectEqualStrings(collection.root_path, expected);
}

test "Collection verify" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    var collection = try Collection.init(testing.allocator, tmp.absolute_path, "foo");
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

    const expected_callbacks = &[_]prog.VerifyProgress{
        .{
            .pre = .{
                .file_number_processed = 0,
                .file_number_total = 3,
                .size_processed_bytes = 0,
                .size_total_bytes = 11122,
                .relative_path = test_files[0].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        .{
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
        .{
            .pre = .{
                .file_number_processed = 1,
                .file_number_total = 3,
                .size_processed_bytes = 11111,
                .size_total_bytes = 11122,
                .relative_path = test_files[1].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        .{ .during = .{ .bytes_read = 12, .bytes_total = 12 } },
        .{
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
        .{
            .pre = .{
                .file_number_processed = 2,
                .file_number_total = 3,
                .size_processed_bytes = 11111,
                .size_total_bytes = 11122,
                .relative_path = test_files[2].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        .{ .during = .{ .bytes_read = 11, .bytes_total = 11 } },
        .{
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

    const CaptureType = helpers.CallbackCapture(prog.VerifyProgress);
    var capture: CaptureType = .init(testing.allocator);
    defer capture.deinit();

    try collection.verify(
        testing.io,
        null,
        &CaptureType.cb,
        &capture,
    );

    try helpers.expectEqualSlicesDeep(
        prog.VerifyProgress,
        expected_callbacks,
        capture.captures.items,
    );
}

test "Collection verify respects include" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    var collection = try Collection.init(testing.allocator, tmp.absolute_path, "foo");
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

    const expected_callbacks = &[_]prog.VerifyProgress{
        .{
            .pre = .{
                .file_number_processed = 1,
                .file_number_total = 3,
                .size_processed_bytes = 11111,
                .size_total_bytes = 11122,
                .relative_path = test_files[1].relativePath,
                .tree_root = tmp.absolute_path,
            },
        },
        .{ .during = .{ .bytes_read = 12, .bytes_total = 12 } },
        .{
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
    };

    const include = struct {
        pub fn incl(relative_path: []const u8, _: *anyopaque) bool {
            return std.mem.endsWith(u8, relative_path, "file.txt");
        }
    }.incl;

    const CaptureType = helpers.CallbackCapture(prog.VerifyProgress);
    var capture: CaptureType = .init(testing.allocator);
    defer capture.deinit();

    try collection.verify(
        testing.io,
        &include,
        &CaptureType.cb,
        &capture,
    );

    try helpers.expectEqualSlicesDeep(
        prog.VerifyProgress,
        expected_callbacks,
        capture.captures.items,
    );
}

test "Collection merge" {
    const helpers = @import("test_helpers.zig");

    const abs_root = comptime helpers.dummyAbsolutePathDir();

    var tests = [_]struct {
        name: []const u8,
        expected_error: ?Collection.Error,
        self: Collection,
        self_files: []const file.File,
        self_mtime: ?Io.Timestamp,
        other: Collection,
        other_mtime: ?Io.Timestamp,
        other_files: []const file.File,
        expected: Collection,
        expected_mtime: ?Io.Timestamp,
        expected_files: []const file.File,
    }{
        .{
            .name = "roots incompatible",
            .expected_error = Collection.Error.MergeRootsIncompatible,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = null,
            .self_files = &.{},
            .other = try .init(
                testing.allocator,
                comptime helpers.dummyAbsolutePathRoot(),
                "other.cshd",
            ),
            .other_mtime = null,
            .other_files = &.{},
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = null,
            .expected_files = &.{},
        },
        .{
            .name = "both mtimes zero: keep ours",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = null,
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = null,
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = null,
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
        .{
            .name = "other zero mtime: keep ours",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = null,
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
        .{
            .name = "other older: keep ours",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(99)),
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
        .{
            .name = "same mtime: keep ours",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
        .{
            .name = "self zero mtime: keep other",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = null,
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = null,
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
        .{
            .name = "self older: keep other",
            .expected_error = null,
            .self = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .self_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(99)),
            .self_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(1337)),
                    .size = 42069,
                    .hash_type = .md5,
                    .hash_bytes = &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
            },
            .other = try .init(
                testing.allocator,
                abs_root,
                "other.cshd",
            ),
            .other_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(100)),
            .other_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
            .expected = try .init(
                testing.allocator,
                abs_root,
                "self.cshd",
            ),
            .expected_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(99)),
            .expected_files = &[_]file.File{
                .{
                    .path = abs_root ++ "/conflict.txt",
                    .mtime = null,
                    .size = null,
                    .hash_type = .sha3_512,
                    .hash_bytes = &.{},
                },
                .{
                    .path = abs_root ++ "/ours/bar.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345)),
                    .size = 5678,
                    .hash_type = .sha512,
                    .hash_bytes = &[_]u8{ 0xab, 0xab, 0xab, 0xab },
                },
                .{
                    .path = abs_root ++ "/other/xer.txt",
                    .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(898989)),
                    .size = 3344,
                    .hash_type = .sha3_256,
                    .hash_bytes = &[_]u8{ 0xaa, 0xaa, 0xaa, 0xaa },
                },
            },
        },
    };

    for (&tests) |*tt| {
        for (tt.self_files) |f| {
            try tt.self.putNoClobber(f);
        }
        tt.self.mtime = tt.self_mtime;
        for (tt.other_files) |f| {
            try tt.other.putNoClobber(f);
        }
        tt.other.mtime = tt.other_mtime;
        for (tt.expected_files) |f| {
            try tt.expected.putNoClobber(f);
        }
        tt.expected.mtime = tt.expected_mtime;
        defer {
            tt.self.deinit();
            tt.other.deinit();
            tt.expected.deinit();
        }

        const actual_err = tt.self.merge(tt.other);

        if (tt.expected_error) |err| {
            try testing.expectError(err, actual_err);
            continue;
        }

        try helpers.expectEqualCollection(
            tt.expected,
            tt.self,
        );
    }
}

test "Collection filter_missing" {
    const helpers = @import("test_helpers.zig");

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    var collection = try Collection.init(testing.allocator, tmp.absolute_path, "foo");
    defer collection.deinit();

    const test_files = &[_]helpers.TestFile{
        .{
            .relativePath = "bar/xer/vid.mp4",
            .mtime = Io.Timestamp.zero.addDuration(.fromSeconds(200)),
            .content = "vid123",
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
            "foo/bar/file.txt",
        }),
        try std_path.join(testing.allocator, &[_][]const u8{
            tmp.absolute_path,
            "xer.bin",
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

    try collection.filter_missing(testing.io);

    try testing.expect(collection.getPtr(absolute_paths[0]) != null);
    try testing.expect(collection.getPtr(absolute_paths[1]) == null);
    try testing.expect(collection.getPtr(absolute_paths[2]) == null);
}

test "Collection.fromDisk sets mtime from file stat" {
    const helpers = @import("test_helpers.zig");
    var store = PathStore.init(testing.allocator, std.Io.Dir.max_path_bytes);
    defer store.deinit();

    var tmp = helpers.tmpDirWithPath(.{});
    defer tmp.cleanup();

    const expected_mtime = Io.Timestamp.zero.addDuration(.fromSeconds(12345));

    const test_files = &[_]helpers.TestFile{
        .{
            .relativePath = "test.cshd",
            .mtime = expected_mtime,
            .content =
            \\# version 1
            \\100.0,100,md5,deadbeef some/file.txt
            \\
            ,
        },
    };
    try helpers.createTestFiles(testing.io, tmp.tmp.dir, test_files);

    const hash_file_path = try std.fs.path.join(testing.allocator, &[_][]const u8{
        tmp.absolute_path,
        "test.cshd",
    });
    defer testing.allocator.free(hash_file_path);

    var collection = try Collection.fromDisk(
        testing.io,
        testing.allocator,
        &store,
        hash_file_path,
    );
    defer collection.deinit();

    try testing.expect(collection.mtime != null);
    try testing.expectEqual(expected_mtime, collection.mtime.?);
}
