const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;
const testing = std.testing;

const hash = @import("hash.zig");

pub const File = struct {
    path: []const u8,
    mtime: ?Io.Timestamp,
    size: ?u64,
    hash_type: hash.HashType,
    hash_bytes: []const u8,

    pub fn metadata_from_disk(self: *@This(), io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(
            io,
            self.path,
            .{ .allow_directory = false, .path_only = true },
        );
        defer file.close(io);

        const st = try file.stat(io);
        self.mtime = st.mtime;
        self.size = st.size;
    }

    pub fn hash_from_disk(self: *@This(), io: Io, allocator: std.mem.Allocator) !void {
        const file = try Io.Dir.openFileAbsolute(
            io,
            self.path,
            .{ .allow_directory = false },
        );
        defer file.close(io);

        inline for (std.meta.fields(hash.HashType)) |f| {
            if (self.hash_type == @field(hash.HashType, f.name)) {
                const ht = @field(hash.HashType, f.name);

                const hash_bytes = try hash.hashFile(io, file, ht);
                self.hash_bytes = try allocator.dupe(u8, &hash_bytes);
            }
        }
    }
};
