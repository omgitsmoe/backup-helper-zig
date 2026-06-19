//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const checksum_helper = @import("checksum_helper.zig");
pub const ChecksumHelper = checksum_helper.ChecksumHelper;
pub const ChecksumHelperOptions = checksum_helper.Options;
pub const ChecksumMissingResult = checksum_helper.CheckMissingResult;
pub const HashType = @import("hash.zig").HashType;

// TODO: testing robustness pass (ordering etc.)
//       also windows compat of tests
//       + check if immutable parameters are enough

test "discover" {
    _ = @import("discover.zig");
}

test "file" {
    _ = @import("file.zig");
}

test "hash" {
    _ = @import("hash.zig");
}

test "store" {
    _ = @import("store.zig");
}

test "collection" {
    _ = @import("collection.zig");
}

test "parser" {
    _ = @import("parser.zig");
}

test "parser_single" {
    _ = @import("parser_single.zig");
}

test "serializer" {
    _ = @import("serializer.zig");
}

test "matcher" {
    _ = @import("matcher.zig");
}

test "most_current" {
    _ = @import("most_current.zig");
}

test "incremental" {
    _ = @import("incremental.zig");
}

test "checksum_helper" {
    _ = @import("checksum_helper.zig");
}
