# translate-rust Architecture & Decoupled Frontend/Backend Design

Status: **Design Specification**  
Date: 2026-08-18  
Scope: Defines the clean separation of frontend (Rust understanding) and backend (Target lowering, representation, and emission), including serialized boundaries, standard library models, pluggable lowering strategies, and intermediate representations.

---

## 1. System Topology Overview

```
                          ┌──────────────────────────┐
                          │   Rust Crate Source      │
                          │ (Cargo.toml, src/**/*.rs)│
                          └─────────────┬────────────┘
                                        │
                                        ▼
                          ┌──────────────────────────┐
                          │   1. Ingestion & CST     │
                          │  (Tree-sitter, mod tree) │
                          └─────────────┬────────────┘
                                        │
                                        ▼
                          ┌──────────────────────────┐
┌──────────────────┐      │   2. CST Code Graph      │
│ Pre-built std/   ├─────►│  (Lossless untyped IR,   │
│ core / alloc IR  │      │   expanded macro bodies) │
└──────────────────┘      └─────────────┬────────────┘
                                        │
┌──────────────────┐                    ▼
│ External Dep     ├─────►┌──────────────────────────┐
│ Serialized IRs   │      │  3. Semantic Analysis    │
└──────────────────┘      │  (Names, Inference,      │
                          │   Traits, Monomorphize)  │
                          └─────────────┬────────────┘
                                        │
                                        ▼
               ====================================================
               BOUNDARY: Serialized RustIr (JSON / Binary)
               - Completely target-agnostic
               - Full semantic model of the Rust crate
               ====================================================
                                        │
                                        ▼
                          ┌──────────────────────────┐
                          │ 4. Lowering Strategy     │
                          │    Selection & Dispatch  │
                          └───────┬───────────┬──────┘
                                  │           │
            ┌─────────────────────┘           └────────────────────┐
            ▼                                                      ▼
┌────────────────────────────┐                         ┌────────────────────────────┐
│ Zig Lowering Strategy      │                         │ C Lowering Strategy        │
│ (Comptime traits, hoisting,│                         │ (Name mangling, explicit   │
│  std.AutoHashMap mapping)  │                         │  vtables, header split)    │
└───────────┬────────────────┘                         └───────────┬────────────────┘
            │                                                      │
            ▼                                                      ▼
┌────────────────────────────┐                         ┌────────────────────────────┐
│ 5. Target Repr: Zig AST    │                         │ 5. Target Repr: C AST      │
│    (Decls, Exprs, Files,   │                         │    (Decls, Header/Source,  │
│     Manifest: build.zig)   │                         │     Makefile/CMake)        │
└───────────┬────────────────┘                         └───────────┬────────────────┘
            │ (Serializable)                                       │ (Serializable)
            ▼                                                      ▼
┌────────────────────────────┐                         ┌────────────────────────────┐
│ 6. Zig Package Emitter     │                         │ 6. C Library Emitter       │
│    (Format, Fingerprint,   │                         │    (Format, Header Guards, │
│     Disk write)            │                         │     Disk write)            │
└───────────┬────────────────┘                         └───────────┬────────────────┘
            │                                                      │
            ▼                                                      ▼
┌────────────────────────────┐                         ┌────────────────────────────┐
│ Emitted Zig Package        │                         │ Emitted C Library          │
│ (r2z-crate/ + build.zig)   │                         │ (include/ + src/ + CMake)  │
└────────────────────────────┘                         └────────────────────────────┘
```

---

## 2. Frontend Subsystem: Pure Rust Semantic Modeling

The frontend is responsible for ingesting, parsing, expanding, and analyzing Rust code until a complete semantic understanding of the crate is achieved. The frontend contains **zero knowledge of Zig, C, or any emission target**.

### 2.1 Ingestion & CST Model
- **File Discovery**: Reads `Cargo.toml` (package name, version, edition, targets, dependencies) and locates root source files (`src/lib.rs`, `src/main.rs`).
- **Submodule Traversal**: Losslessly parses `mod foo;` declarations into filesystem paths (`foo.rs` or `foo/mod.rs`), recursing arbitrarily deep.
- **Tree-sitter CST Extraction**: Direct tree-sitter parser producing a concrete syntax tree without requiring a Rust toolchain or `rustc`.
- **Macro Expansion**: Built-in standard macro expander (`expand.zig`) expanding structural macros (`assert!`, `assert_eq!`, `panic!`, `vec!`, `format!`, `include_str!`) directly into code graph structures.

### 2.2 Semantic Analysis (`Sema`)
- **Name Resolution (`names.zig`)**:
  - Scopes per module, `use` declarations (plain, aliases, globs, nested groups `a::{b, c::{d, e}}`).
  - Path prefix resolution (`crate::`, `super::`, `self::`).
  - Re-exports (`pub use`) mapped to canonical item IDs.
- **Type Inference & Solver (`infer.zig`)**:
  - Generation of type constraints across expression and pattern boundaries.
  - Union-find unification solver.
  - Application of Rust type defaults (`i32`, `f64`, integer literals).
- **Trait & Method Dispatch (`resolve_methods.zig`)**:
  - Inherent `impl` method lookup on receiver types.
  - Trait `impl` resolution against trait bounds.
  - Method calls (`x.clone()`, `x.len()`, `x.hash(&mut state)`) resolved to concrete definition IDs or synthetic trait method definitions.
- **Monomorphization (`monomorphize.zig`)**:
  - Detects all concrete type instantiations for generic functions, structs, and enums.
  - Produces an explicit `Instantiation` registry.

### 2.3 Frontend Boundary Interfaces

#### A. Standard Library Model (`core`, `alloc`, `std`)
Instead of parsing the Rust standard library from source, the frontend loads a pre-constructed, serialized `RustIr` image defining:
- Primitive type definitions and fundamental wrappers (`Option<T>`, `Result<T, E>`, `Box<T>`, `Vec<T>`, `String`, `&[T]`, `&str`).
- Standard language traits:
  - Memory/Identity: `Clone`, `Copy`, `Default`, `Drop`.
  - Hashing: `Hash`, `Hasher`, `BuildHasher`, `BuildHasherDefault`.
  - Iteration: `Iterator`, `IntoIterator`, `DoubleEndedIterator`, `ExactSizeIterator`.
  - Formatting & Conversion: `Display`, `Debug`, `AsRef`, `AsMut`, `From`, `Into`.
  - Operators: `Add`, `Sub`, `Mul`, `Div`, `Index`, `IndexMut`, `Deref`, `DerefMut`.

#### B. External Dependency Interfaces (`DepCrateIR`)
- Dependencies declared in `Cargo.toml` are satisfied by consuming pre-compiled `RustIr` bundles (`.rustir.json` / binary).
- `Sema` resolves cross-crate item references, trait implementations, and types directly against the dependency's symbol table without source reprocessing.

#### C. Serializable `RustIr` Specification
The final artifact of the frontend is `RustIr`, serialized into a deterministic flat JSON or binary structure:
```json
{
  "schema_version": "1.0.0",
  "crate_name": "fnv",
  "edition": "2021",
  "symbol_table": {
    "entities": [
      {
        "id": 1,
        "kind": "struct_",
        "name": "FnvHasher",
        "parent": 0,
        "visibility": "public",
        "span": { "start_line": 80, "start_col": 1, "end_line": 82, "end_col": 2 }
      }
    ]
  },
  "modules": [ ... ],
  "types": [ ... ],
  "exprs": [ ... ],
  "stmts": [ ... ],
  "pats": [ ... ],
  "bodies": [ ... ],
  "trait_impls": [ ... ],
  "instantiations": [ ... ]
}
```

---

## 3. Backend Subsystem: Lowering, Target Repr & Emitter

The backend is strictly decoupled from Rust AST parsing. It consumes `RustIr` and transforms it into the target language package.

```
       ┌────────────────────────┐
       │   Semantic RustIr      │
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │  Lowering Strategy     │  <-- Strategy Pattern Interface
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │  Target Repr (AST)     │  <-- Serializable Target-Language DOM
       └───────────┬────────────┘
                   │
                   ▼
       ┌────────────────────────┐
       │  Package Emitter       │  <-- Disk, Formatting, Fingerprints
       └────────────────────────┘
```

### 3.1 Pluggable Lowering Strategies (`strategy.zig`)

Different target languages or different usage contexts for the same target require different translation strategies.

```zig
pub const LoweringStrategy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Map a semantic Rust type to a target representation type
        lowerType: *const fn (ctx: *anyopaque, ty: types.Type) LowerError!target.Type,
        
        /// Lower a struct, enum, union, or trait declaration
        lowerDecl: *const fn (ctx: *anyopaque, ent_id: spine.EntityId) LowerError!target.Decl,
        
        /// Lower a function or method body
        lowerBody: *const fn (ctx: *anyopaque, body_id: spine.EntityId) LowerError!target.Body,
        
        /// Lower an individual expression
        lowerExpr: *const fn (ctx: *anyopaque, expr_id: exprs.NodeId) LowerError!target.Expr,

        /// Lower standard library collections and trait calls
        lowerStdConstruct: *const fn (ctx: *anyopaque, construct: RustStdConstruct) LowerError!target.Expr,
    };
};
```

#### Strategy Variants:
1. **`ZigDefaultStrategy`**:
   - Inherent and trait methods hoisted into struct bodies (`pub const S = struct { pub fn method() ... }`).
   - Comptime duck typing for generic constraints (`anytype`).
   - Standard collections mapped to Zig stdlib (`std.AutoHashMap`, `std.hash.BuildHasherDefault`).
   - Error handling mapped to Zig error unions (`!T`) or tagged error enums.
2. **`ZigEmbeddedStrategy`**:
   - Zero dynamic allocations in default paths.
   - Functions requiring allocation take explicit `allocator: std.mem.Allocator` parameters.
   - Slices and fixed-size buffers favored over dynamic containers.
3. **`C99Strategy` (Future)**:
   - Namespaces flattened with deterministic prefixing (`fnv_FnvHasher_write`).
   - Trait polymorphism lowered to explicit C structs containing function pointer tables (vtables).
   - Generics monomorphized to distinct C functions and structs.

### 3.2 Serializable Target Representation (`target.zig`)

The backend builds an explicit, structured intermediate representation of the target code before writing bytes to disk.

#### `ZigAST` Target Model:
- **`File`**: Represents a physical `.zig` file with doc comments, top-level imports (`@import`), and declarations.
- **`Decl`**:
  - `.struct_decl`: name, fields, alignment, methods, visibility.
  - `.enum_decl`: name, tag type, variants (with optional payloads for tagged unions).
  - `.fn_decl`: name, parameters, return type, body, attributes (`pub`, `inline`).
  - `.const_decl` / `.var_decl`: name, type, initial value.
- **`Expr` / `Statement`**: Explicit tree representing target statements, assignments, switches, if-else expressions, for/while loops, and builtins (`@truncate`, `@as`, `@bitCast`).
- **`Manifest`**: Structured model of `build.zig` and `build.zig.zon` (dependencies, paths, fingerprints).

#### Benefits of `TargetRepr`:
- **Independent Serialization**: `ZigAST` can be serialized to `.zig_ast.json`, allowing snapshot/golden tests for lowering logic without being sensitive to whitespace or comment formatting.
- **Transformations on Target Repr**: Post-lowering passes (e.g., dead code elimination, unused import pruning, unshadowing) operate directly on `ZigAST`.

### 3.3 Target Emitter (`emit.zig`, `package.zig`)
- Consumes `ZigAST` / `CAST`.
- Formats text cleanly adhering to language idioms (e.g., Tiger Style Zig formatting).
- Writes out files to disk (`src/root.zig`, submodules, `build.zig`, `build.zig.zon`).
- Invokes target toolchain verification (e.g., calculating self-healing build package fingerprints).

---

## 4. Directory Layout Refactoring Plan

The code will be reorganized into explicit `frontend`, `ir`, `backend`, and `driver` namespaces:

```
src/
├── root.zig                        # Public API exports
├── main.zig                        # CLI entry point & diagnostics
│
├── ir/                             # Language-agnostic Semantic IR & serialization
│   ├── root.zig
│   ├── spine.zig                   # Entity kinds, EntityId, spans, visibility
│   ├── graph.zig                   # CrateGraph, SymbolTable, Modules, Uses
│   ├── types.zig                   # Type definitions (primitives, structs, generics)
│   ├── exprs.zig                   # Lossless expressions, statements, patterns
│   ├── bodies.zig                  # Function and item bodies
│   ├── traits.zig                  # Trait definitions and impl tables
│   ├── serialize.zig               # JSON / binary de/serializer for RustIr
│   └── std_model.zig               # Built-in serialized core/alloc/std models
│
├── frontend/                       # Rust Ingestion, CST & Semantic Analysis
│   ├── root.zig
│   ├── ingest.zig                  # Cargo.toml reader & source file resolver
│   ├── cst.zig                     # Tree-sitter AST -> CST graph extractor
│   ├── submodules.zig              # Filesystem recursive submodule loader
│   ├── expand.zig                  # Built-in macro expander
│   ├── names.zig                   # Name & scope resolution pass
│   ├── infer.zig                   # Type inference & unification solver
│   ├── resolve_methods.zig         # Inherent & trait method dispatch
│   └── monomorphize.zig            # Generic instantiation pass
│
├── backend/                        # Lowering Strategies, Target Repr & Emitters
│   ├── root.zig
│   ├── strategy.zig                # Strategy pattern interface & registry
│   │
│   ├── zig/                        # Zig Target Backend
│   │   ├── root.zig
│   │   ├── ast.zig                 # Target Repr: Explicit Zig AST & Manifest DOM
│   │   ├── serialize.zig           # Zig AST JSON serializer (for snapshot tests)
│   │   ├── strategies/             # Zig strategy implementations
│   │   │   ├── default.zig         # Idiomatic standard library mapping
│   │   │   └── embedded.zig        # Allocator-aware / no_std strategy
│   │   ├── lower.zig               # RustIr -> ZigAST lowering orchestrator
│   │   ├── emit.zig                # ZigAST -> source text formatter
│   │   └── package.zig             # Package writer (build.zig, zon, fingerprint)
│   │
│   └── c/                          # Future C Target Backend
│       ├── root.zig
│       ├── ast.zig                 # C AST Model (Headers, TUs, Types)
│       ├── lower.zig               # RustIr -> CAST lowering
│       └── emit.zig                # C formatter (Make/CMake, .h, .c)
│
├── driver/                         # Pipeline orchestration
│   ├── root.zig
│   └── pipeline.zig                # Orchestrates Frontend -> RustIr -> Backend
│
└── runtime/
    └── r2z-core/                   # Standalone Zig-std compat layer
```

---

## 5. Verification & Testing Discipline

1. **Frontend Isolation Tests**:
   - Rust source → `RustIr` assertions. Golden `.rustir.json` test fixtures ensure semantic extraction remains intact regardless of backend changes.
2. **Backend Lowering Snapshot Tests**:
   - Pre-canned `RustIr` → `ZigAST` structure assertions. Isolates lowering rules from frontend parser changes.
3. **End-to-End Package Verification**:
   - Source crate → Full translation → `zig build test` execution inside generated package.
4. **Gate Compliance**:
   - `gate` execution (`fmt`, `build`, `test`, `ast-check`, `ziglint`, `zlint`) across all internal modules and generated test crates.
