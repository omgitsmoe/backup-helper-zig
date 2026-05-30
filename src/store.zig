const std = @import("std");
const testing = std.testing;
const FilteredWalker = @import("discover.zig").FilteredWalker;

pub const StoreStr = struct {
    paths: std.ArrayList([]const u8) = .empty,
    total_path_len: usize = 0,

    pub fn store(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !usize {
        const dupe = try allocator.dupe(u8, path);
        try self.paths.append(allocator, dupe);
        self.total_path_len += path.len;
        return self.paths.items.len - 1;
    }

    pub fn memoryUsed(self: *const @This()) usize {
        return self.total_path_len + self.paths.capacity * @sizeOf([]const u8);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| {
            allocator.free(path);
        }
        self.paths.deinit(allocator);
    }
};

pub const StoreTree = struct {
    pub const Error = error{
        NotSubpath,
        NotFound,
        OutOfMemory,
    };

    pub const Node = struct {
        parent: ?*Node = null,
        name: []const u8,
        children: std.ArrayList(*Node) = .empty,

        pub fn find_child(self: *Node, name: []const u8) ?*Node {
            for (self.children.items) |child| {
                if (std.mem.eql(u8, child.name, name)) return child;
            }
            return null;
        }

        pub fn path(self: *Node, allocator: std.mem.Allocator) ![]u8 {
            var components = std.ArrayList([]const u8).empty;
            defer components.deinit(allocator);

            var curr: ?*Node = self;
            while (curr) |c| {
                try components.append(allocator, c.name);
                curr = c.parent;
            }

            std.mem.reverse([]const u8, components.items);
            const result = try std.fs.path.join(allocator, components.items);
            return result;
        }
    };

    root: *Node,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !@This() {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena.allocator();

        const rootCopy = try alloc.dupe(u8, root);

        const node = try alloc.create(Node);
        node.* = .{
            .parent = null,
            .name = rootCopy,
            .children = .empty,
        };

        return .{
            .root = node,
            .arena = arena,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    /// Add child to an existing node
    pub fn add_child(self: *@This(), parent: *Node, child_name: []const u8) !*Node {
        const alloc = self.arena.allocator();

        const name_copy = try alloc.dupe(u8, child_name);

        const node = try alloc.create(Node);
        node.* = .{
            .parent = parent,
            .name = name_copy,
            .children = .empty,
        };

        try parent.children.append(alloc, node);
        return node;
    }

    /// Find a node by absolute path (must be under root)
    pub fn find(self: *@This(), path: []const u8) Error!?*Node {
        if (!std.mem.startsWith(u8, path, self.root.name)) {
            return Error.NotSubpath;
        }

        var cur = self.root;

        var it = std.mem.splitScalar(u8, path[self.root.name.len..], '/');

        while (it.next()) |part| {
            if (part.len == 0) continue;

            cur = cur.find_child(part) orelse return null;
        }

        return cur;
    }

    /// Add a full path, creating intermediate nodes
    pub fn add(self: *@This(), path: []const u8) Error!*Node {
        if (!std.mem.startsWith(u8, path, self.root.name)) {
            return Error.NotSubpath;
        }

        const alloc = self.arena.allocator();

        var cur = self.root;
        var it = std.mem.splitScalar(u8, path[self.root.name.len..], '/');

        while (it.next()) |part| {
            if (part.len == 0) continue;

            if (cur.find_child(part)) |existing| {
                cur = existing;
            } else {
                const name_copy = try alloc.dupe(u8, part);

                const node = try alloc.create(Node);
                node.* = .{
                    .parent = cur,
                    .name = name_copy,
                    .children = .empty,
                };

                try cur.children.append(alloc, node);
                cur = node;
            }
        }

        return cur;
    }

    pub fn iter(self: *@This(), allocator: std.mem.Allocator) !StoreTreeIter {
        return StoreTreeIter.init(allocator, self.root);
    }

    pub fn memoryUsed(self: *const @This()) usize {
        var total: usize = 0;
        var it = self.arena.state.used_list;
        while (it) |node| : (it = node.next) {
            var int = node.size;
            int.resizing = false;
            total += @as(usize, @bitCast(int)) - @sizeOf(@TypeOf(node));
        }
        return total;
    }
};

pub const StoreTreeIter = struct {
    const Entry = struct {
        node: *StoreTree.Node,
    };

    stack: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator, start: *StoreTree.Node) !StoreTreeIter {
        var self = StoreTreeIter{ .stack = .empty };
        try self.stack.append(allocator, .{ .node = start });

        return self;
    }

    pub fn next(self: *@This(), allocator: std.mem.Allocator) !?*StoreTree.Node {
        if (self.stack.pop()) |curr| {
            for (curr.node.children.items) |child| {
                try self.stack.append(allocator, .{ .node = child });
            }

            return curr.node;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }
};

pub const StorePacked = struct {
    buffer: std.ArrayList(u8),
    offsets: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) StorePacked {
        _ = allocator;
        return .{
            .buffer = .empty,
            .offsets = .empty,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.offsets.deinit(allocator);
    }

    pub fn store(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !usize {
        const offset = self.buffer.items.len;
        try self.offsets.append(allocator, offset);
        try self.buffer.appendSlice(allocator, path);
        return self.offsets.items.len - 1;
    }

    pub fn get(self: *@This(), index: usize) []const u8 {
        const start = self.offsets.items[index];
        const end = if (index + 1 < self.offsets.items.len)
            self.offsets.items[index + 1]
        else
            self.buffer.items.len;
        return self.buffer.items[start..end];
    }

    pub fn len(self: *@This()) usize {
        return self.offsets.items.len;
    }

    pub fn iter(self: *@This()) StorePackedIter {
        return .{
            .buffer = self.buffer.items,
            .offsets = self.offsets.items,
            .index = 0,
        };
    }

    pub fn memoryUsed(self: *const @This()) usize {
        return self.buffer.capacity + self.offsets.capacity * @sizeOf(usize);
    }
};

pub const StorePackedIter = struct {
    buffer: []const u8,
    offsets: []const usize,
    index: usize,

    pub fn next(self: *@This()) ?[]const u8 {
        const i = self.index;
        if (i >= self.offsets.len) return null;
        self.index = i + 1;
        const start = self.offsets[i];
        const end = if (i + 1 < self.offsets.len)
            self.offsets[i + 1]
        else
            self.buffer.len;
        return self.buffer[start..end];
    }
};

pub const StorePackedChunked = struct {
    chunk_size: usize,
    chunks: std.ArrayList([]u8),
    pos: usize,
    offsets: std.ArrayList(usize),
    total_data_len: usize,

    pub fn init(allocator: std.mem.Allocator, chunk_size: usize) StorePackedChunked {
        _ = allocator;
        return .{
            .chunk_size = chunk_size,
            .chunks = .empty,
            .pos = 0,
            .offsets = .empty,
            .total_data_len = 0,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.chunks.items) |chunk| {
            allocator.free(chunk);
        }
        self.chunks.deinit(allocator);
        self.offsets.deinit(allocator);
    }

    pub fn store(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !usize {
        if (self.chunks.items.len == 0 or self.pos + path.len > self.chunk_size) {
            const new_chunk = try allocator.alloc(u8, self.chunk_size);
            try self.chunks.append(allocator, new_chunk);
            self.pos = 0;
        }

        const chunk_idx = self.chunks.items.len - 1;
        const global_offset = chunk_idx * self.chunk_size + self.pos;
        try self.offsets.append(allocator, global_offset);

        @memcpy(self.chunks.items[chunk_idx][self.pos..][0..path.len], path);
        self.pos += path.len;
        self.total_data_len = chunk_idx * self.chunk_size + self.pos;
        return self.offsets.items.len - 1;
    }

    pub fn get(self: *@This(), index: usize) []const u8 {
        const global_start = self.offsets.items[index];
        const global_end = if (index + 1 < self.offsets.items.len)
            self.offsets.items[index + 1]
        else
            self.total_data_len;

        const chunk = global_start / self.chunk_size;
        const local = global_start % self.chunk_size;
        return self.chunks.items[chunk][local..local + (global_end - global_start)];
    }

    pub fn len(self: *@This()) usize {
        return self.offsets.items.len;
    }

    pub fn iter(self: *@This()) StorePackedChunkedIter {
        return .{
            .chunks = self.chunks.items,
            .offsets = self.offsets.items,
            .chunk_size = self.chunk_size,
            .total_data_len = self.total_data_len,
            .offset_idx = 0,
        };
    }

    pub fn memoryUsed(self: *const @This()) usize {
        return self.chunks.items.len * self.chunk_size +
            self.offsets.capacity * @sizeOf(usize) +
            self.chunks.capacity * @sizeOf([]u8);
    }
};

pub const StorePackedChunkedIter = struct {
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
        return self.chunks[chunk][local..local + (global_end - global_start)];
    }
};
