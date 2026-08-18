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

/// The entire semantic model of a translated crate: its crate graph, the
/// crate-level type table, and the body (expr/statement/pattern) store.
pub const RustIR = struct {
    crate_name: []const u8,
    edition: []const u8 = "2021",
    graph: graph.CrateGraph,
    types: []const types.Type = &.{},
    bodies: bodies.Bodies,
};

test {
    std.testing.refAllDecls(@This());
}
