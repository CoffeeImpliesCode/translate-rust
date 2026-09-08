//! translate_rust — Rust → Zig translation pipeline.
//! The canonical path is Rust source / wire JSON → RustIr → ZigAST → package.
//! Tree-sitter provides the syntax front-end; `src/model` remains a read-only
//! wire inventory/parser support layer for diagnostics and legacy fixtures.

const std = @import("std");

pub const version = "0.0.0";

// Expose the syntax front-end and the semantic IR under the project namespace.
pub const rust = @import("translate_rust.rust");
pub const model = @import("translate_rust.model");
pub const ir = @import("translate_rust.ir");
pub const frontend = @import("translate_rust.frontend");
pub const backend = @import("translate_rust.backend");
pub const driver = @import("translate_rust.driver");

test {
    std.testing.refAllDecls(@This());
}
