const std = @import("std");
const toMatcher = @import("main.zig").toMatcher;
const bh = @import("backup_helper_zig");

pub fn VerifyCallbacks(comptime ProgressFn: type, comptime P: type) type {
    return struct {
        matcher: bh.PathMatcher,
        progress: ProgressFn,
        context: *anyopaque,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            progress: ProgressFn,
            context: *anyopaque,
            allow: []const []const u8,
            block: []const []const u8,
        ) !Self {
            const matcher = try toMatcher(allocator, allow, block);
            return .{
                .matcher = matcher,
                .progress = progress,
                .context = context,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.matcher.deinit(allocator);
        }

        pub fn include(relative_path: []const u8, context: *anyopaque) bool {
            const self: *const Self = @ptrCast(@alignCast(context));

            return self.matcher.isMatch(relative_path);
        }

        pub fn progressCb(p: P, context: *anyopaque) bh.progress.CallbackError!void {
            const self: *Self = @ptrCast(@alignCast(context));

            try self.progress(p, self.context);
        }
    };
}
