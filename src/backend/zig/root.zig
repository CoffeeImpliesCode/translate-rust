//! translate_rust.backend.zig — the Zig target backend.
//! Exposes the target-language AST for Zig packages, the lowering engine,
//! JSON serialization for snapshot testing, and pluggable lowering strategies.

const std = @import("std");

/// Structured DOM for Zig source packages.
pub const ast = @import("ast.zig");
/// Text emitter: ast.Package/File -> Zig source.
pub const emit = @import("emit.zig");
/// Package writer: ast.Package -> files on disk (build.zig, build.zig.zon, src/*).
pub const package = @import("package.zig");
/// Lowering engine: RustIr to ast.Package.
pub const lower = @import("lower.zig");
/// Lowering engine tests.
pub const lower_test = @import("lower_test.zig");
/// Text emitter tests.
pub const emit_test = @import("emit_test.zig");
/// JSON encoder/decoder for ast.Package.
pub const serialize = @import("serialize.zig");
/// Pluggable lowering strategies.
pub const strategies = @import("strategies/root.zig");

test {
    std.testing.refAllDecls(@This());
}
