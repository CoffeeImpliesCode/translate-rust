const std = @import("std");
pub const child = @import("./support/child.zig");

pub const ParentValue = struct {
    const Self = @This();

    value: u32,

    pub fn make() ParentValue {
        return ParentValue{ .value = 11 };
    }
};

pub fn parent_value() u32 {
    return 3;
}

test "translated tests reachable through ./support/child.zig" {
    _ = child;
}
