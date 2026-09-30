const algo = @import("./algo.zig");

pub const U32X4 = struct {
    const Self = @This();

    @"0": [4]u32,

    pub fn from(bytes: []const u8) algo.U32X4 {
        return algo.U32X4{ .@"0" = [_]u32{ @as(u32, bytes[0]), @as(u32, bytes[1]), @as(u32, bytes[2]), @as(u32, bytes[3]) } };
    }

    pub fn add_assign(self: *U32X4, other: algo.U32X4) void {
        for (self.@"0"[0..], other.@"0"[0..]) |*s, *o| {
            s.* +%= o.*;
        }
    }

    pub fn rem_assign(self: *U32X4, quotient: u32) void {
        for (self.@"0"[0..]) |*s| {
            s.* %= quotient;
        }
    }

    pub fn mul_assign(self: *U32X4, rhs: u32) void {
        for (self.@"0"[0..]) |*s| {
            s.* *%= rhs;
        }
    }
};
