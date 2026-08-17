//! Vendored from fletcher 1.1.4 (`test/crates/fletcher`).
//!
//! The crate computes Fletcher-16 through a generic `Fletcher<T>` streaming
//! struct (`update`/`value`/`reduce`/`combine`). The v1 emitter cannot
//! translate structs/generics/method calls, so this golden LOWERS the
//! Fletcher-16 algorithm into a free fn — the correct translation of the
//! algorithm for this dialect. Differential oracle = the crate's own test
//! vectors, translated below into Zig `test` blocks (fletcher-16 only).

const std = @import("std");

const BIT_MASK: u16 = 0x00ff;
const SHIFT_AMOUNT: u16 = 8;
const MAX_CHUNK_SIZE: usize = 21;

/// Reduce a 16-bit accumulator value: fold the low and high bytes, mapping
/// the all-ones result (0xff) to 0 to avoid a zero checksum.
fn reduce(value: u16) u16 {
    const lhs = value & BIT_MASK;
    const rhs = value >> SHIFT_AMOUNT;
    const result = lhs + rhs;
    return if (result == 0xff) 0 else result;
}

/// One-shot Fletcher-16 checksum of a byte slice, processed in chunks of up
/// to MAX_CHUNK_SIZE bytes so the wrapping math mirrors the crate's streaming
/// `Fletcher<u16>` update/reduce cycle.
pub fn calc_fletcher16(data: []const u8) u16 {
    var a: u16 = 0;
    var b: u16 = 0;

    var i: usize = 0;
    while (i < data.len) {
        const chunk_end = @min(i + MAX_CHUNK_SIZE, data.len);
        var ia: u16 = a;
        var ib: u16 = b;

        var j = i;
        while (j < chunk_end) : (j += 1) {
            const byte = @as(u16, data[j]);
            ia +%= byte;
            ib +%= ia;
        }

        a = reduce(ia);
        b = reduce(ib);
        i = chunk_end;
    }

    a = reduce(a);
    b = reduce(b);
    return a | (b << 8);
}

test "fletcher16 ascii data" {
    try std.testing.expectEqual(@as(u16, 0xC8F0), calc_fletcher16("abcde"));
    try std.testing.expectEqual(@as(u16, 0x2057), calc_fletcher16("abcdef"));
    try std.testing.expectEqual(@as(u16, 0x0627), calc_fletcher16("abcdefgh"));
}

test "fletcher16 test" {
    const data = [_]u8{ 0xC1, 0x77, 0xE9, 0xC0, 0xAB, 0x1E };
    try std.testing.expectEqual(@as(u16, 0x3FAD), calc_fletcher16(&data));
}

test "fletcher16 underflow" {
    const zeros = [_]u8{0} ** 200000;
    try std.testing.expectEqual(@as(u16, 0), calc_fletcher16(&zeros));
}

test "fletcher16 overflow" {
    const ones = [_]u8{0xff} ** 200000;
    try std.testing.expectEqual(@as(u16, 0x0000), calc_fletcher16(&ones));
}

test "fletcher16 issue 8" {
    const data = [_]u8{ 0x06, 0x83, 0x0d, 0x00, 0xc5, 0x18, 0xe5, 0x08, 0xef, 0x11 };
    try std.testing.expectEqual(@as(u16, 0x0063), calc_fletcher16(&data));
}

test "fletcher16 wiki example" {
    const data = [_]u8{ 0x01, 0x02, 0xF8, 0x04 };
    try std.testing.expectEqual(@as(u16, 0x0000), calc_fletcher16(&data));
}
