const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;
const path = std.fs.path;
const testing = std.testing;
const Collection = @import("collection.zig").Collection;
const prog = @import("progress.zig");

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

// compares slices and inner slices only based on their content,
// not their addresses!
pub fn expectEqualSlicesDeep(
    comptime T: type,
    expected: []const T,
    actual: []const T,
) !void {
    const diff_index: usize = diff_index: {
        const shortest = @min(expected.len, actual.len);
        var i: usize = 0;
        while (i < shortest) : (i += 1) {
            if (!deepEql(expected[i], actual[i])) break :diff_index i;
        }
        break :diff_index if (expected.len == actual.len)
            return
        else
            shortest;
    };

    if (!std.testing.backend_can_print) return error.TestExpectedEqual;

    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;

    try w.print("\nSlices differ at index {}\n\n", .{diff_index});

    try w.print("expected: ", .{});
    if (expected.len > 0) {
        try printValue(w, expected[diff_index]);
    } else {
        try w.print("[]", .{});
    }
    try w.print("\nactual:   ", .{});
    if (actual.len > 0) {
        try printValue(w, actual[diff_index]);
    } else {
        try w.print("[]", .{});
    }
    try w.print("\n\n", .{});

    return error.TestExpectedEqual;
}

fn isStringSlice(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;

    const ptr = @typeInfo(T).pointer;
    return ptr.size == .slice and ptr.child == u8;
}

fn printValue(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const ti = @typeInfo(T);

    if (comptime isStringSlice(T)) {
        try w.print("{any}", .{value});
        try w.print("\nas str: \"{s}\"", .{value});
    } else if ((ti == .@"struct" or ti == .@"union" or
        ti == .@"enum" or ti == .@"opaque") and @hasDecl(T, "format"))
    {
        try w.print("{f}", .{value});
    } else {
        try w.print("{any}", .{value});
    }
}

// eql that doesn't compare slice.ptr, just the contents
fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                const Child = ptr.child;
                return std.mem.eql(Child, a, b);
            }
            if (ptr.size == .one) {
                return deepEql(a.*, b.*);
            }
            return a == b;
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (!deepEql(@field(a, field.name), @field(b, field.name))) {
                    return false;
                }
            }
            return true;
        },
        .array => {
            for (a, b) |ai, bi| {
                if (!deepEql(ai, bi)) return false;
            }
            return true;
        },
        .@"union" => |info| {
            if (info.layout == .@"packed") return a == b;

            const Tag = info.tag_type orelse
                @compileError("cannot compare untagged union " ++ @typeName(T));

            const tag_a: Tag = a;
            const tag_b: Tag = b;

            if (tag_a != tag_b) return false;

            return switch (a) {
                inline else => |val, tag| {
                    const b_val = @field(b, @tagName(tag));
                    return deepEql(val, b_val);
                },
            };
        },
        else => return std.meta.eql(a, b),
    }
}

pub fn expectEqualCollection(
    expected: Collection,
    actual: Collection,
) !void {
    try testing.expectEqualStrings(expected.root_path, actual.root_path);
    try testing.expectEqualStrings(expected.name, actual.name);
    try testing.expectEqual(expected.mtime, actual.mtime);

    try testing.expectEqual(expected.path_to_file.count(), actual.path_to_file.count());
    var iter = expected.iterator();
    while (iter.next()) |expected_entry| {
        std.log.debug("looking up expected key: {s}\n", .{expected_entry.key_ptr.*});
        const actual_entry = actual.path_to_file.get(expected_entry.key_ptr.*) orelse
            @panic("expected key not found");
        try testing.expectEqualDeep(expected_entry.value_ptr.*, actual_entry);
    }
}

pub fn dummyAbsolutePathFile() []const u8 {
    if (builtin.os.tag == .windows) {
        return comptime dummyAbsolutePathDir() ++ "\\file.txt";
    }

    return comptime dummyAbsolutePathDir() ++ "/file.txt";
}

pub fn dummyAbsolutePathDir() []const u8 {
    if (builtin.os.tag == .windows) {
        return comptime dummyAbsolutePathRoot() ++ "\\foo\\bar";
    }

    return comptime dummyAbsolutePathRoot() ++ "foo/bar";
}

pub fn dummyAbsolutePathRoot() []const u8 {
    if (builtin.os.tag == .windows) {
        return "C:";
    }

    return "/";
}

pub fn CallbackCapture(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        captures: std.ArrayList(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .arena = .init(allocator),
                .captures = .empty,
            };
        }

        pub fn cb(progress: T, context: *anyopaque) prog.CallbackError!void {
            var self: *Self = @ptrCast(@alignCast(context));

            try self.captures.append(
                self.arena.allocator(),
                try Self.cloneOrCopy(progress, self.arena.allocator()),
            );
        }

        pub fn cbVoid(progress: T, context: *anyopaque) void {
            var self: *Self = @ptrCast(@alignCast(context));

            self.captures.append(
                self.arena.allocator(),
                Self.cloneOrCopy(progress, self.arena.allocator()) catch
                    @panic("failed to copy callback value"),
            ) catch @panic("failed to append callback value");
        }

        fn cloneOrCopy(value: T, allocator: std.mem.Allocator) !T {
            return switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => blk: {
                    if (@hasDecl(T, "clone")) {
                        break :blk try value.clone(allocator);
                    }
                    break :blk value;
                },
                .pointer => |ptr_info| blk: {
                    if (ptr_info.size != .one) break :blk value;
                    const Child = ptr_info.child;
                    switch (@typeInfo(Child)) {
                        .@"struct", .@"union" => {
                            if (@hasDecl(Child, "clone")) {
                                const cloned = try value.*.clone(allocator);
                                const ptr = try allocator.create(Child);
                                ptr.* = cloned;
                                break :blk ptr;
                            }
                            break :blk value;
                        },
                        else => break :blk value,
                    }
                },
                else => value, // primitives, etc.
            };
        }

        pub fn deinit(self: *@This()) void {
            self.captures.deinit(self.arena.allocator());
            self.arena.deinit();
        }
    };
}
