const std = @import("std");
const hash = std.crypto.hash;
const Dir = std.Io.Dir;
const Io = std.Io;
const testing = std.testing;

const prog = @import("progress.zig");
const build_options = @import("build_options");

pub const HashType = enum {
    md5,
    sha256,
    sha512,
    sha3_256,
    sha3_512,

    pub const Error = error{
        UnknownHashType,
    };

    pub fn str(self: @This()) []const u8 {
        return @tagName(self);
    }

    pub fn from(name: []const u8) !@This() {
        return std.meta.stringToEnum(@This(), name) orelse Error.UnknownHashType;
    }

    pub fn toHasher(self: @This()) type {
        return switch (self) {
            .md5 => hash.Md5,
            .sha256 => hash.sha2.Sha256,
            .sha512 => hash.sha2.Sha512,
            .sha3_256 => hash.sha3.Sha3_256,
            .sha3_512 => hash.sha3.Sha3_512,
        };
    }

    pub fn maxTagNameLen() usize {
        const T = @This();
        var max_len: usize = 0;

        inline for (std.meta.tags(T)) |tag| {
            const name = @tagName(tag);
            max_len = @max(max_len, name.len);
        }

        return max_len;
    }
};

pub fn hashFile(
    io: Io,
    file: std.Io.File,
    comptime hash_type: HashType,
    progress: ?*const fn (bytes_read: u64, context: *anyopaque) prog.CallbackError!void,
    context: *anyopaque,
) ![hash_type.toHasher().digest_length]u8 {
    if (comptime hash_type == .sha512 and build_options.use_openssl) {
        return hashFileOpensslSha512(io, file, progress, context);
    }

    const hasher_type = hash_type.toHasher();
    var hasher = hasher_type.init(.{});

    var buf: [65536]u8 = undefined;
    var r = file.reader(io, &buf);

    var read_total: u64 = 0;
    while (true) {
        // NOTE: read __at least__ 1 byte (otherwise error.EndOfStream)
        //       then clear the buffered content that was returned
        const chunk = r.interface.peekGreedy(1) catch break;
        defer r.interface.toss(chunk.len);

        hasher.update(chunk);

        read_total += chunk.len;
        if (progress) |func| {
            try func(read_total, context);
        }
    }

    var hashBytes: [hasher_type.digest_length]u8 = undefined;
    hasher.final(&hashBytes);
    return hashBytes;
}

fn hashFileOpensslSha512(
    io: Io,
    file: std.Io.File,
    progress: ?*const fn (bytes_read: u64, context: *anyopaque) prog.CallbackError!void,
    context: *anyopaque,
) ![64]u8 {
    const ctx = EVP_MD_CTX_new() orelse return error.OutOfMemory;
    defer EVP_MD_CTX_free(ctx);

    if (EVP_DigestInit_ex(ctx, EVP_sha512(), null) != 1) return error.HashFunctionFailed;

    var buf: [65536]u8 = undefined;
    var r = file.reader(io, &buf);

    var read_total: u64 = 0;
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch break;
        defer r.interface.toss(chunk.len);

        if (EVP_DigestUpdate(ctx, chunk.ptr, chunk.len) != 1) return error.HashFunctionFailed;

        read_total += chunk.len;
        if (progress) |func| {
            try func(read_total, context);
        }
    }

    var hash_bytes: [64]u8 = undefined;
    var hash_len: c_uint = 64;
    if (EVP_DigestFinal_ex(ctx, &hash_bytes, &hash_len) != 1) return error.HashFunctionFailed;

    return hash_bytes;
}

extern fn EVP_MD_CTX_new() callconv(.c) ?*anyopaque;
extern fn EVP_MD_CTX_free(ctx: ?*anyopaque) callconv(.c) void;
extern fn EVP_DigestInit_ex(ctx: *anyopaque, md: *anyopaque, impl: ?*anyopaque) callconv(.c) c_int;
extern fn EVP_DigestUpdate(ctx: *anyopaque, data: [*]const u8, len: usize) callconv(.c) c_int;
extern fn EVP_DigestFinal_ex(ctx: *anyopaque, md: [*]u8, len: *c_uint) callconv(.c) c_int;
extern fn EVP_sha512() callconv(.c) *anyopaque;

test hashFile {
    const helpers = @import("test_helpers.zig");
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello world!" });

    // const expectedMd5 = "fc3ff98e8c6a0d3087d515c0473f8677";
    // const expectedSha256 = "7509e5bda0c762d2bac7f90d758b5b2263fa01ccbc542ab5e3df163be08e6ca9";
    var hashTypeToExpected = std.EnumMap(HashType, []const u8).init(.{});
    const expectedMd5Bytes = [_]u8{
        0xfc, 0x3f, 0xf9, 0x8e, 0x8c, 0x6a, 0x0d, 0x30,
        0x87, 0xd5, 0x15, 0xc0, 0x47, 0x3f, 0x86, 0x77,
    };
    hashTypeToExpected.put(.md5, &expectedMd5Bytes);
    const expectedSha256Bytes = [_]u8{
        0x75, 0x09, 0xe5, 0xbd, 0xa0, 0xc7, 0x62, 0xd2, 0xba, 0xc7, 0xf9, 0x0d,
        0x75, 0x8b, 0x5b, 0x22, 0x63, 0xfa, 0x01, 0xcc, 0xbc, 0x54, 0x2a, 0xb5,
        0xe3, 0xdf, 0x16, 0x3b, 0xe0, 0x8e, 0x6c, 0xa9,
    };
    hashTypeToExpected.put(.sha256, &expectedSha256Bytes);
    const expectedSha512Bytes = [_]u8{
        0xdb, 0x9b, 0x1c, 0xd3, 0x26, 0x2d, 0xee, 0x37,
        0x75, 0x6a, 0x09, 0xb9, 0x06, 0x49, 0x73, 0x58,
        0x98, 0x47, 0xca, 0xa8, 0xe5, 0x3d, 0x31, 0xa9,
        0xd1, 0x42, 0xea, 0x27, 0x01, 0xb1, 0xb2, 0x8a,
        0xbd, 0x97, 0x83, 0x8b, 0xb9, 0xa2, 0x70, 0x68,
        0xba, 0x30, 0x5d, 0xc8, 0xd0, 0x4a, 0x45, 0xa1,
        0xfc, 0xf0, 0x79, 0xde, 0x54, 0xd6, 0x07, 0x66,
        0x69, 0x96, 0xb3, 0xcc, 0x54, 0xf6, 0xb6, 0x7c,
    };
    hashTypeToExpected.put(.sha512, &expectedSha512Bytes);

    const CbCapture = helpers.CallbackCapture(u64);
    var capture: CbCapture = .init(testing.allocator);
    defer capture.deinit();

    inline for ([_]HashType{ .md5, .sha256, .sha512 }) |hash_type| {
        const file = try tmp.dir.openFile(io, "file.txt", .{});
        defer file.close(io);
        const actualBytes = try hashFile(io, file, hash_type, &CbCapture.cb, &capture);

        const expectedBytes = hashTypeToExpected.get(hash_type) orelse @panic("missing mapping");
        try testing.expectEqualSlices(u8, expectedBytes[0..], &actualBytes);
    }

    try helpers.expectEqualSlicesDeep(u64, &[_]u64{ 12, 12, 12 }, capture.captures.items);
}
