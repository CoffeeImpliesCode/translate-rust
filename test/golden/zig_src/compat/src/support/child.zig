const std = @import("std");
const support = @import("../support.zig");
const root = @import("../root.zig");

pub fn total() u32 {
    const explicit: support.ParentValue = support.ParentValue{ .value = 7 };
    const constructed: support.ParentValue = support.ParentValue.make();
    return (((explicit.value +% constructed.value) +% support.parent_value()) +% root.root_value());
}

test "translated tests reachable through ../support.zig" {
    _ = support;
}

test "translated tests reachable through ../root.zig" {
    _ = root;
}
