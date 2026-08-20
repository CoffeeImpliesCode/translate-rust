# Restructuring Plan: Decoupled Frontend / Backend Architecture

Status: **Implementation Plan**  
Target: Progressive, green-at-every-step refactoring of `translate-rust` codebase to match `notes/design/architecture.md`.

---

## Phase Overview & Dependency Graph

```
┌────────────────────────────────────────────────────────┐
│ Phase 1: IR Foundation & Serialization                 │
│ • Establish src/ir/ namespace                          │
│ • Unify spine, graph, types, exprs, bodies, traits     │
│ • Add full RustIr JSON serializer / deserializer       │
│ • Provide built-in core/alloc/std model registry       │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Phase 2: Frontend Separation & Pure Rust Pipeline      │
│ • Establish src/frontend/ namespace                    │
│ • Migrate ingest, cst, submodules, expand              │
│ • Migrate names, infer, resolve_methods, monomorphize  │
│ • Ensure Frontend produces ONLY pure, target-less      │
│   RustIr data structures                               │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Phase 3: Backend Target Repr & Strategy Pattern        │
│ • Establish src/backend/ namespace                     │
│ • Define LoweringStrategy interface & VTable           │
│ • Define Target Repr (ZigAST DOM) + Serialization      │
│ • Implement ZigDefaultStrategy & ZigLowering           │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Phase 4: Emitter & Package Decoupling                  │
│ • Migrate emit.zig to consume ZigAST (pure formatter)  │
│ • Migrate package.zig & driver pipeline integration    │
│ • Wire pipeline: Rust Source -> RustIr -> ZigAST ->    │
│   Package on Disk                                      │
└───────────────────────────┬────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────┐
│ Phase 5: Verification, Golden Tests & Cleanup          │
│ • Add frontend RustIr snapshot golden tests            │
│ • Add backend ZigAST snapshot golden tests             │
│ • Update CLI diagnostics (--dump-rustir, --dump-zigast)│
│ • Full gate & 14 test-crates + e2e validation          │
└────────────────────────────────────────────────────────┘
```

---

## Detailed Phase Breakdown

### Phase 1: IR Foundation & Serialization
**Goal**: Make the semantic data model completely independent of both extraction logic and emission logic, and fully serializable.

1. **Create `src/ir/`**:
   - Move/refactor:
     - `src/model/spine.zig` → `src/ir/spine.zig`
     - `src/model/graph.zig` → `src/ir/graph.zig`
     - `src/model/types.zig` → `src/ir/types.zig`
     - `src/model/exprs.zig` → `src/ir/exprs.zig`
     - `src/model/bodies.zig` → `src/ir/bodies.zig`
     - `src/model/ownership.zig` → `src/ir/ownership.zig`
   - Create `src/ir/serialize.zig`:
     - Full de/serialization for `CrateGraph`, `Bodies`, `Types`, `Exprs`, `Statements`, `Patterns`.
     - Roundtrip test verifying byte/structural parity on all 14 test crates.
   - Create `src/ir/std_model.zig`:
     - In-memory pre-built `RustIr` symbol table for `core`, `alloc`, `std` primitives and standard traits (`Option`, `Result`, `Hasher`, `Iterator`, `Default`, `Clone`).
2. **Verification Gate**: `zig build test` passes on IR serialization roundtrip.

---

### Phase 2: Frontend Separation & Pure Rust Pipeline
**Goal**: Organize all Rust understanding (parsing, resolution, inference, monomorphization) under `src/frontend/` with zero backend dependencies.

1. **Create `src/frontend/`**:
   - `src/frontend/ingest.zig`: `Cargo.toml` reader, target file discovery.
   - `src/frontend/cst.zig`: Tree-sitter CST traversal and type extraction.
   - `src/frontend/submodules.zig`: Recursive filesystem traversal for `mod foo;`.
   - `src/frontend/expand.zig`: Macro expander (`assert!`, `panic!`, `vec!`).
   - `src/frontend/names.zig`: Lexical scoping, `use` resolution, re-exports.
   - `src/frontend/infer.zig`: Type inference & unification solver.
   - `src/frontend/resolve_methods.zig`: Inherent and trait method lookup against `std_model`.
   - `src/frontend/monomorphize.zig`: Generic instantiation detection and naming.
   - `src/frontend/pipeline.zig`: Single function `analyzeCrate(allocator, src_dir) !ir.RustIr`.
2. **Purity Check**: Ensure `src/frontend/` imports **only** `src/ir/` and `vendor/tree-sitter-rust`. No references to `std.AutoHashMap`, Zig builtins, or emission formatting.
3. **Verification Gate**: `zig build test` passes; `--dump-types`, `--dump-names`, `--dump-infer` CLI flags read from frontend pipeline.

---

### Phase 3: Backend Target Repr & Strategy Pattern
**Goal**: Build explicit target representation and dynamic lowering strategies.

1. **Create `src/backend/` and `src/backend/zig/ast.zig`**:
   - Structured Zig AST DOM:
     - `File`, `Decl` (`struct_decl`, `enum_decl`, `fn_decl`, `const_decl`, `var_decl`).
     - `Type` (primitives, pointers, slices, optionals, error unions, generic instantiations).
     - `Expr` / `Statement` (literals, calls, blocks, matches, field accesses, binary/unary ops, builtins).
     - `Manifest` (`build.zig.zon` and `build.zig` models).
   - Create `src/backend/zig/serialize.zig` for JSON serialization of `ZigAST`.
2. **Implement Strategy Interface (`src/backend/strategy.zig`)**:
   - `LoweringStrategy` struct + `VTable` abstraction.
3. **Implement `src/backend/zig/strategies/default.zig`**:
   - Impl method hoisting into struct bodies.
   - Rust `HashMap` / `HashSet` → `std.AutoHashMap`.
   - Rust `BuildHasherDefault` → `std.hash.BuildHasherDefault`.
   - Comptime duck typing for generic bounds.
4. **Implement `src/backend/zig/lower.zig`**:
   - Pure function: `lowerRustIr(allocator, rust_ir: *const ir.RustIr, strategy: *const LoweringStrategy) !zig.ast.Package`.
5. **Verification Gate**: Snapshot tests verifying `RustIr` → `ZigAST` generation.

---

### Phase 4: Emitter & Package Decoupling
**Goal**: Separate AST-to-text formatting from translation logic.

1. **Refactor `src/backend/zig/emit.zig`**:
   - Consumes only `zig.ast.File` / `zig.ast.Package`.
   - Pure code formatting logic (Tiger Style indentation, comment emission, identifier quoting).
2. **Refactor `src/backend/zig/package.zig`**:
   - Writes `zig.ast.Package` to disk.
   - Generates directory hierarchy (`src/root.zig`, submodule files, `build.zig`, `build.zig.zon`).
3. **Create `src/driver/pipeline.zig`**:
   - Orchestrates `Frontend.analyzeCrate(...)` → `RustIr` → `Backend.lower(...)` → `ZigAST` → `Backend.emit(...)` → Files on disk.
   - Handles self-healing fingerprinting via build error capture.
4. **Verification Gate**: `zig build test-e2e` and `zig build test-crates` pass across all 14 test crates.

---

### Phase 5: Verification, Golden Tests & Cleanup
**Goal**: Lock in architectural boundaries with automated regression tests.

1. **Add Golden Tests**:
   - `test/golden/rust_ir/`: Golden `.rustir.json` files for standard fixtures (`mini`, `fnv`, `hex`).
   - `test/golden/zig_ast/`: Golden `.zigast.json` files for standard fixtures.
2. **Update CLI Flags**:
   - `--dump rustir <crate-dir>`: Emits pure serialized `RustIr`.
   - `--dump zigast <crate-dir>`: Emits pure serialized `ZigAST`.
   - `--strategy <name>`: Selects backend lowering strategy (`default`, `embedded`).
3. **Run Full Project Quality Gates**:
   - `gate` (fmt, build, test, ast-check, ziglint, zlint).
   - `zig build test-crates` (full parsing and compilation of all 14 generated `r2z-*` crates).
   - `jj commit` with clean modular history.
