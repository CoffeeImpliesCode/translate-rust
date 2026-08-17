//! translate_rust — exploration of a translate-c-style tool for Rust → Zig.
//! Pipeline not built yet; findings in notes/research/.
//! The Rust grammar front-end (tree-sitter) lives in `rust.zig`.

const std = @import("std");

pub const version = "0.0.0";

// Expose the syntax front-end and the semantic IR under the project namespace.
pub const rust = @import("translate_rust.rust");
pub const model = @import("translate_rust.model");

test {
    std.testing.refAllDecls(@This());
}
