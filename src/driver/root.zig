//! translate_rust.driver — the high-level end-to-end translation pipeline.
//!
//! Exposes `pipeline.translate` (Rust source -> package), `translateWireJson`
//! (wire JSON -> package), and `fixFingerprint` (self-healing build.zig.zon).

const std = @import("std");

/// End-to-end translation pipeline (Rust source / wire JSON -> Zig package).
pub const pipeline = @import("pipeline.zig");

/// Translate a Rust crate directory into a standalone Zig package at `out_dir`.
pub const translate = pipeline.translate;

/// Translate a wire-format v2 JSON dump into a standalone Zig package at `out_dir`.
pub const translateWireJson = pipeline.translateWireJson;

/// Self-heal the `.fingerprint` in a generated package's `build.zig.zon`.
pub const fixFingerprint = pipeline.fixFingerprint;

/// Read a whole file into memory with allocation (re-exported helper).
pub const readFileAlloc = pipeline.readFileAlloc;

test {
    std.testing.refAllDecls(@This());
}
