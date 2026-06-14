const std = @import("std");
const HashType = @import("hash.zig").HashType;
const Io = std.Io;

const PathMatcher = @import("matcher.zig").PathMatcher;

pub const Options = struct {
    /// Which hash algorithm to use for generating new hashes.
    hash_type: HashType,

    /// Whether to include files in the output, which did not change compared
    /// to the previous latest available hash found.
    incremental_include_unchanged_files: bool,

    /// Whether to skip files when computing hashes if that files has the same
    /// modification time as in the latest available hash found.
    incremental_skip_unchanged: bool,

    /// If Some, periodically flushes the incremental hash collection
    /// to disk upon the next modification after the specified time interval.
    incremental_periodic_write_interval: ?Io.Duration,

    /// Up to which depth should the root and its subdirectories be searched
    /// for hash files (*.cshd, *.md5, *.sha512, etc.) to determine the
    /// current state of hashes.
    /// Zero means only files in the root directory will be considered.
    /// One means at most one subdirectory will be allowed.
    /// None means no depth limit.
    discover_hash_files_depth: ?u32,

    /// Whether the most_current hash file should filter out all files that are
    /// not found on disk at the time of generation.
    most_current_filter_deleted: bool,

    /// Allow/block list like matching for hash files which will be used
    /// for building the most current state of hashes.
    /// These hashes will be used when e.g. using the `incremental`
    /// method.
    hash_files_matcher: PathMatcher,

    /// Allow/block list like matching for all files.
    /// Affects all file discovery behaviour: which files get included
    /// in an incremental hash file, which files are ignored when checking
    /// for files that don't have checksums in `check_missing`, etc.
    all_files_matcher: PathMatcher,
};

pub fn defaultHashFileName(
    io: Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    default: []const u8,
    infix: []const u8,
) (std.mem.Allocator.Error || Io.Writer.Error)![]u8 {
    const dirname = std.fs.path.basename(directory);
    const base = if (dirname.len == 0 or std.mem.eql(u8, dirname, "."))
        default
    else
        dirname;

    const now = Io.Timestamp.now(io, .real);

    // YYYY-MM-DDTHHMMSS
    //                  ^ 18
    const time_string_bytes_max = 20;
    var buf: [Io.Dir.max_name_bytes + time_string_bytes_max]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);

    try writer.print("{s}_{s}", .{ base, infix });
    try now.formatNumber(&writer, .{});

    const dupe = allocator.dupe(u8, writer.buffered());
    return dupe;
}
