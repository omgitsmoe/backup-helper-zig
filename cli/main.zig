const std = @import("std");
const Io = std.Io;

const backup_helper_zig = @import("backup_helper_zig");

const err = error{
    NotEnoughArguments,
};

pub fn main(init: std.process.Init) !void {
    _ = init; // autofix
    // const gpa = init.gpa;
    // const io = init.io;

    // const args = try init.minimal.args.toSlice(init.arena.allocator());
    // if (args.len < 2) {
    //     return err.NotEnoughArguments;
    // }
    // const root = args[1];
    // std.debug.print("using {s}\n", .{root});

    // const file = try std.Io.Dir.cwd().openFile(io, root, .{});
    // var buf: [65536]u8 = undefined;
    // var reader = file.reader(io, &buf);
    std.debug.print("hello world!\n", .{});
}
