const std = @import("std");
const Io = std.Io;

const backup_helper_zig = @import("backup_helper_zig");

const err = error{
    NotEnoughArguments,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        return err.NotEnoughArguments;
    }
    const root = args[1];
    std.debug.print("using {s}\n", .{root});
    // try testStoreStr(io, gpa, root);
    // try testStoreTree(io, gpa, root);

    const file = try std.Io.Dir.cwd().openFile(io, root, .{});
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);

    try testStorePackedChunkedStreaming(gpa, &reader.interface);
}

fn testStorePackedChunkedStreaming(allocator: std.mem.Allocator, reader: *Io.Reader) !void {
    var store = backup_helper_zig.store.StorePackedChunked.init(allocator, 65536);
    defer store.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |path| {
        _ = try store.store(allocator, path);
    }

    // var iter = store.iter();
    // while (iter.next()) |path| {
    //     std.debug.print("{s}\n", .{path});
    // }

    std.debug.print("Stored {} paths\n", .{store.len()});
    const bytesUsed = store.memoryUsed();
    std.debug.print("Using bytes {} = {} KB = {} MB\n", .{
        bytesUsed,
        bytesUsed / 1024,
        bytesUsed / 1024 / 1024,
    });
}
