//! translate_rust.backend — the target-language backend layer.
//! A `LoweringStrategy` plus backend-specific implementation (currently Zig).

const std = @import("std");

/// Pluggable lowering strategies (opaque context + vtable).
pub const strategy = @import("strategy.zig");

/// The Zig backend implementation.
pub const zig = @import("zig/root.zig");

test {
    std.testing.refAllDecls(@This());
}
