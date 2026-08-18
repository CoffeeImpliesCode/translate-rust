//! translate_rust.model — public module root for the lossless semantic IR.
//! Re-exports the shared spine, the crate & module graph, and the JSON
//! boundary. Layering: json.zig loads/saves graph.zig, which hangs off the
//! spine.zig symbol table.

const std = @import("std");

pub const spine = @import("spine.zig");
pub const graph = @import("graph.zig");
pub const json = @import("json.zig");
pub const emit = @import("emit.zig");
pub const package = @import("package.zig");
pub const driver = @import("driver.zig");
pub const ts_ext = @import("ts_ext.zig");
pub const cst = @import("cst.zig");
pub const names = @import("names.zig");
pub const types = @import("types.zig");
pub const bodies = @import("bodies.zig");
pub const items = @import("items.zig");
pub const exprs = @import("exprs.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("graph.zig"); // include graph + json + emit test blocks
    _ = @import("json.zig");
    _ = @import("emit.zig");
    _ = @import("emit_fnv_test.zig");
    _ = @import("emit_hex_test.zig");
    _ = @import("package.zig");
    _ = @import("emit_m3m4_test.zig");
    _ = @import("names.zig");
    _ = @import("names_test.zig");
}
