# System Architecture — translate-rust (`r2z`)

Master architectural specification for **translate-rust** — translating Rust crates
into correct, idiomatic, high-performance Zig 0.16 packages.

Detailed sub-system specifications live in `notes/design/architecture/`:
- [`pkg-dep-macros.md`](architecture/pkg-dep-macros.md): Package emission, Cargo dependency graph, and macro expansion pipeline.
- [`runtime-traits.md`](architecture/runtime-traits.md): `r2z-core` runtime library, static duck typing, dynamic `dyn Trait` vtables, and `@fieldParentPtr` supertrait upcasting.
- [`structure-memory.md`](architecture/structure-memory.md): 1:1 structural mapping, visibility, re-exports, allocator injection, and LIFO `defer`/`errdefer` RAII.
- [`features-actionable.md`](architecture/features-actionable.md): Enums/unions, dual-track error handling, match guards, raw pointers, and the crate-by-crate actionable roadmap (`mini`, `fnv`, `hex`, `fletcher`).

---

## 1. Top-Level Package Generation & Dependency Graph

### 1.1 Target Shape: The `r2z-<crate>/` Package Directory

A translated Rust crate is emitted as a standalone, reproducible Zig package directory:

```
r2z-<crate>/
├── build.zig          # Declares package module(s), library/binary artifacts, test steps
├── build.zig.zon      # Package manifest (fingerprint, version, r2z dependencies)
└── src/
    ├── root.zig       # Crate root (mirrors Rust lib.rs)
    ├── <module>.zig   # Top-level file modules (mod <module>;)
    └── <module>/      # Nested submodules
        └── <submodule>.zig
```

### 1.2 Inter-Crate Dependency Wiring

- **Package Naming**: A Rust crate `foo` maps to Zig package `r2z-foo`.
- **Manifest Dependencies (`build.zig.zon`)**:
  ```zig
  .{
      .name = .@"r2z-foo",
      .version = "0.1.0",
      .fingerprint = 0x1234567890abcdef,
      .minimum_zig_version = "0.16.0",
      .dependencies = .{
          .@"r2z-core" = .{ .path = "../r2z-core" },
          .@"r2z-bar" = .{ .path = "../r2z-bar" },
      },
      .paths = .{ "build.zig", "build.zig.zon", "src" },
  }
  ```
- **Build Graph (`build.zig`)**:
  ```zig
  const r2z_core = b.dependency("r2z-core", .{ .target = target, .optimize = optimize });
  const r2z_bar = b.dependency("r2z-bar", .{ .target = target, .optimize = optimize });

  const mod = b.addModule("r2z-foo", .{
      .root_source_file = b.path("src/root.zig"),
      .target = target,
      .optimize = optimize,
      .imports = &.{
          .{ .name = "r2z", .module = r2z_core.module("r2z") },
          .{ .name = "r2z-bar", .module = r2z_bar.module("r2z-bar") },
      },
  });
  ```
- **Code Reference**: Rust `use bar::func;` translates to `@import("r2z-bar").func;`.

---

## 2. Common Rust Core/Std Runtime — `r2z-core` (`libr2z`)

Following historical precedent (`c2rust-bitfields`, `libcc2rs`, `modernc.org/libc`), `r2z-core` provides zero-overhead primitives and compatibility shims without introducing heavy dependencies.

### 2.1 Runtime Components

1. **Arithmetic & Bit Primitives**:
   - `wrapping_add(a, b)` -> `a +% b`
   - `saturating_add(a, b)` -> `a +| b`
   - `rotate_left(val, shift)` -> `std.math.rotl(T, val, shift)`
   - `leading_zeros(val)` -> `@clz(val)`

2. **Slice Utilities**:
   - `chunks(slice, size)` -> Chunk iterator yielding sub-slices
   - `windows(slice, size)` -> Overlapping window iterator
   - `copy_from_slice(dest, src)` -> `@memcpy(dest, src)` with length assertion

3. **Trait Runtimes**:
   - `Hasher`: Standard hashing interface (`write([]const u8)`, `finish() u64`).
   - `FnvHasher`, `SipHasher`: Standard hash state implementations.

4. **Panic & Assertion Discipline**:
   - Rust `panic!(...)` -> Zig `@panic(...)`
   - Rust `assert!(c)` -> Zig `std.debug.assert(c)`
   - Rust `debug_assert!(c)` -> Guarded evaluation `if (builtin.mode == .Debug) std.debug.assert(c);` to prevent release-mode side-effect regressions (Bun port lesson).

---

## 3. Macro Expansion Strategy

### 3.1 Pre-IR Expansion in Semantic Sidecar

Macro expansion occurs in the Rust semantic sidecar before Lossless Semantic IR lowering:

```
Rust Source -> [rustc / cargo expand] -> Expanded AST + SCIP Types -> [Lossless IR] -> [Zig Emitter] -> r2z-<crate>/
```

- **Declarative (`macro_rules!`)**: Fully expanded into concrete syntax trees by the compiler.
- **Procedural & Attribute Macros**: Executed during compilation; output items lowered into the IR.
- **Span & Comment Preservation**: A hybrid Tree-sitter byte-span mapper preserves doc comments and original function boundaries across expansion.

### 3.2 Native Derive Synthesis

Standard derives are intercepted to emit idiomatic Zig 0.16 methods rather than compiler macro boilerplate:
- `#[derive(Clone)]` -> `pub fn clone(self: Self, allocator: std.mem.Allocator) !Self`
- `#[derive(Copy)]` -> Value copy (no-op in Zig; documented)
- `#[derive(Debug)]` -> `pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void`
- `#[derive(PartialEq, Eq)]` -> `pub fn eql(self: Self, other: Self) bool`
- `#[derive(Default)]` -> `pub fn default() Self` or `pub const default = Self{ ... };`
- `#[derive(Hash)]` -> `pub fn hash(self: Self, hasher: anytype) void`

---

## 4. Faithful Structural Mapping

### 4.1 1:1 Physical & Logical Hierarchy

| Rust Construct | Zig 0.16 Target |
|---|---|
| Crate root `src/lib.rs` | `r2z-<crate>/src/root.zig` |
| File module `mod foo;` | `r2z-<crate>/src/foo.zig` imported via `pub const foo = @import("foo.zig");` |
| Directory module `foo/mod.rs` | Normalized to `r2z-<crate>/src/foo.zig` with child submodules in `src/foo/` |
| Inline module `mod foo { ... }` | `pub const foo = struct { ... };` inside the parent container |
| Public item `pub fn foo()` | `pub fn foo()` |
| Package-private `pub(crate) fn foo()` | Internal struct/container visibility |
| Private item `fn foo()` | `fn foo()` (file-private in Zig) |
| Re-export `pub use foo::Bar;` | `pub const Bar = foo.Bar;` in the exporting container |

### 4.2 Methods & Receivers

Inherent `impl Struct` blocks are placed directly inside the struct container in Zig:
- `&self` -> `self: *const Self`
- `&mut self` -> `self: *Self`
- `self` (by-value) -> `self: Self`
- Static methods (e.g. `Point::new(...)`) -> `pub fn new(...) Self`

---

## 5. Trait Translation Architecture

### 5.1 Static Dispatch: Comptime Duck Typing

Rust generic functions with trait bounds translate to comptime-parameterized functions with trait verification:

```rust
pub fn compute<T: Summary>(item: &T) -> String { item.summarize() }
```
```zig
pub fn compute(comptime T: type, item: *const T) []const u8 {
    comptime r2z.traits.verify(T, r2z.traits.Summary);
    return item.summarize();
}
```

### 5.2 Dynamic Dispatch (`dyn Trait`) & Supertraits

Dynamic trait objects use explicit `{ ptr: *anyopaque, vtable: *const VTable }` fat pointers.

#### Nested VTables & Supertrait Upcasting (`@fieldParentPtr`):

```zig
// Supertrait: Read
pub const ReadVTable = struct {
    read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
};

pub const Read = struct {
    ptr: *anyopaque,
    vtable: *const ReadVTable,

    pub fn read(self: Read, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }
};

// Subtrait: BufRead (inherits from Read)
pub const BufReadVTable = struct {
    super: ReadVTable, // Embedded supertrait VTable
    fillBuf: *const fn (ctx: *anyopaque) anyerror![]const u8,
    consume: *const fn (ctx: *anyopaque, amt: usize) void,
};

pub const BufRead = struct {
    ptr: *anyopaque,
    vtable: *const BufReadVTable,

    // Zero-cost upcasting to dyn Read:
    pub fn asRead(self: BufRead) Read {
        return .{
            .ptr = self.ptr,
            .vtable = &self.vtable.super,
        };
    }
};
```

---

## 6. Allocation & Memory Architecture

### 6.1 `no_alloc` Default vs Allocator Injection

1. **`no_alloc` Default**: Pure compute functions (`fnv1a_hash`, `calc_fletcher16`, pure math, parsers over slices) take **zero allocator parameters** — generating clean, zero-overhead Zig code.
2. **Explicit Allocator Parameter (`std.mem.Allocator`)**: Functions requiring dynamic memory allocate via an explicit `allocator: std.mem.Allocator` parameter (Tiger Style).
3. **Struct-Stored Allocator**: State objects managing dynamic buffers (`FnvHasher`, `Vec`, `Buffer`) store `allocator: std.mem.Allocator` passed to `init(allocator)`.

### 6.2 RAII & Deterministic Drop Translation

- **LIFO Scope Deinitialization**: Rust scope exits emit `defer` in reverse declaration order.
- **Error Cleanup**: Fallible call paths emit `errdefer` to ensure leak-free unwinding on `return error.X`.
- **Field Destruction**: Struct `deinit(self: *Self)` methods deinitialize fields sequentially to match Rust's struct drop semantics.

---

## 7. Translation of Other Core Rust Features

### 7.1 Enums & Tagged Unions
- **C-like Enums**: `enum(u8)` / `enum(u32)` with explicit discriminant integer values.
- **Data-Carrying Enums**: `union(enum)` tagged unions with payload structs.
- **`#[non_exhaustive]`**: Synthesized `else => return error.NonExhaustiveVariant` arm.

### 7.2 Dual-Track Error Handling
- **Finite Error Enums**: `Result<T, ErrorCode>` -> Zig native error union `ErrorCode!T`, with `?` -> `try`.
- **Payload-Bearing Errors**: `Result<T, ComplexError>` -> Generic tagged union `union(enum) { ok: T, err: ComplexError }`.

### 7.3 Pattern Matching & Match Guards
- **Direct Matches**: Exhaustive Zig `switch` with payload captures `|val|`.
- **Range Matches**: `1..=5` -> `1...5`.
- **Match Guards (`if cond`)**: Emitted as a decision tree (`if / else if`) within the switch or block.

---

## 8. Actionable Implementation Checklist for Test Crates

### 8.1 Crate-by-Crate Technical Gap Breakdown

| Crate | Current State | Remaining Technical Gaps to 100% Package Translation |
|---|---|---|
| **`mini`** | Rust source in `test/crates/mini/` | 1. Multi-file emission (`util.zig`).<br>2. Struct field emission (`struct Point { x: i32, y: i32 }`).<br>3. Enum payload variant emission (`union(enum) { circle: f64, rect: struct { ... } }`).<br>4. Match lowering with payload captures in `area()`.<br>5. `pub use util::helper` re-export emission.<br>6. Generate `r2z-mini/` package. |
| **`fnv`** | Core body translated; 203 vectors pass | 1. Package generator: emit `r2z-fnv/` with `build.zig` and `build.zig.zon`.<br>2. `FnvHasher` struct translation with `allocator` / state.<br>3. `Hasher` trait static methods translation (`write`, `finish`).<br>4. Automatic `r2z-fnv` package build and test verification. |
| **`hex`** | Reduced slice golden; core source in `test/crates/hex/` | 1. Multi-file emission (`error.rs` -> `error.zig`).<br>2. `FromHexError` enum translation.<br>3. Dual-track error handling: return type `FromHexError![]u8`.<br>4. Helper function calls (`hexChar` / `val`).<br>5. Generate `r2z-hex/` package. |
| **`fletcher`** | Algorithm translated; 6 vectors pass; source in `test/crates/fletcher/` | 1. Comptime generic type function: `pub fn Fletcher(comptime T: type) type`.<br>2. `FletcherAccumulator` trait translation.<br>3. Struct methods (`new`, `with_initial_values`, `update`, `value`, `reduce`, `combine`).<br>4. Chunking loop (`chunks(21)`).<br>5. Generate `r2z-fletcher/` package. |

---

### 8.2 Prioritized Implementation Roadmap

```
  ┌────────────────────────────────────────────────────────────────────────┐
  │ M1: Package Generator & Multi-File Emission (`mini` 100% End-to-End)   │
  │ - Emitter produces `r2z-<crate>/` dir with `build.zig` + `.zon`        │
  │ - Multi-file emission (`root.zig` + `util.zig`) + struct/enum payloads │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ M2: Package Generator on Existing Corpora (`fnv` Package 100%)         │
  │ - Automated `r2z-fnv/` package generation                              │
  │ - `FnvHasher` struct + `Hasher` trait methods                          │
  │ - 203 vectors pass from generated package                              │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ M3: Error Handling & Slices (`hex` Package 100%)                       │
  │ - `error.zig` submodule + `FromHexError` error union                   │
  │ - Slice encode/decode loops with helper calls                          │
  │ - Automated `r2z-hex/` package generation & test pass                  │
  └───────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │ M4: Comptime Generic Structs & Traits (`fletcher` Package 100%)        │
  │ - Generic struct `Fletcher(comptime T: type)`                          │
  │ - Inherent struct methods + chunking loop                              │
  │ - Automated `r2z-fletcher/` package generation & 6 vectors pass        │
  └────────────────────────────────────────────────────────────────────────┘
```
