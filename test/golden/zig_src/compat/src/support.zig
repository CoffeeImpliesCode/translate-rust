const std = @import("std");
const support = @import("./support.zig");
pub const child = @import("./support/child.zig");

pub const ParentValue = struct {
    const Self = @This();

    value: u32,

    pub fn make() support.ParentValue {
        return support.ParentValue{ .value = 11 };
    }
};

pub fn parent_value() u32 {
    return 3;
}

test "translated tests reachable through ./support.zig" {
    _ = support;
}

test "translated tests reachable through ./support/child.zig" {
    _ = child;
}
