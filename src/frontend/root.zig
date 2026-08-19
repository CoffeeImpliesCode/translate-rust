//! translate_rust.frontend.root — the pure Rust understanding layer.
//!
//! Re-exports every frontend submodule: ingestion, CST extraction, body
//! lowering, macro expansion, name resolution, type inference, method
//! resolution, and monomorphization, plus the pipeline orchestrator.
//!
//! Frontend modules import ONLY the IR (`@import("translate_rust.ir")`),
//! tree-sitter, and `translate_rust.rust`. ZERO backend dependencies
//! (no emit.zig, no package.zig, no driver.zig).

const std = @import("std");

/// Frontend submodules (pure Rust understanding).
pub const ingest = @import("ingest.zig");
pub const cst = @import("cst.zig");
pub const ts_ext = @import("ts_ext.zig");
pub const expand = @import("expand.zig");
pub const names = @import("names.zig");
pub const infer = @import("infer.zig");
pub const resolve_methods = @import("resolve_methods.zig");
pub const monomorphize = @import("monomorphize.zig");
pub const pipeline = @import("pipeline.zig");

/// The full frontend pipeline orchestrator.
pub const analyzeCrate = pipeline.analyzeCrate;
pub const analyzeSource = pipeline.analyzeSource;

test {
    _ = @import("expand_test.zig");
    std.testing.refAllDecls(@This());
}
