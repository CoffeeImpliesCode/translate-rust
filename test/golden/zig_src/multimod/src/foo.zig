const bar = @import("./foo/bar.zig");
const bar_1 = @import("./foo/bar.zig");

pub fn foo_fn() u32 {
    return bar_1.bar_fn();
}
