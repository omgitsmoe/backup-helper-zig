const std = @import("std");
const testing = std.testing;
const FilteredWalker = @import("discover.zig").FilteredWalker;

pub const StoreStr = struct {
    paths: std.ArrayList([]const u8) = .empty,

    pub fn store(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !void {
        const dupe = try allocator.dupe(u8, path);
        try self.paths.append(allocator, dupe);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| {
            allocator.free(path);
        }
        self.paths.deinit(allocator);
    }
};
