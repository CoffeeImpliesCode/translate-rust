const std = @import("std");
const r2z = @import("r2z");

pub const FromHexError = union(enum) {
    InvalidHexCharacter: struct { c: u21, index: usize },
    OddLength: void,
    InvalidStringLength: void,

    pub fn fmt(self: *const FromHexError, f: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (self.*) {
            .InvalidHexCharacter => |__r2z_match_payload| __r2z_match_arm: {
                const c = __r2z_match_payload.c;
                const index = __r2z_match_payload.index;
                break :__r2z_match_arm __r2z_value_block_4: {
                    break :__r2z_value_block_4 r2z.format.write(f, "Invalid character {:?} at position {}", .{ c, index });
                };
            },
            .OddLength => r2z.format.write(f, "Odd number of digits", .{}),
            .InvalidStringLength => r2z.format.write(f, "Invalid string length", .{}),
        };
    }
};
