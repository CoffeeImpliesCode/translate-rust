//! translate_rust.backend.zig.strategies — collection of lowering strategies.
//! Re-exports the concrete strategy implementations.

const std = @import("std");

/// The standard Zig lowering strategy.
pub const default = @import("default.zig");

/// The embedded/no-alloc Zig lowering strategy.
pub const embedded = @import("embedded.zig");

test {
    std.testing.refAllDecls(@This());
}
