//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const discover = @import("discover.zig");
pub const store = @import("store.zig");

// TODO:
// - discover: files + hash files
// - incremental
// - build most current
// - verify file/collection

// TODO: testing robustness path (ordering etc.)
//       also windows compat of tests

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
