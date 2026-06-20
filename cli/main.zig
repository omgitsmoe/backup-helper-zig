const std = @import("std");

const bh = @import("backup_helper_zig");
const clap = @import("clap");
const File = std.Io.File;
const VerifyCallbacks = @import("verify.zig").VerifyCallbacks;
const ProgressReporter = @import("progress.zig").ProgressReporter;

const SubCommands = enum {
    help,
    incremental,
    build,
    missing,
    fill,
    move,
    verify,
};

fn hashType(in: []const u8) bh.HashType.Error!bh.HashType {
    return bh.HashType.from(in);
}

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
    .path = clap.parsers.string,
    .glob = clap.parsers.string,
    .hash_type = hashType,
    .u64 = clap.parsers.int(u64, 10),
    .u32 = clap.parsers.int(u32, 10),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

const VerifyCommands = enum {
    help,
    file,
    root,
};

const verify_parsers = .{
    .command = clap.parsers.enumeration(VerifyCommands),
};

const incremental_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<path>                                              Root directory for checksum generation
    \\--hash-type <hash_type>                                  Which hash type to use (default: sha512)
    \\-i, --include-unchanged                            Include unchanged files in output
    \\-s, --skip-unchanged                               Skip files with matching modification time
    \\--periodic-write-interval-seconds <u64>            Flush to disk every N seconds
    \\--discover-hash-files-depth <u32>                  Maximum directory depth for discovering checksum files
    \\--keep-deleted                                     Keep entries for deleted files (default: false)
    \\--hash-allow <glob>...                              Glob patterns for allowed checksum sources. If empty, all checksum files are included by default.
    \\--hash-block <glob>...                              Glob patterns for blocked checksum sources. Block patterns always take precedence over allow patterns.
    \\--all-allow <glob>...                               Glob patterns for allowed files in discovery. If empty, all files are included by default.
    \\--all-block <glob>...                               Glob patterns for blocked files in discovery. Block patterns always take precedence over allow patterns.
    \\
);

const build_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<path>                                              Root directory for checksum file discovery
    \\--discover-hash-files-depth <u32>                  Maximum directory depth for discovering checksum files
    \\--keep-deleted                                     Keep entries for deleted files
    \\--hash-allow <glob>...                              Glob patterns for allowed checksum sources. If empty, all checksum files are included by default.
    \\--hash-block <glob>...                              Glob patterns for blocked checksum sources. Block patterns always take precedence over allow patterns.
    \\
);

const move_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<path>                                              Source checksum file path
    \\<path>                                              Destination path
    \\
);

const verify_file_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<path>                                              Path to the checksum file to verify
    \\--verify-allow <glob>...                            Glob patterns for allowed files in verify. If empty, all files are included by default.
    \\--verify-block <glob>...                            Glob patterns for blocked files in verify. Block patterns always take precedence over allow patterns.
    \\
);

const verify_root_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<path>                                              Root directory for checksum file discovery
    \\--discover-hash-files-depth <u32>                  Maximum directory depth for discovering checksum files
    \\--keep-deleted                                     Keep entries for deleted files
    \\--hash-allow <glob>...                              Glob patterns for allowed checksum sources. If empty, all checksum files are included by default.
    \\--hash-block <glob>...                              Glob patterns for blocked checksum sources. Block patterns always take precedence over allow patterns.
    \\--verify-allow <glob>...                            Glob patterns for allowed files in verify. If empty, all files are included by default.
    \\--verify-block <glob>...                            Glob patterns for blocked files in verify. Block patterns always take precedence over allow patterns.
    \\
);

const verify_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

fn printMainHelp(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var w = File.stderr().writer(io, &buf);
    try w.interface.writeAll(
        \\Usage: backup_helper_zig <COMMAND>
        \\
        \\Commands:
        \\  incremental  Creates an incremental checksum file
        \\  build        Creates one checksum file for the given root directory
        \\  missing      Check for files that don't have a checksum yet
        \\  fill         Generate checksums for files that don't have one yet
        \\  move         Move a hash file modifying the relative paths inside
        \\  verify       Subcommands for all verify operations
        \\
        \\Options:
        \\  -h, --help   Display this help and exit
        \\
    );
    try w.interface.flush();
}

fn printVerifyHelp(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var w = File.stderr().writer(io, &buf);
    try w.interface.writeAll(
        \\Usage: backup_helper_zig verify <COMMAND>
        \\
        \\Commands:
        \\  file  Verify a single hash file
        \\  root  Verify hashes in a directory
        \\
        \\Options:
        \\  -h, --help   Display this help and exit
        \\
    );
    try w.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    // skip exe arg
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printMainHelp(init.io);
        return;
    }

    const command = res.positionals[0] orelse {
        try printMainHelp(init.io);
        return;
    };
    switch (command) {
        .help => try printMainHelp(init.io),
        .incremental => try incrementalOrFill(init.io, init.gpa, &iter, .incremental),
        .build => try buildOrMissing(init.io, init.gpa, &iter, .build),
        .missing => try buildOrMissing(init.io, init.gpa, &iter, .missing),
        .fill => try incrementalOrFill(init.io, init.gpa, &iter, .fill),
        .move => try moveCmd(init.io, init.gpa, &iter),
        .verify => try verifyMain(init.io, init.gpa, &iter),
    }
}

fn incrementalOrFill(
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
    comptime command: enum { incremental, fill },
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &incremental_params, &main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &incremental_params, .{});
        return;
    }

    const root = res.positionals[0] orelse return error.MissingPath;
    var hash_files_matcher = try toMatcher(gpa, res.args.@"hash-allow", res.args.@"hash-block");
    defer hash_files_matcher.deinit(gpa);
    var all_files_matcher = try toMatcher(gpa, res.args.@"all-allow", res.args.@"all-block");
    defer all_files_matcher.deinit(gpa);

    var opts = bh.ChecksumHelperOptions.default();
    opts.hash_type = res.args.@"hash-type" orelse .sha512;
    opts.incremental_include_unchanged_files = res.args.@"include-unchanged" != 0;
    opts.incremental_skip_unchanged = res.args.@"skip-unchanged" != 0;
    opts.incremental_periodic_write_interval = if (res.args.@"periodic-write-interval-seconds") |secs|
        std.Io.Duration.fromSeconds(@intCast(secs))
    else
        null;
    opts.discover_hash_files_depth = res.args.@"discover-hash-files-depth";
    opts.most_current_filter_deleted = res.args.@"keep-deleted" == 0;
    opts.hash_files_matcher = hash_files_matcher;
    opts.all_files_matcher = all_files_matcher;

    var reporter = ProgressReporter{ .io = io, .allocator = gpa };
    defer reporter.deinit();

    var ch = try bh.ChecksumHelper.withOptions(io, gpa, root, opts);
    defer ch.deinit();

    var result = try switch (command) {
        .incremental => ch.incremental(ProgressReporter.cbIncremental, &reporter),
        .fill => ch.fillMissing(ProgressReporter.cbIncremental, &reporter),
    };
    defer result.deinit();

    try ch.writeCollection(result);
}

fn buildOrMissing(
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
    comptime command: enum { build, missing },
) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &build_params, &main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &build_params, .{});
        return;
    }

    const root = res.positionals[0] orelse return error.MissingPath;
    var hash_files_matcher = try toMatcher(gpa, res.args.@"hash-allow", res.args.@"hash-block");
    defer hash_files_matcher.deinit(gpa);

    var opts = bh.ChecksumHelperOptions.default();
    opts.discover_hash_files_depth = res.args.@"discover-hash-files-depth";
    opts.most_current_filter_deleted = res.args.@"keep-deleted" == 0;
    opts.hash_files_matcher = hash_files_matcher;

    var reporter = ProgressReporter{ .io = io, .allocator = gpa };
    defer reporter.deinit();

    var ch = try bh.ChecksumHelper.withOptions(io, gpa, root, opts);
    defer ch.deinit();

    switch (command) {
        .build => {
            const collection = try ch.mostCurrent(ProgressReporter.cbMostCurrent, &reporter);
            try ch.writeCollection(collection.*);
        },
        .missing => {
            var result = try ch.checkMissing(ProgressReporter.cbIncremental, &reporter);
            defer result.deinit(gpa);

            var buf: [1024]u8 = undefined;
            var w = File.stderr().writer(io, &buf);

            try w.interface.writeAll("\nMissing directories:\n");
            for (result.directories) |dir| {
                try w.interface.print("  {s}\n", .{dir});
            }

            try w.interface.writeAll("\nMissing files:\n");
            for (result.files) |f| {
                try w.interface.print("  {s}\n", .{f});
            }

            try w.interface.flush();
        },
    }
}

fn moveCmd(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &move_params, &main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &move_params, .{});
        return;
    }

    // TODO: implement move
}

fn verifyMain(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &verify_params, verify_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printVerifyHelp(io);
        return;
    }

    const command = res.positionals[0] orelse {
        try printVerifyHelp(io);
        return;
    };
    switch (command) {
        .help => try printVerifyHelp(io),
        .file => try verifyFile(io, gpa, iter),
        .root => try verifyRoot(io, gpa, iter),
    }
}

fn verifyFile(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &verify_file_params, &main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &verify_file_params, .{});
        return;
    }

    const path = res.positionals[0] orelse return error.MissingPath;
    const root = std.fs.path.dirname(path) orelse return error.InvalidFilePath;

    var reporter = ProgressReporter{ .io = io, .allocator = gpa };
    defer reporter.deinit();

    const CallbackType = VerifyCallbacks(
        bh.progress.VerifyProgressFn,
        bh.progress.VerifyProgress,
    );
    var callbacks = try CallbackType.init(
        gpa,
        ProgressReporter.cbVerify,
        &reporter,
        res.args.@"verify-allow",
        res.args.@"verify-block",
    );
    defer callbacks.deinit(gpa);

    var ch = try bh.ChecksumHelper.init(io, gpa, root);
    defer ch.deinit();

    var collection = try ch.readCollection(path);
    defer collection.deinit();

    try ch.verify(
        collection,
        CallbackType.include,
        CallbackType.progressCb,
        &callbacks,
    );
}

fn verifyRoot(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &verify_root_params, &main_parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stderr(), clap.Help, &verify_root_params, .{});
        return;
    }

    const root = res.positionals[0] orelse return error.MissingPath;
    var hash_files_matcher = try toMatcher(gpa, res.args.@"hash-allow", res.args.@"hash-block");
    defer hash_files_matcher.deinit(gpa);

    var reporter = ProgressReporter{ .io = io, .allocator = gpa };
    defer reporter.deinit();

    const CallbackType = VerifyCallbacks(
        bh.progress.VerifyRootProgressFn,
        bh.progress.VerifyRootProgress,
    );
    var callbacks = try CallbackType.init(
        gpa,
        ProgressReporter.cbVerifyRoot,
        &reporter,
        res.args.@"verify-allow",
        res.args.@"verify-block",
    );
    defer callbacks.deinit(gpa);

    var opts = bh.ChecksumHelperOptions.default();
    opts.discover_hash_files_depth = res.args.@"discover-hash-files-depth";
    opts.most_current_filter_deleted = res.args.@"keep-deleted" == 0;
    opts.hash_files_matcher = hash_files_matcher;

    var ch = try bh.ChecksumHelper.withOptions(io, gpa, root, opts);
    try ch.verifyRoot(CallbackType.include, CallbackType.progressCb, &callbacks);
    ch.deinit();
}

pub fn toMatcher(
    allocator: std.mem.Allocator,
    allow: []const []const u8,
    block: []const []const u8,
) !bh.PathMatcher {
    var builder = bh.PathMatcherBuilder.init(allocator);

    for (allow) |a| {
        try builder.allow(a);
    }

    for (block) |b| {
        try builder.block(b);
    }

    return builder.build();
}
