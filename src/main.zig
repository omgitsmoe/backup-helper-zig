const std = @import("std");
const Io = std.Io;

const backup_helper_zig = @import("backup_helper_zig");

const err = error{
    NotEnoughArguments,
};

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // // This is appropriate for anything that lives as long as the process.
    // const arena: std.mem.Allocator = init.arena.allocator();

    // // Accessing command line arguments:
    // const args = try init.minimal.args.toSlice(arena);
    // for (args) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }

    // // In order to do I/O operations need an `Io` instance.
    // const io = init.io;

    // // Stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try backup_helper_zig.printAnotherMessage(stdout_writer);

    // try stdout_writer.flush(); // Don't forget to flush!

    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        return err.NotEnoughArguments;
    }
    const root = args[1];
    std.debug.print("visiting {s}\n", .{root});
    try testStoreStr(io, gpa, root);
}

fn debugInclude(entry: Io.Dir.Walker.Entry) bool {
    std.debug.print("visiting {s}\n", .{entry.path});
}

fn testStoreStr(io: Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const dir = try std.Io.Dir.openDirAbsolute(
        io,
        root,
        .{ .iterate = true },
    );

    var store = backup_helper_zig.store.StoreStr{};
    defer store.deinit(allocator);

    var walker = try backup_helper_zig.discover.FilteredWalker.init(
        allocator,
        dir,
        null,
    );
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const absPath = try std.fs.path.join(allocator, &[_][]const u8{
            root,
            entry.path,
        });
        defer allocator.free(absPath);

        try store.store(allocator, absPath);
    }

    // for (store.paths.items) |path| {
    //     std.debug.print("{s}\n", .{path});
    // }
    std.debug.print("Stored {} paths\n", .{store.paths.items.len});
}
