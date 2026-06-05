const std = @import("std");
const Io = std.Io;
const std_path = std.fs.path;
const testing = std.testing;

const file = @import("file.zig");

pub const Collection = struct {
    root_path: []const u8,
    name: []const u8,
    arena: *std.heap.ArenaAllocator,
    path_to_file: std.StringHashMap(file.File),
    mtime: ?Io.Timestamp,

    const Iterator = std.StringHashMap(file.File).Iterator;

    pub const Error = error{
        PathNotAbsolute,
        WouldClobber,
        OutOfMemory,
    };

    /// Collection does not take ownership of `path`
    pub fn init(allocator: std.mem.Allocator, path: []const u8) Error!Collection {
        if (!std_path.isAbsolute(path)) {
            return Error.PathNotAbsolute;
        }

        const name = std_path.basename(path);
        // if path is absolute, then dirname will always succeed
        const dirpath = std_path.dirname(path) orelse unreachable;
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
};

test "Collection.init does not borrow path" {
    const builtin = @import("builtin");
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
    const builtin = @import("builtin");
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
    const builtin = @import("builtin");
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
