const std = @import("std");
const testing = std.testing;
const FilteredWalker = @import("discover.zig").FilteredWalker;

pub const PathStore = struct {
    chunk_size: usize,
    // TODO use [chunk_size]u8 instead and make chunk_size comptime?
    chunks: std.ArrayList([]u8),
    // Position inside the current chunk
    pos: usize,
    // Contains the offsets of each path, where the offset denotes the
    // starting point in self.chunks
    offsets: std.ArrayList(usize),
    // Total data in bytes up till and including the last path stored.
    // Includes empty gap bytes, but does not include free trailing
    // bytes in the current chunk.
    total_data_len: usize,
    allocator: std.mem.Allocator,

    pub const Error = error{ PathLargerThanChunkSize, OutOfMemory };

    pub fn init(allocator: std.mem.Allocator, chunk_size: usize) PathStore {
        return .{
            .chunk_size = chunk_size,
            .chunks = .empty,
            .pos = 0,
            .offsets = .empty,
            .total_data_len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }

    pub fn store(self: *@This(), path: []const u8) Error![]const u8 {
        if (path.len > self.chunk_size) {
            return Error.PathLargerThanChunkSize;
        }

        if (self.chunks.items.len == 0 or self.pos + path.len > self.chunk_size) {
            const new_chunk = try self.allocator.alloc(u8, self.chunk_size);
            try self.chunks.append(self.allocator, new_chunk);
            self.pos = 0;
        }

        const chunk_idx = self.chunks.items.len - 1;
        const global_offset = chunk_idx * self.chunk_size + self.pos;
        try self.offsets.append(self.allocator, global_offset);

        const slice = self.chunks.items[chunk_idx][self.pos..][0..path.len];
        @memcpy(slice, path);
        self.pos += path.len;
        self.total_data_len = chunk_idx * self.chunk_size + self.pos;
        return slice;
    }

    pub fn len(self: *@This()) usize {
        return self.offsets.items.len;
    }

    pub fn iter(self: *@This()) PathStoreIter {
        return .{
            .chunks = self.chunks.items,
            .offsets = self.offsets.items,
            .chunk_size = self.chunk_size,
            .total_data_len = self.total_data_len,
            .offset_idx = 0,
        };
    }
};

pub const PathStoreIter = struct {
    chunks: []const []u8,
    offsets: []const usize,
    chunk_size: usize,
    total_data_len: usize,
    offset_idx: usize,

    pub fn next(self: *@This()) ?[]const u8 {
        const i = self.offset_idx;
        if (i >= self.offsets.len) return null;
        self.offset_idx = i + 1;

        const global_start = self.offsets[i];
        const global_end = if (self.offset_idx < self.offsets.len)
            self.offsets[self.offset_idx]
        else
            self.total_data_len;

        const chunk = global_start / self.chunk_size;
        const local = global_start % self.chunk_size;
        return self.chunks[chunk][local .. local + (global_end - global_start)];
    }
};

test "PathStore first alloc fit in chunk size" {
    const expected = "0123456789";
    var store = PathStore.init(testing.allocator, 10);
    defer store.deinit();
    const actual = try store.store(
        expected,
    );

    try testing.expectEqualStrings(expected, actual);
    try testing.expectEqualStrings(expected, store.chunks.items[0]);
    try testing.expectEqual(0, store.offsets.items[0]);
    try testing.expectEqual(10, store.pos);
    try testing.expectEqual(10, store.total_data_len);
}

test "PathStore erorrs when path is larger than chunk size" {
    const expected = "0123456789+";
    var store = PathStore.init(testing.allocator, 10);
    defer store.deinit();
    const actual = store.store(
        expected,
    );

    try testing.expectError(PathStore.Error.PathLargerThanChunkSize, actual);
}

test "PathStore current chunk fits two allocs" {
    const expectedFirst = "0123456789";
    const expectedSecond = "abc";
    var store = PathStore.init(testing.allocator, 13);
    defer store.deinit();
    const actualFirst = try store.store(
        expectedFirst,
    );
    const actualSecond = try store.store(
        expectedSecond,
    );

    try testing.expectEqualStrings(expectedFirst, actualFirst);
    try testing.expectEqualStrings(expectedSecond, actualSecond);
    try testing.expectEqual(1, store.chunks.items.len);
    try testing.expectEqual(2, store.offsets.items.len);
    try testing.expectEqual(0, store.offsets.items[0]);
    try testing.expectEqual(10, store.offsets.items[1]);
    try testing.expectEqual(13, store.pos);
    try testing.expectEqual(13, store.total_data_len);
}

test "PathStore current chunk too small" {
    const expectedFirst = "0123456789";
    const expectedSecond = "abc";
    var store = PathStore.init(testing.allocator, 12);
    defer store.deinit();
    const actualFirst = try store.store(
        expectedFirst,
    );
    const actualSecond = try store.store(
        expectedSecond,
    );

    try testing.expectEqualStrings(expectedFirst, actualFirst);
    try testing.expectEqualStrings(expectedSecond, actualSecond);
    try testing.expectEqual(2, store.chunks.items.len);
    try testing.expectEqual(2, store.offsets.items.len);
    try testing.expectEqual(0, store.offsets.items[0]);
    try testing.expectEqual(12, store.offsets.items[1]);
    try testing.expectEqual(3, store.pos);
    try testing.expectEqual(15, store.total_data_len);
}
