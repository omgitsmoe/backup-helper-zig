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
    if (args.len < 3) {
        return err.NotEnoughArguments;
    }
    const root = args[1];
    const method = args[2];
    std.debug.print("using {s}\n", .{root});
    // try testStoreStr(io, gpa, root);
    // try testStoreTree(io, gpa, root);

    const file = try std.Io.Dir.cwd().openFile(io, root, .{});
    var buf: [65536]u8 = undefined;
    var reader = file.reader(io, &buf);

    if (std.mem.eql(u8, method, "str")) {
        try testStoreStrStreaming(gpa, &reader.interface);
    } else if (std.mem.eql(u8, method, "tree")) {
        try testStoreTreeStreaming(gpa, &reader.interface);
    } else if (std.mem.eql(u8, method, "packed")) {
        try testStorePackedStreaming(gpa, &reader.interface);
    } else {
        return error.UnknownMethod;
    }
}

fn debugInclude(entry: Io.Dir.Walker.Entry) bool {
    std.debug.print("visiting {s}\n", .{entry.path});
}

// using paths_real
// Stored 1157340 paths
// Using bytes 92939296 = 90761 KB = 88 MB
// 6.09user 0.10system 0:06.21elapsed 99%CPU (0avgtext+0avgdata 228588maxresident)k
// 0inputs+0outputs (0major+64506minor)pagefaults 0swaps
// using paths_1m
// Stored 1000000 paths
// Using bytes 5064227308 = 4945534 KB = 4829 MB
// 11.17user 2.30system 0:13.56elapsed 99%CPU (0avgtext+0avgdata 7254780maxresident)k
// 0inputs+60462outputs (21major+1843887minor)pagefaults 0swaps
fn testStoreStrStreaming(allocator: std.mem.Allocator, reader: *Io.Reader) !void {
    var store = backup_helper_zig.store.StoreStr{};
    defer store.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |path| {
        try store.store(allocator, path);
    }

    // for (store.paths.items) |path| {
    //     std.debug.print("{s}\n", .{path});
    // }
    std.debug.print("Stored {} paths\n", .{store.paths.items.len});
    const bytesUsed = store.memoryUsed();
    std.debug.print("Using bytes {} = {} KB = {} MB\n", .{
        bytesUsed,
        bytesUsed / 1024,
        bytesUsed / 1024 / 1024,
    });
}

// visiting /mnt/wdata/coding
// Stored 152270 paths
// 1.83user 0.17system 0:02.34elapsed 85%CPU (0avgtext+0avgdata 76988maxresident)k
// ca. 77kb
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

// using paths_real
// Stored 1079134 paths
// Using bytes 112431402 = 109796 KB = 107 MB
// 20.40user 0.03system 0:20.48elapsed 99%CPU (0avgtext+0avgdata 112748maxresident)k
// 0inputs+0outputs (0major+13741minor)pagefaults 0swaps
// using paths_1m
// Stored 1000000 paths
// Using bytes 850236092 = 830308 KB = 810 MB
// 62.79user 0.90system 1:03.74elapsed 99%CPU (0avgtext+0avgdata 576888maxresident)k
// 0inputs+60462outputs (0major+63740minor)pagefaults 0swaps
fn testStoreTreeStreaming(allocator: std.mem.Allocator, reader: *Io.Reader) !void {
    var store = try backup_helper_zig.store.StoreTree.init(allocator, "/");
    defer store.deinit();

    while (try reader.takeDelimiter('\n')) |path| {
        _ = try store.add(path);
    }

    // not storing iteration allocs inside arena, shouldn't count to storage size
    var iter = try store.iter(allocator);
    defer iter.deinit(allocator);
    var paths_num: usize = 0;
    while (try iter.next(allocator)) |node| {
        if (node.children.items.len != 0) {
            // only count leaf nodes
            continue;
        }
        paths_num += 1;
        // const path = try node.path(allocator);
        // defer allocator.free(path);

        // std.debug.print("{s}\n", .{path});
    }
    std.debug.print("Stored {} paths\n", .{paths_num});
    const bytesUsed = store.memoryUsed();
    std.debug.print("Using bytes {} = {} KB = {} MB\n", .{
        bytesUsed,
        bytesUsed / 1024,
        bytesUsed / 1024 / 1024,
    });
}

// using paths_real
// Stored 1157340 paths
// Using bytes 101594165 = 99213 KB = 96 MB
// 0.30user 0.02system 0:00.32elapsed 99%CPU (0avgtext+0avgdata 102976maxresident)k
// 0inputs+0outputs (0major+16967minor)pagefaults 0swaps
// using paths_1m
// Stored 1000000 paths
// Using bytes 5313175672 = 5188648 KB = 5067 MB
// 5.93user 1.14system 0:07.01elapsed 100%CPU (0avgtext+0avgdata 5190520maxresident)k
// 0inputs+60462outputs (0major+1138804minor)pagefaults 0swaps
fn testStorePackedStreaming(allocator: std.mem.Allocator, reader: *Io.Reader) !void {
    var store = backup_helper_zig.store.StorePacked.init(allocator);
    defer store.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |path| {
        try store.store(allocator, path);
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

// visiting /mnt/wdata/coding
// Stored 178443 paths
// 2.98user 0.70system 0:04.03elapsed 91%CPU (0avgtext+0avgdata 51156maxresident)k
// 0inputs+0outputs (0major+318318minor)pagefaults 0swaps
fn testStoreTree(io: Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const dir = try std.Io.Dir.openDirAbsolute(
        io,
        root,
        .{ .iterate = true },
    );

    var store = try backup_helper_zig.store.StoreTree.init(allocator, root);
    defer store.deinit();

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

        _ = try store.add(absPath);
    }

    var iter = try store.iter(allocator);
    defer iter.deinit(allocator);
    var paths_num: usize = 0;
    while (try iter.next(allocator)) |node| : (paths_num += 1) {
        _ = node;
        // const path = try node.path(allocator);
        // defer allocator.free(path);

        // std.debug.print("{s}\n", .{path});
    }
    std.debug.print("Stored {} paths\n", .{paths_num});
}

fn pathsToFile(gpa: std.mem.Allocator, io: std.Io, filename: []const u8) !void {
    var gen = try PathGen.init(gpa, 1_000_000, 0xdeadbeef);
    defer gen.deinit();

    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, filename, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);

    while (try gen.next()) |path| {
        defer gpa.free(path);

        try writer.interface.writeAll(path);
        try writer.interface.writeByte('\n');
        // std.debug.print("{s}\n", .{path});
    }
    try writer.flush();
}

pub const PathGen = struct {
    allocator: std.mem.Allocator,
    rand: std.Random,

    remaining: usize,

    dirs: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, count: usize, seed: u64) !PathGen {
        var prng = std.Random.DefaultPrng.init(seed);

        var dirs = std.ArrayList([]const u8).empty;
        try dirs.append(allocator, try allocator.dupe(u8, "/"));

        return .{
            .allocator = allocator,
            .rand = prng.random(),
            .remaining = count,
            .dirs = dirs,
        };
    }

    pub fn deinit(self: *PathGen) void {
        for (self.dirs.items) |d| {
            self.allocator.free(d);
        }
        self.dirs.deinit(self.allocator);
    }

    pub fn next(self: *PathGen) !?[]const u8 {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        const depth = biasedDepth(self.rand);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        const base = self.dirs.items[self.rand.uintLessThan(usize, self.dirs.items.len)];
        try buf.appendSlice(self.allocator, base);

        var cur_depth: usize = 0;

        while (cur_depth < depth) : (cur_depth += 1) {
            if (buf.items.len > 1) try buf.append(self.allocator, '/');

            const name = try randomName(self.allocator, self.rand);
            defer self.allocator.free(name);

            try buf.appendSlice(self.allocator, name);

            // occasionally register new directory
            if (self.rand.float(f32) < 0.3) {
                const dup = try self.allocator.dupe(u8, buf.items);
                try self.dirs.append(self.allocator, dup);
            }
        }

        if (buf.items.len > 1) try buf.append(self.allocator, '/');

        const file = try randomFileName(self.allocator, self.rand);
        defer self.allocator.free(file);

        try buf.appendSlice(self.allocator, file);

        return try self.allocator.dupe(u8, buf.items);
    }
};

fn biasedDepth(rand: std.Random) usize {
    const r = rand.float(f32);

    // heavily skewed distribution
    return if (r < 0.5) 1 else if (r < 0.75) 2 else if (r < 0.9) 3 else if (r < 0.97) 4 else rand.uintLessThan(usize, 8) + 5; // rare deep paths
}

fn randomName(
    allocator: std.mem.Allocator,
    rand: std.Random,
) ![]u8 {
    const len = nameLength(rand);

    const buf = try allocator.alloc(u8, len);

    for (buf) |*c| {
        const choice = rand.uintLessThan(u8, 36);
        c.* = if (choice < 26)
            'a' + choice
        else
            '0' + (choice - 26);
    }

    return buf;
}

fn randomFileName(
    allocator: std.mem.Allocator,
    rand: std.Random,
) ![]u8 {
    const base = try randomName(allocator, rand);
    defer allocator.free(base);

    const ext = extensions[rand.uintLessThan(usize, extensions.len)];

    var buf = try allocator.alloc(u8, base.len + 1 + ext.len);
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '.';
    @memcpy(buf[base.len + 1 ..], ext);

    return buf;
}

fn nameLength(rand: std.Random) usize {
    const r = rand.float(f32);

    return if (r < 0.6) rand.uintLessThan(usize, 8) + 3 // short
    else if (r < 0.9) rand.uintLessThan(usize, 16) + 8 // medium
    else rand.uintLessThan(usize, 64) + 16; // long
}

const extensions = [_][]const u8{
    "txt", "log", "json", "bin", "data",
    "jpg", "png", "mp4",  "mp3", "zip",
};
