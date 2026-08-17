//! translate_rust — exploration of a translate-c-style tool for Rust → Zig.
//! Research phase: pipeline not built yet; findings in notes/research/.
//!
//! Direction: a tool that takes a Rust crate and emits correct, idiomatic
//! Zig — the Rust analogue of Zig's translate-c (clang AST → Zig source).

const std = @import("std");

pub const version = "0.0.0";

test {
    std.testing.refAllDecls(@This());
}
