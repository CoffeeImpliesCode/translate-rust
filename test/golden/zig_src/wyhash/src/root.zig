const std = @import("std");
const functions = @import("./functions.zig");

pub const wyhash = functions.wyhash;

pub const wyrng = functions.wyrng;

test "translated tests reachable through ./functions.zig" {
    _ = functions;
}
