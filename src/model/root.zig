//! translate_rust.model — public module root for the lossless semantic IR.
//! Re-exports the shared spine, the crate & module graph, and the JSON
//! boundary. Layering: json.zig loads/saves graph.zig, which hangs off the
//! spine.zig symbol table.

const std = @import("std");

pub const spine = @import("spine.zig");
pub const graph = @import("graph.zig");
pub const json = @import("json.zig");
pub const ts_ext = @import("ts_ext.zig");
pub const cst = @import("cst.zig");
pub const names = @import("names.zig");
pub const infer = @import("infer.zig");
pub const types = @import("types.zig");
pub const bodies = @import("bodies.zig");
pub const items = @import("items.zig");
pub const exprs = @import("exprs.zig");
pub const expand = @import("expand.zig");
pub const resolve_methods = @import("resolve_methods.zig");
pub const monomorphize = @import("monomorphize.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("graph.zig");
    _ = @import("json.zig");
    _ = @import("names.zig");
    _ = @import("names_test.zig");
    _ = @import("infer.zig");
    _ = @import("infer_test.zig");
    _ = @import("resolve_methods.zig");
    _ = @import("resolve_methods_test.zig");
    _ = @import("exprs.zig");
    _ = @import("expand.zig");
    _ = @import("monomorphize.zig");
    _ = @import("monomorphize_test.zig");
    _ = @import("expand_test.zig");
}
