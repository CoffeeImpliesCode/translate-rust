const std = @import("std");
const algo = @import("./algo.zig");
const algo_1 = @import("./algo.zig");
const tests = @import("./tests.zig");
const r2z = @import("r2z");

pub const Adler32 = struct {
    const Self = @This();

    a: u16,
    b: u16,

    pub fn new() Adler32 {
        return Adler32.default();
    }

    pub fn from_checksum(sum: u32) Adler32 {
        return Adler32{ .a = @as(u16, @truncate(sum)), .b = @as(u16, @truncate((sum >> @intCast(16)))) };
    }

    pub fn checksum(self: *const Adler32) u32 {
        return ((@as(u32, self.b) << @intCast(16)) | @as(u32, self.a));
    }

    pub fn write_slice(self: *Adler32, bytes: []const u8) void {
        self.compute(bytes);
    }

    pub fn default() Adler32 {
        return Adler32{ .a = 1, .b = 0 };
    }

    pub fn finish(self: *const Adler32) u64 {
        return @as(u64, self.checksum());
    }

    pub fn write(self: *Adler32, bytes: []const u8) void {
        self.write_slice(bytes);
    }

    pub fn compute(self: *Adler32, bytes: []const u8) void {
        const MOD: u32 = 65521;
        const CHUNK_SIZE: usize = (5552 *% 4);
        var a: u32 = @as(u32, self.a);
        var b: u32 = @as(u32, self.b);
        var a_vec: algo_1.U32X4 = algo_1.U32X4{ .@"0" = [_]u32{ 0 } ** 4 };
        var b_vec: algo_1.U32X4 = a_vec;
        const _tuple = r2z.splitAt(bytes, (bytes.len -% (bytes.len % 4)));
        const bytes_1 = _tuple[0];
        const remainder = _tuple[1];
        const chunk_iter: r2z.ChunksExact(u8) = r2z.chunksExact(bytes_1, CHUNK_SIZE);
        const remainder_chunk: []const u8 = r2z.chunksExactRemainder(chunk_iter);
        var __r2z_iter = chunk_iter;
        while (__r2z_iter.next()) |chunk| {
            var __r2z_chunks_exact = r2z.chunksExact(chunk, 4);
            while (__r2z_chunks_exact.next()) |byte_vec| {
                const val: algo_1.U32X4 = algo_1.U32X4.from(byte_vec);
                a_vec.add_assign(val);
                b_vec.add_assign(a_vec);
            }
            b +%= (@as(u32, @truncate(CHUNK_SIZE)) *% a);
            a_vec.rem_assign(MOD);
            b_vec.rem_assign(MOD);
            b %= MOD;
        }
        var __r2z_chunks_exact = r2z.chunksExact(remainder_chunk, 4);
        while (__r2z_chunks_exact.next()) |byte_vec_1| {
            const val_1: algo_1.U32X4 = algo_1.U32X4.from(byte_vec_1);
            a_vec.add_assign(val_1);
            b_vec.add_assign(a_vec);
        }
        b +%= (@as(u32, @truncate(remainder_chunk.len)) *% a);
        a_vec.rem_assign(MOD);
        b_vec.rem_assign(MOD);
        b %= MOD;
        b_vec.mul_assign(4);
        b_vec.@"0"[1] +%= (MOD -% a_vec.@"0"[1]);
        b_vec.@"0"[2] +%= ((MOD -% a_vec.@"0"[2]) *% 2);
        b_vec.@"0"[3] +%= ((MOD -% a_vec.@"0"[3]) *% 3);
        for (a_vec.@"0") |av| {
            a +%= av;
        }
        for (b_vec.@"0") |bv| {
            b +%= bv;
        }
        for (remainder) |byte| {
            a +%= @as(u32, byte);
            b +%= a;
        }
        self.a = @as(u16, @truncate((a % MOD)));
        self.b = @as(u16, @truncate((b % MOD)));
    }
};

pub fn adler32_slice(data: []const u8) u32 {
    var h: Adler32 = Adler32.new();
    h.write_slice(data);
    return h.checksum();
}

test "translated tests reachable through ./tests.zig" {
    _ = tests;
}
