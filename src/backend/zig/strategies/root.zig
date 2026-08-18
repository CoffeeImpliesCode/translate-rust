//! translate_rust.backend.zig.strategies — collection of lowering strategies.
//! Re-exports the concrete strategy implementations.

const std = @import("std");

/// The standard Zig lowering strategy.
pub const default = @import("default.zig");

test {
    std.testing.refAllDecls(@This());
}
