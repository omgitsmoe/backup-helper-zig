//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const discover = @import("discover.zig");
pub const store = @import("store.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

// TODO:
// - matcher
// - ^ discover: files + hash files
// - incremental
// - build most current
// - verify file/collection

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
