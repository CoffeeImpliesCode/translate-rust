> **Historical design record — not current coverage.** Written during the
> exploration phase of this translator. It records a proposed design, not what
> the translator does today. Nothing here is a claim that `translate-rust`
> supports a Rust shape. For what the translator actually translates, read the
> [repository README](../../../README.md).

# Package Generation, Dependency Graph, and Macro Expansion Architecture

Design specification for translate-rust (Rust to Zig 0.16 transpiler).
Covers package generation (`r2z-<crate>/`), manifest translation (`Cargo.toml` to `build.zig.zon` and `build.zig`), dependency graph resolution, multi-file code emission, and macro expansion.

- Upstream research: `notes/research/parsing-tooling.md` (§2.3, §2.6), `notes/research/idiom-mapping.md` (§1).
- Semantic data models: `notes/design/data-model/crate-graph.md`, `notes/design/data-model/items-types.md`.
- Target: Zig 0.16.0 stable.

---

## 1. Package Structure & Manifest Mapping (`Cargo.toml` -> Zig 0.16)

### 1.1 Physical Layout of `r2z-<crate>/`

Each translated Rust crate becomes an independent Zig package named `r2z-<crate>`. The transpiler emits a standard Zig package layout:

```text
r2z-<crate>/
├── build.zig.zon          # Package metadata, fingerprint, dependencies
├── build.zig              # Build logic, modules, artifacts, test runner
└── src/
    ├── root.zig           # Translated crate root (lib.rs or main.rs)
    ├── util.zig           # Translated submodule (src/util.rs)
    └── codec/
        └── hex.zig        # Translated nested submodule (src/codec/hex.rs)
```

The output root directory isolates translated code from source Rust code.

### 1.2 Manifest Field Mapping

`Cargo.toml` manifests map deterministically to Zig 0.16 build constructs:

| Cargo Manifest Field | Zig 0.16 Construct | Mapping Mechanism |
|---|---|---|
| `[package].name` | `build.zig.zon` `.name` | Prefixed identifier: `.@"r2z-<name>"` |
| `[package].version` | `build.zig.zon` `.version` | Semver string verbatim |
| `[package].edition` | Compiler resolution pass | Controls path resolution rules (2015 vs 2018+) |
| `[dependencies]` | `build.zig.zon` `.dependencies` | Path or URL/hash dependencies |
| `[features]` | `build.zig` `b.option()` | Exposed as a `config` options module |
| `[target.'...'.dependencies]` | `build.zig` conditional logic | Guarded by `target.result.os.tag` queries |

#### Feature Flag Desugaring
Rust features configure conditional compilation (`#[cfg(feature = "...")]`). In Zig 0.16, the transpiler generates a `config` module via `b.addOptions()`. Source modules query features at compile time:

```zig
const config = @import("config");

pub fn encode(data: []const u8) ![]u8 {
    if (comptime config.feature_alloc) {
        // Feature "alloc" enabled
    } else {
        @compileError("encode requires feature 'alloc'");
    }
}
```

### 1.3 Concrete Manifest Examples

#### `build.zig.zon` for `r2z-hex`
```zig
.{
    .name = .@"r2z-hex",
    .version = "0.4.3",
    .fingerprint = 0xb97cfc0a37e1b52a,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .@"r2z-serde" = .{
            .path = "../r2z-serde",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

#### `build.zig` for `r2z-hex`
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const feat_serde = b.option(bool, "serde", "Enable serde serialization support") orelse false;
    const feat_alloc = b.option(bool, "alloc", "Enable heap allocation features") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "feature_serde", feat_serde);
    options.addOption(bool, "feature_alloc", feat_alloc);

    const mod = b.addModule("r2z_hex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("config", options);

    if (feat_serde) {
        const serde_dep = b.dependency("r2z-serde", .{
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("r2z_serde", serde_dep.module("r2z_serde"));
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "r2z_hex",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const test_mod = b.addModule("test_r2z_hex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("config", options);
    if (feat_serde) {
        const serde_dep = b.dependency("r2z-serde", .{
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("r2z_serde", serde_dep.module("r2z_serde"));
    }

    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);
}
```

---

## 2. Inter-Crate Dependency Translation & Workspace Resolution

### 2.1 Topological Workspace Resolution

Multi-crate Rust workspaces form Directed Acyclic Graphs (DAGs). The transpiler resolves translation order using Kahn's algorithm over `CrateGraph` (`notes/design/data-model/crate-graph.md` §1.3):

```text
       [ r2z-core ] (Leaf: 0 dependencies)
            ^
            |
       [ r2z-codec ]
            ^
            |
    +-------+-------+
    |               |
[ r2z-client ]  [ r2z-server ]
```

1. **Calculate In-Degrees**: Count unresolved dependencies for each crate in the workspace.
2. **Initialize Queue**: Enqueue all leaf crates (in-degree = 0).
3. **Iterative Emission**:
   - Dequeue crate `C`.
   - Transpile `C` and emit `r2z-C/`.
   - Decrement in-degree for all crates depending on `C`.
   - If in-degree reaches 0, enqueue dependent crate.
4. **Cycle Guard**: If processed crate count does not equal total workspace crate count, abort with dependency cycle diagnostic.

### 2.2 Dependency Interconnection Rules

1. **Local Workspace Dependencies**: Emitted in `build.zig.zon` with relative directory paths:
   ```zig
   .@"r2z-common" = .{ .path = "../r2z-common" }
   ```
2. **External crates.io Dependencies**: Transpiler emits pre-transpiled vendor packages or references remote package URLs with integrity hashes:
   ```zig
   .@"r2z-fnv" = .{
       .url = "https://github.com/example/r2z-fnv/archive/v1.0.7.tar.gz",
       .hash = "1220a6b...",
   }
   ```
3. **Source Import Mapping**:
   Rust code accessing an external crate via `use fnv::FnvHasher;` becomes:
   ```zig
   const r2z_fnv = @import("r2z_fnv");
   const FnvHasher = r2z_fnv.FnvHasher;
   ```

---

## 3. Module Tree & Multi-File Code Emission

### 3.1 Module System Mapping

Rust modules define namespaces and compilation units. Zig files are struct containers accessed via `@import`.

| Rust Module Declaration | Rust File Location | Emitted Zig File | Emission Mechanism |
|---|---|---|---|
| Crate root | `src/lib.rs` / `src/main.rs` | `src/root.zig` | Root compilation unit |
| `mod foo;` (2018 edition) | `src/foo.rs` | `src/foo.zig` | Standalone file |
| `mod foo;` (2015 edition) | `src/foo/mod.rs` | `src/foo.zig` | Normalized to file without `mod.zig` |
| `mod bar;` inside `foo` | `src/foo/bar.rs` | `src/foo/bar.zig` | Nested subdirectory file |
| `mod inline { ... }` | Inside parent file | Inlined in parent `.zig` | `pub const inline = struct { ... };` |

### 3.2 Filesystem Path Calculation Algorithm

The transpiler computes output paths deterministically:

```zig
pub fn computeZigSourcePath(
    allocator: std.mem.Allocator,
    rust_relative_path: []const u8,
    is_crate_root: bool,
) ![]const u8 {
    if (is_crate_root) {
        return try std.fs.path.join(allocator, &.{ "src", "root.zig" });
    }

    // Strip "src/" prefix if present
    var clean_path = rust_relative_path;
    if (std.mem.startsWith(u8, clean_path, "src/")) {
        clean_path = clean_path[4..];
    }

    // Normalize foo/mod.rs -> foo.zig
    if (std.mem.endsWith(u8, clean_path, "/mod.rs")) {
        const base = clean_path[0 .. clean_path.len - 7];
        return try std.fmt.allocPrint(allocator, "src/{s}.zig", .{base});
    }

    // Normalize foo.rs -> foo.zig
    if (std.mem.endsWith(u8, clean_path, ".rs")) {
        const base = clean_path[0 .. clean_path.len - 3];
        return try std.fmt.allocPrint(allocator, "src/{s}.zig", .{base});
    }

    return error.InvalidRustSourcePath;
}
```

### 3.3 Relative Import Resolution

Zig requires exact relative path strings in `@import(...)`. The emitter calculates path hops between modules:

```text
src/root.zig               -> @import("codec/hex.zig")
src/codec/hex.zig          -> @import("../root.zig")
src/codec/hex.zig          -> @import("encoder.zig")
```

### 3.4 Re-exports (`pub use`)

Zig 0.16 does not support wildcard re-exports (`pub use foo::*`). The transpiler queries the semantic symbol table (`notes/design/data-model/crate-graph.md` §3) and expands re-exports explicitly:

```rust
// Rust: src/lib.rs
pub mod codec;
pub use codec::hex::{decode, encode, HexError};
```

```zig
// Zig: src/root.zig
pub const codec = @import("codec.zig");
pub const decode = codec.hex.decode;
pub const encode = codec.hex.encode;
pub const HexError = codec.hex.HexError;
```

---

## 4. Macro Expansion Architecture

### 4.1 Rust Macro Categories

Rust macros belong to three distinct categories:

1. **Declarative Macros (`macro_rules!`)**: Pattern matching and AST token replacement.
2. **Derive Macros (`#[derive(...)]`)**: AST synthesis attached to struct and enum definitions.
3. **Procedural & Attribute Macros (`#[proc_macro]`, `#[proc_macro_attribute]`)**: Token stream transformation functions executed by compiler plugins.

### 4.2 Pipeline Positioning: Expansion Before IR Lowering

Macro expansion must occur **before** lowering into the Lossless Semantic IR (`src/model/items.zig`, `src/model/bodies.zig`).

```text
+-----------------------+
|   Rust Source Files   |
+-----------------------+
           |
           v
+-----------------------+      +---------------------------+
| Rust Semantic Sidecar | <--> | Macro Expansion Engine    |
| (rustc_driver / HIR)  |      | (Tokens -> Expanded Items)|
+-----------------------+      +---------------------------+
           |
           v (Expanded AST / Resolved HIR / Exact Types)
+-----------------------+
|  JSON Semantic Model  |
+-----------------------+
           |
           v
+-----------------------+
| Lossless Semantic IR  | (src/model/)
+-----------------------+
           |
           v
+-----------------------+
| Zig Emitter           | (src/model/emit.zig)
+-----------------------+
```

#### Why AST-Only Parsers Fail on Macros
Tree-sitter parses Rust syntax without macro expansion. In raw syntax trees, macro invocations appear as opaque `token_tree` nodes (`vec![1, 2, 3]`, `custom_dsl!(...)`). AST-only parsers cannot determine:
- Whether an invocation produces expressions, items, statements, or type signatures.
- Type definitions and trait implementations generated inside macros.
- Control flow transfers and match arms embedded in macro bodies.

#### Limitations of `cargo expand` / `rustc -Zunpretty=expanded`
As identified in `notes/research/parsing-tooling.md` §2.6:
- **Hygiene Failure**: Textual expansion leaks local identifiers and introduces identifier collisions.
- **Comment Loss**: Pretty-printed output strips original comments and documentation attributes.
- **Span Corruption**: Source line and column numbers reference synthetic expanded buffers rather than original user files.

#### Architectural Solution
The transpiler uses a Rust semantic sidecar (`rustc_interface` or rust-analyzer `hir`). The sidecar expands macros in memory, preserves span mapping back to source files, resolves types, and emits the canonical JSON IR.

### 4.3 Provenance and Comment Retention

To preserve developer comments across macro expansion:

1. **Tree-sitter Syntax Scan**: Parse unexpanded source file with Tree-sitter to extract all comments and their byte spans (`Span { start: Pos, end: Pos }`).
2. **Semantic IR Alignment**: Match doc-comments (`///`, `//!`) to expanded items by target entity identifier (`DefId`).
3. **Inline Comment Association**: Associate inline comments (`//`) with the nearest following statement or field based on source line proximity.
4. **Emission**: Emitter prints preserved comments directly above generated Zig declarations and statements.

---

## 5. Standard Derive Macro Synthesis (Compiler vs Native Zig)

Compiler expansion of standard derives generates hundreds of lines of internal boilerplate (`core::fmt::Formatter`, `core::cmp::PartialEq`). The transpiler intercepts standard derive attributes on structs and enums and synthesizes clean, idiomatic Zig 0.16 implementations.

### 5.1 `Clone` and `Copy` Synthesis

- **Copy Types**: Primitive and value structs require no methods. Zig assigns value types by bitwise copy.
- **Resource/Pointer Types**: Synthesize explicit `.clone()` accepting an allocator:

```zig
pub const Buffer = struct {
    items: []u8,
    allocator: std.mem.Allocator,

    pub fn clone(self: Buffer, allocator: std.mem.Allocator) !Buffer {
        const items_copy = try allocator.dupe(u8, self.items);
        return .{
            .items = items_copy,
            .allocator = allocator,
        };
    }
};
```

### 5.2 `Debug` and `Display` Synthesis

Synthesize standard Zig `format` functions conforming to `std.fmt`:

```zig
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn format(
        self: Point,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Point{{ .x = {d}, .y = {d} }}", .{ self.x, self.y });
    }
};
```

#### Tagged Union `Debug` Synthesis
```zig
pub const Message = union(enum) {
    quit: void,
    move_by: struct { dx: i32, dy: i32 },
    write_text: []const u8,

    pub fn format(
        self: Message,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .quit => try writer.writeAll("Message.quit"),
            .move_by => |val| try writer.print("Message.move_by{{ .dx = {d}, .dy = {d} }}", .{ val.dx, val.dy }),
            .write_text => |val| try writer.print("Message.write_text(\"{s}\")", .{val}),
        }
    }
};
```

### 5.3 `PartialEq` and `Eq` Synthesis

Synthesize `eql` functions. For scalar structs, field comparisons or `std.meta.eql` are emitted:

```zig
pub const Rectangle = struct {
    width: u32,
    height: u32,

    pub fn eql(self: Rectangle, other: Rectangle) bool {
        return self.width == other.width and self.height == other.height;
    }
};
```

### 5.4 `Default` Synthesis

Synthesize compile-time constant defaults or initialization constructors:

```zig
pub const Config = struct {
    timeout_ms: u32 = 5000,
    retries: u8 = 3,
    debug_mode: bool = false,

    pub const default: Config = .{};
};
```

### 5.5 `Hash` Synthesis

Synthesize `hash` methods compatible with `std.hash.autoHash`:

```zig
pub const SessionKey = struct {
    user_id: u64,
    token: u32,

    pub fn hash(self: SessionKey, hasher: anytype) void {
        std.hash.autoHash(hasher, self.user_id);
        std.hash.autoHash(hasher, self.token);
    }
};
```

---

## 6. Strategic Architecture Summary & Key Decisions

### Executive Summary
1. Each Rust crate transpiles to an independent `r2z-<crate>/` package with `build.zig.zon` and `build.zig`.
2. `Cargo.toml` features compile into a typed Zig `config` options module via `b.addOptions()`.
3. Inter-crate workspace dependencies resolve through topological sort (Kahn's algorithm) before compilation.
4. Rust module hierarchies normalize into standard Zig file paths (`src/root.zig`, `src/<module>.zig`).
5. Re-exports (`pub use`) expand into explicit `pub const` symbol aliases in the importing container.
6. Macro expansion executes inside the semantic sidecar before Lossless Semantic IR lowering.
7. Original source comments align to expanded items via hybrid Tree-sitter byte-span mapping.
8. Standard derives (`Clone`, `Debug`, `Eq`, `Default`, `Hash`) synthesize idiomatic Zig methods instead of compiler macro output.

### Key Architectural Decisions and Tradeoffs

1. **Pre-IR Macro Expansion vs Syntax-Level Macro Translation**:
   - *Decision*: Fully expand all declarative, derive, and procedural macros in the semantic sidecar prior to IR lowering.
   - *Tradeoff*: Increases dependency on the Rust compiler sidecar, but ensures 100% semantic correctness for complex macro-heavy crates (`serde`, `tokio`, `clap`).

2. **Native Derive Synthesis vs Expanded Rust Boilerplate**:
   - *Decision*: Intercept standard derives (`#[derive(Debug, PartialEq, ...)]`) and synthesize native Zig 0.16 idioms (`format`, `eql`, `default`).
   - *Tradeoff*: Requires custom emitter logic per standard trait, but eliminates thousands of lines of unreadable, non-idiomatic compiler boilerplate.

3. **Flat Module Normalization vs Deep Directory Nesting**:
   - *Decision*: Normalize `foo/mod.rs` into `foo.zig` while preserving nested submodule directories `foo/bar.zig`. Inlined Rust modules (`mod foo { ... }`) remain in-place structs.
   - *Tradeoff*: Deviates from legacy Rust 2015 filesystem layout, but aligns strictly with idiomatic Zig 0.16 package and `@import` conventions.
