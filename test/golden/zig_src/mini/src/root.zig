pub const util = @import("./util.zig");
const r2z = @import("r2z");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Shape = union(enum) {
    Circle: f64,
    Rect: struct { width: f64, height: f64 },
};

pub fn area(shape: Shape) f64 {
    return switch (shape) {
        .Circle => |r| r2z.ops.binary(r2z.ops.Operation.mul, r2z.ops.Overflow.wrapping, r2z.ops.binary(r2z.ops.Operation.mul, r2z.ops.Overflow.wrapping, r, r), 3.14159),
        .Rect => |__r2z_match_payload| __r2z_match_arm: {
            const width = __r2z_match_payload.width;
            const height = __r2z_match_payload.height;
            break :__r2z_match_arm r2z.ops.binary(r2z.ops.Operation.mul, r2z.ops.Overflow.wrapping, width, height);
        },
    };
}

pub fn origin() Point {
    return Point{ .x = 0, .y = 0 };
}

pub const helper = util.helper;
