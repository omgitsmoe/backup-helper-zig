const std = @import("std");
const hash = std.crypto.hash;
const Dir = std.Io.Dir;
const Io = std.Io;
const testing = std.testing;

pub const HashType = enum {
    md5,
    sha256,
    sha512,
    sha3_256,
    sha3_512,

    pub fn str(self: @This()) []const u8 {
        return @tagName(self);
    }

    pub fn from(name: []const u8) !@This() {
        return std.meta.stringToEnum(@This(), name) orelse error.UnknownHashType;
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
};

pub const File = struct {
    path: []const u8,
    mtime: ?u64,
    size: ?u64,
    hash_type: HashType,
    hash_bytes: []const u8,
};

fn hashFile(io: Io, file: std.Io.File, comptime hash_type: HashType) ![hash_type.toHasher().digest_length]u8 {
    const hasher_type = hash_type.toHasher();
    var hasher = hasher_type.init(.{});
    // const file = try Dir.openFileAbsolute(io, path, .{ .allow_directory = false });

    var buf: [65536]u8 = undefined;
    var r = file.reader(io, &buf);

    while (true) {
        // NOTE: read __at least__ 1 byte (otherwise error.EndOfStream)
        //       then clear the buffered content that was returned
        const chunk = r.interface.peekGreedy(1) catch break;
        defer r.interface.toss(chunk.len);

        hasher.update(chunk);
    }

    var hashBytes: [hasher_type.digest_length]u8 = undefined;
    hasher.final(&hashBytes);
    return hashBytes;
}

test hashFile {
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

    inline for ([_]HashType{ .md5, .sha256 }) |hash_type| {
        const file = try tmp.dir.openFile(io, "file.txt", .{});
        defer file.close(io);
        const actualBytes = try hashFile(io, file, hash_type);

        const expectedBytes = hashTypeToExpected.get(hash_type) orelse @panic("missing mapping");
        try testing.expectEqualSlices(u8, expectedBytes[0..], &actualBytes);
    }
}
