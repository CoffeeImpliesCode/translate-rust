//! translate_rust.ir.root — the target-agnostic Rust Semantic IR.
//! Pure semantic model: target-agnostic, no backend dependencies.
//! Consumers (backends, the CLI) import this root and navigate the model.

const std = @import("std");

/// Self-contained semantic IR submodules.
pub const spine = @import("spine.zig");
pub const graph = @import("graph.zig");
pub const types = @import("types.zig");
pub const exprs = @import("exprs.zig");
pub const bodies = @import("bodies.zig");
pub const ownership = @import("ownership.zig");
pub const items = @import("items.zig");
pub const serialize = @import("serialize.zig");
pub const std_model = @import("std_model.zig");
pub const validation = @import("validate.zig");
pub const validateForTranslation = validation.validateForTranslation;
pub const ValidationError = validation.ValidationError;

/// The canonical wire body entry. Body ownership is explicit on the wire,
/// while `RustIr.bodies.bodies` remains the dense in-memory lookup table.
pub const BodySlot = serialize.BodySlot;

/// The entire semantic model of a translated crate.
///
/// The definition lives beside the wire codec so decoded values and
/// frontend-produced values share one nominal type.
pub const RustIr = serialize.RustIr;

test {
    std.testing.refAllDecls(@This());
}
