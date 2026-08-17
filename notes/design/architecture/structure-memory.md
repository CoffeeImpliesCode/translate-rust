# Architecture Design: Structure & Memory (1:1 Mapping, Visibility, Allocators, Drop)

- **Document**: `notes/design/architecture/structure-memory.md`
- **Status**: Complete Architectural Specification
- **Target Platform**: Zig 0.16.0 (Tiger Style, ASD-STE100 terseness, Zero-Hidden-Allocation)
- **Cross-References**:
  - `notes/research/idiom-mapping.md` (§1 Module System, §8 Ownership & Memory)
  - `notes/research/prior-work.md` (§4 Lessons from Prior Transpilers)
  - `notes/design/data-model/crate-graph.md` (§1 Crate Root + Module Graph, §2 Visibility & Scope, §4 Path Resolution)
  - `notes/design/data-model/ownership-mem.md` (§2 Ownership Representation, §4 Drop & RAII Model, §5 Allocator Strategy)
  - `notes/design/data-model/items-types.md` (§1 Item Model, §2 Struct & Union Model, §4 Function Model)

---

## 1. Executive Summary

This document specifies the architectural model for translating Rust crate structure, namespaces, memory allocation, and RAII drop semantics into safe, idiomatic Zig 0.16.
Translation preserves 1:1 physical and logical hierarchy through file modules and nested container structs.
Visibility modifiers map deterministically to Zig `pub` exports and private declarations.
Memory management adheres to a strict `no_alloc` default: pure compute functions receive zero allocator parameters.
Allocating functions use an explicit `allocator: std.mem.Allocator` parameter (Tiger Style) or struct-stored allocator for stateful objects.
Rust drop semantics translate to inverted LIFO `defer` unwinding for local scopes, FIFO member cleanup in struct `deinit()`, and automated `errdefer` recovery paths.

---

## 2. Faithful Structural Mapping

```
Rust Crate Layout                         Generated Zig Package Layout
┌───────────────────────────┐             ┌───────────────────────────┐
│ src/lib.rs (Crate Root)   │ ──────────> │ src/root.zig (Root API)   │
│   mod utils;              │             │   pub const utils =       │
│   pub mod codec;          │             │     @import("utils.zig"); │
│   pub use codec::Encoder; │             │   pub const codec =       │
├───────────────────────────┤             │     @import("codec.zig"); │
│ src/utils.rs (File Mod)   │ ──────────> │   pub const Encoder =     │
│   fn helper() {}          │             │     codec.Encoder;        │
├───────────────────────────┤             ├───────────────────────────┤
│ src/codec/                │             │ src/codec.zig (or codec/) │
│   mod.rs / encoder.rs     │ ──────────> │   pub const Encoder = ... │
│   mod inline_parser { ... }             │   pub const inline_parser=│
└───────────────────────────┘             │     struct { ... };       │
                                          └───────────────────────────┘
```

### 2.1 File & Module Hierarchy (1:1 Physical Fidelity)

Rust uses three module forms (`notes/design/data-model/crate-graph.md` §1.2, `notes/research/idiom-mapping.md` §1):
1. **Crate Root**: `src/lib.rs` maps to `src/root.zig`; `src/main.rs` maps to `src/main.zig`.
2. **File Module (`mod foo;`)**:
   - `src/foo.rs` maps to `src/foo.zig`.
   - `src/foo/mod.rs` (legacy Rust) or `src/foo.rs` with `src/foo/bar.rs` (modern Rust) maps to `src/foo/root.zig` or `src/foo.zig` alongside `src/foo/bar.zig`.
   - The parent module binds the child module via:
     ```zig
     pub const foo = @import("foo.zig");
     ```
3. **Inline Module (`mod foo { ... }`)**:
   - Maps to an inline namespace container struct inside the parent Zig file:
     ```zig
     pub const foo = struct {
         // Declarations from inline module body
     };
     ```

### 2.2 Visibility Translation Matrix

Rust enforces fine-grained path-scoped visibility. Zig supports only two item-level visibility states: `pub` (exported from file/struct) and private/unexported (local to file/struct).

| Rust Visibility | Rust Semantics | Zig Target Pattern | Semantic Fidelity & Boundary Handling |
|:---|:---|:---|:---|
| `pub` | Public to all consumers | `pub const ...` / `pub fn ...` | 100% equivalent export level. |
| `pub(crate)` | Public across crate, hidden outside | `pub` on file item, excluded from `root.zig` re-export | Module-public within package; consumers of package cannot see it unless exposed by `root.zig`. |
| `pub(super)` | Visible to immediate parent module | `pub` in child container, not re-exported by parent | Parent can read child's `pub` symbol; parent does not re-export symbol upwards. |
| `pub(in crate::path)` | Visible only to specific path | `pub` within target submodule tree | Preserved via selective file import paths. |
| Private (default) | Visible only to defining module | Non-`pub` declaration (`const`, `fn`) | File-private or container-private in Zig. |

### 2.3 Re-Export (`pub use`) Synthesis

Rust uses `pub use path::Symbol;` to flatten API hierarchies (`notes/design/data-model/crate-graph.md` §2.3).
The transpiler translates re-exports into Zig top-level `pub const` aliases:

```zig
// Rust: pub use crate::codec::encoder::Encoder;
pub const Encoder = codec.encoder.Encoder;

// Rust: pub use self::types::*; (glob import)
// Flattened explicitly by symbol table resolution:
pub const Point = types.Point;
pub const Vector = types.Vector;
```

**Circular Dependency Resolution**:
Zig evaluates top-level container declarations lazily at compile-time (`comptime`). Mutual file imports (`@import("a.zig")` inside `b.zig` and `@import("b.zig")` inside `a.zig`) are valid in Zig when types do not contain infinite recursive value nesting. Circular types require pointer indirection (`*T` or `?*T`).

### 2.4 Struct Method Namespaces & Receiver Translation

Rust methods in `impl Struct` blocks map directly inside the Zig `struct` declaration (`notes/design/data-model/items-types.md` §2, `notes/research/idiom-mapping.md` §3).

| Rust Method Receiver | Zig Parameter Signature | Semantics & Receiver Mutation |
|:---|:---|:---|
| `&self` (immutable borrow) | `self: *const Self` (or `self: Self` for small scalar types) | Read-only access via const pointer or copy. |
| `&mut self` (mutable borrow) | `self: *Self` | Mutable reference to target instance. |
| `self` (owned / consumed) | `self: Self` | Passed by value. Caller ownership transferred. |
| No receiver (`fn new(...)`) | Static associated function: `pub fn init(...) Self` | Constructor or factory function called as `Type.init(...)`. |

```zig
pub const FastHasher = struct {
    state: u64,

    /// Associated constructor (Rust: fn new(seed: u64) -> Self)
    pub fn init(seed: u64) FastHasher {
        return .{ .state = seed };
    }

    /// &mut self method (Rust: fn write_u8(&mut self, byte: u8))
    pub fn writeByte(self: *FastHasher, byte: u8) void {
        self.state = (self.state ^ @as(u64, byte)) *% 0x100000001b3;
    }

    /// &self method (Rust: fn finish(&self) -> u64)
    pub fn finish(self: *const FastHasher) u64 {
        return self.state;
    }

    /// self method (Rust: fn into_state(self) -> u64)
    pub fn intoState(self: FastHasher) u64 {
        return self.state;
    }
};
```

---

## 3. Allocation & Memory Architecture

```
Function Semantic Classification
┌─────────────────────────────────────────────────────────────┐
│ Pure Compute (AST has zero heap/OS operations)              │
│   -> Signature: fn compute(input: []const u8) u32           │
│   -> Allocator Parameters: EXACTLY ZERO (no_alloc)          │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ Dynamic / Allocating Function (Vec, Box, String, OS)        │
│   -> Explicit Parameter (Tiger Style):                      │
│      fn process(allocator: std.mem.Allocator, in: []const u8)│
│   -> Struct Lifecycle Owner (Stateful Object):              │
│      fn init(allocator: std.mem.Allocator) !Self            │
│      fn deinit(self: *Self) void                            │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Pure Compute (`no_alloc` Default)

Real-world Rust crates (such as `fnv`, `fletcher`, `hex`) contain pure algorithms that do not touch dynamic memory.
The transpiler enforces a strict **`no_alloc` default**:
1. Static analysis checks function IR for heap operations (`Box`, `Vec`, `String`, dynamic layout, allocation traits).
2. Functions with zero heap dependencies are emitted with zero allocator parameters.
3. This guarantees optimal performance, zero memory footprint, and full compatibility with freestanding/embedded Zig.

```zig
/// Pure computation: zero allocation arguments emitted
pub fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        hash ^= @as(u64, b);
        hash = hash *% 0x100000001b3;
    }
    return hash;
}
```

### 3.2 Allocator Injection Models

When functions allocate memory, four architectural strategies exist:

```
Option A: Context Object           Option B: Explicit Allocator (Tiger Style)
┌─────────────────────────┐        ┌─────────────────────────┐
│ fn exec(ctx: *Context)  │        │ fn exec(alloc: Allocator│
│   ctx.allocator         │        │   alloc.create(...)     │
│   ctx.config            │        └─────────────────────────┘
└─────────────────────────┘
Option C: Struct-Stored            Option D: Scoped Arena
┌─────────────────────────┐        ┌─────────────────────────┐
│ const S = struct {      │        │ var arena = Arena(...)  │
│   allocator: Allocator, │        │ defer arena.deinit()    │
│   fn init(alloc) S      │        │ fn exec(arena.allocator)│
│ };                      │        └─────────────────────────┘
└─────────────────────────┘
```

#### Option A: Context Parameter (`r2z_ctx: *R2zContext`)
- Carries an allocator, environment flags, and runtime settings in a single context pointer.
- *Downside*: Obscures function requirements, couples code to a transpiler runtime struct, violates Tiger Style.

#### Option B: Explicit `allocator: std.mem.Allocator` Parameter (Tiger Style Standard)
- Every function that allocates accepts `allocator: std.mem.Allocator` as its first parameter.
- *Advantage*: 100% explicit, transparent call sites, adheres strictly to Zig 0.16 idioms and Tiger Style.

#### Option C: Struct-Stored Allocator
- The struct stores `allocator: std.mem.Allocator` in an internal field.
- Passed once during `init(allocator: std.mem.Allocator)`. Methods allocate using `self.allocator`.
- `deinit(self: *Self)` frees all owned resources using `self.allocator`.
- *Advantage*: Clean method call sites (`self.append(item)`) without passing `allocator` on every operation.

#### Option D: Request / Scoped Arena Allocator
- Temporary allocations take an arena allocator (`std.heap.ArenaAllocator`).
- All allocated resources are freed simultaneously when the parent arena is destroyed.

### 3.3 Allocator Model Tradeoff Analysis

| Evaluation Metric | Option A (Context) | Option B (Explicit Param) | Option C (Struct-Stored) | Option D (Arena) |
|:---|:---|:---|:---|:---|
| **Tiger Style Alignment** | Low (Hidden state) | **Very High** (Explicit) | **High** (Explicit at init) | High (Scoped) |
| **Leak Safety** | Medium | High | **Very High** (Encapsulated) | **Absolute** (Bulk free) |
| **API Ergonomics** | Low (Cluttered) | Medium (Extra param) | **Very High** (Clean methods) | High |
| **Memory Overhead** | 8-16 bytes (ptr) | **0 bytes** (No struct field) | 16 bytes per struct | 8 bytes (Arena header) |
| **Transpiler Determinism** | High | **Very High** | **Very High** | Medium |

### 3.4 Recommended Hybrid Allocation Strategy

`translate-rust` adopts a hybrid strategy based on data lifecycle:
1. **Pure Functions**: 0 allocator parameters (`no_alloc` default).
2. **Free Functions & Data Converters**: Explicit `allocator: std.mem.Allocator` parameter (Option B).
   ```zig
   pub fn decodeHex(allocator: std.mem.Allocator, input: []const u8) ![]u8
   ```
3. **Stateful Data Structures & Owning Containers**: Struct-stored allocator (Option C).
   ```zig
   pub const BufferPool = struct {
       allocator: std.mem.Allocator,
       items: std.ArrayList(u8),

       pub fn init(allocator: std.mem.Allocator) BufferPool {
           return .{
               .allocator = allocator,
               .items = std.ArrayList(u8).empty,
           };
       }

       pub fn deinit(self: *BufferPool) void {
           self.items.deinit(self.allocator);
       }
   };
   ```
4. **Parse & Batch Pipelines**: Arena-compatible allocators passed at pipeline boundary.

---

## 4. Drop & RAII Translation Architecture

Rust executes destructors deterministically at scope exit via the `Drop` trait.
Zig replaces language-level RAII with explicit `defer` and `errdefer` statements.

```
Rust Scope Unwinding (LIFO)               Zig Scope Unwinding (LIFO defer)
┌───────────────────────────┐             ┌───────────────────────────┐
│ {                         │             │ {                         │
│   let a = Resource::new();│             │   var a = try Res.init(); │
│   let b = Resource::new();│ ──────────> │   defer a.deinit();       │
│   // execution            │             │   var b = try Res.init(); │
│ } // Drop order: b, then a│             │   defer b.deinit();       │
└───────────────────────────┘             │   // LIFO runs b then a   │
                                          │ }                         │
                                          └───────────────────────────┘
```

### 4.1 Drop Order Inversion Rules

There is a critical semantic difference between local variable drop order and struct field drop order in Rust:
1. **Local Variables**: Dropped in **reverse order of declaration (LIFO)**.
   - When lowering to Zig, emitting `defer res.deinit()` immediately after variable initialization naturally executes cleanup in reverse order (LIFO), matching Rust exactly.
2. **Struct Fields**: Dropped in **declaration order (FIFO)** in Rust.
   - In Zig struct `deinit()` functions, field deinitializations must be emitted sequentially in declaration order:
     ```zig
     pub fn deinit(self: *Self) void {
         self.field_a.deinit(self.allocator); // Drop field A first
         self.field_b.deinit(self.allocator); // Drop field B second
     }
     ```

### 4.2 Automated `errdefer` Generation

In Rust, returning an `Err(e)` via the `?` operator automatically runs destructors for all local variables currently in scope.
In Zig, returning an error (`try expr`) does not execute normal scope `defer` statements unless they are in scope. If a function fails midway through initialization, partially allocated sub-resources leak unless protected by `errdefer`.

**Transpiler Rule**:
For every fallible initialization sequence, an `errdefer` is synthesized immediately following each resource acquisition:

```zig
pub fn createPipeline(allocator: std.mem.Allocator, path: []const u8) !Pipeline {
    var parser = try Parser.init(allocator, path);
    errdefer parser.deinit(); // Cleaned up ONLY if subsequent steps fail

    var encoder = try Encoder.init(allocator);
    errdefer encoder.deinit(); // Cleaned up if builder fails

    var state = try allocator.alloc(u8, 1024);
    errdefer allocator.free(state);

    return Pipeline{
        .parser = parser,
        .encoder = encoder,
        .buffer = state,
    };
}
```

### 4.3 Manual Memory Translation for Rust Heap Types

| Rust Heap Type | Zig 0.16 Representation | Allocation Pattern | Deallocation Pattern |
|:---|:---|:---|:---|
| `Box<T>` | `*T` | `try allocator.create(T)` | `allocator.destroy(ptr)` |
| `Vec<T>` | `std.ArrayList(T)` or managed slice | `std.ArrayList(T).empty` | `list.deinit(allocator)` |
| `String` / `Vec<u8>` | `std.ArrayList(u8)` or `[]u8` | `try allocator.alloc(u8, len)` | `allocator.free(slice)` |
| Recursive Struct (`Option<Box<Node>>`) | `?*Node` | `try allocator.create(Node)` | Recursive `deinit` + `allocator.destroy` |

---

## 5. Complete Compilable Translation Examples

### 5.1 Recursive Type with `Box` and Explicit Lifecycle

#### Rust Original Source:
```rust
pub struct TreeNode {
    pub value: u32,
    pub left: Option<Box<TreeNode>>,
    pub right: Option<Box<TreeNode>>,
}

impl TreeNode {
    pub fn new(value: u32) -> Self {
        TreeNode { value, left: None, right: None }
    }

    pub fn insert_left(&mut self, node: Box<TreeNode>) {
        self.left = Some(node);
    }
}
```

#### Emitted Zig 0.16 Code:
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TreeNode = struct {
    value: u32,
    left: ?*TreeNode,
    right: ?*TreeNode,

    /// Static constructor: 0 allocations, no allocator needed
    pub fn init(value: u32) TreeNode {
        return .{
            .value = value,
            .left = null,
            .right = null,
        };
    }

    /// Heap allocation helper: Box<TreeNode>::new(val)
    pub fn createBox(allocator: Allocator, value: u32) !*TreeNode {
        const ptr = try allocator.create(TreeNode);
        ptr.* = TreeNode.init(value);
        return ptr;
    }

    /// &mut self method: attaches owned pointer
    pub fn insertLeft(self: *TreeNode, child: *TreeNode) void {
        self.left = child;
    }

    /// Recursive drop cleanup: frees entire tree deterministically
    pub fn deinit(self: *TreeNode, allocator: Allocator) void {
        if (self.left) |left_child| {
            left_child.deinit(allocator);
            allocator.destroy(left_child);
            self.left = null;
        }
        if (self.right) |right_child| {
            right_child.deinit(allocator);
            allocator.destroy(right_child);
            self.right = null;
        }
    }
};

test "TreeNode lifecycle and allocation" {
    const allocator = std.testing.allocator;

    var root = TreeNode.init(10);
    defer root.deinit(allocator);

    const child = try TreeNode.createBox(allocator, 5);
    root.insertLeft(child);

    try std.testing.expectEqual(@as(u32, 10), root.value);
    try std.testing.expect(root.left != null);
    try std.testing.expectEqual(@as(u32, 5), root.left.?.value);
}
```

### 5.2 Dynamic Allocating Module with Re-Exports & Fallible Error Unwinding

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Encapsulated module namespace (Rust: pub mod codec)
pub const codec = struct {
    pub const Error = error{
        InvalidHexDigit,
        OddLengthInput,
        OutOfMemory,
    };

    /// Rust: pub struct HexEncoder
    pub const HexEncoder = struct {
        allocator: Allocator,
        delimiter: ?u8,

        pub fn init(allocator: Allocator, delimiter: ?u8) HexEncoder {
            return .{
                .allocator = allocator,
                .delimiter = delimiter,
            };
        }

        pub fn encode(self: *const HexEncoder, bytes: []const u8) ![]u8 {
            const hex_chars = "0123456789abcdef";
            const out_len = if (self.delimiter != null and bytes.len > 0)
                bytes.len * 3 - 1
            else
                bytes.len * 2;

            const buf = try self.allocator.alloc(u8, out_len);
            errdefer self.allocator.free(buf);

            var out_idx: usize = 0;
            for (bytes, 0..) |b, i| {
                if (i > 0) {
                    if (self.delimiter) |delim| {
                        buf[out_idx] = delim;
                        out_idx += 1;
                    }
                }
                buf[out_idx] = hex_chars[b >> 4];
                buf[out_idx + 1] = hex_chars[b & 0x0f];
                out_idx += 2;
            }

            return buf;
        }
    };
};

/// Synthesized re-export (Rust: pub use codec::HexEncoder;)
pub const HexEncoder = codec.HexEncoder;

test "HexEncoder allocation and error-defer safety" {
    const allocator = std.testing.allocator;

    const encoder = HexEncoder.init(allocator, ':');
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    const result = try encoder.encode(&input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("de:ad:be:ef", result);
}
```

---

## 6. Key Architectural Decisions & Tradeoffs

1. **Explicit Parameter Injection over Implicit Global / Thread-Local Allocators**:
   - *Decision*: Passing explicit `allocator: std.mem.Allocator` parameter or storing it in the owning struct.
   - *Tradeoff*: Increases parameter count for allocating functions by 1, but guarantees compliance with Tiger Style, eliminates hidden global state, and ensures compatibility with embedded/Wasm targets.

2. **Strict `no_alloc` Default for Pure Compute Functions**:
   - *Decision*: Functions whose AST contains no heap allocation receive zero allocator arguments.
   - *Tradeoff*: Requires IR static analysis pass to verify purity, but produces idiomatic, zero-overhead Zig for algorithmic and compute-heavy crates (e.g. hashing, checksums).

3. **Inverted LIFO `defer` for Local Scopes vs Sequential FIFO for Struct Fields**:
   - *Decision*: Emitting `defer` immediately on local binding to exploit Zig's LIFO execution, while emitting sequential member deinitializations inside struct `deinit()`.
   - *Tradeoff*: Requires differentiated drop order lowering depending on AST context, but guarantees 100% semantic fidelity with Rust's Drop specification.
