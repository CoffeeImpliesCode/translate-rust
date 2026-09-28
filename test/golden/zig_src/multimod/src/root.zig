const foo = @import("./foo.zig");
pub const custom_pub = @import("./custom_pub.zig");

pub fn enter() u32 {
    return 42;
}
