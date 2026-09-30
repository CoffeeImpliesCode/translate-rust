const foo = @import("./foo.zig");

pub fn enter() u32 {
    return 42;
}

pub const custom_pub = @import("./custom_pub.zig");
