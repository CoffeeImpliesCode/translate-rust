# Idiom Mapping: Rust → Correct & Proper Zig 0.16

Research date: 2026-08-17. Target: **Zig 0.16.0** (released 2026-04-14 — https://ziglang.org/news/0.16.0-released/).

Scope: a per-feature mapping of the full Rust language surface to *idiomatic* Zig 0.16
(explicit allocators, comptime, tagged unions, error unions, tiger style). Each entry:
Rust shape → Zig translation, a tiny code sketch, and correctness traps. Difficulty
rating per feature and v1-blocker list are in §19–§20.

Grounding: Zig std sources cited against the installed tree at
`~/.cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std/`; language facts
cited to zig.guide, the Zig docs, the Rust Reference, and the existing Rust→Zig
transpiler `sanxiyn/rust2zig`.

---

## 1. Module system: `mod` / `use` / `crate` → file imports, pub API surface

Rust modules are items (`mod foo { ... }` or `mod foo;` from `foo.rs`/`foo/mod.rs`),
and `use`/`pub use` control the API surface. Zig has **no modules or namespaces**; a
file is a container and `@import` returns that container as a type. Zig 0.16 does not
even have Zig's own `pub use` re-export — a "module" is a struct with public decls.

```rust
// lib.rs
pub mod util;
pub use util::helper;
pub struct Widget { pub n: u32 }
```

```zig
// util.zig
pub fn helper() void {}
// lib.zig
pub const util = @import("util.zig");
pub const helper = util.helper;   // Zig HAS no re-export alias => re-declare
pub const Widget = struct { n: u32 };
```

Trap notes:
- `pub use` has **no direct Zig equivalent** — each exposed name must be re-declared;
  aliasing one decl is the closest (`pub const helper = util.helper;`).
- `mod foo;` (file split) maps naturally to `@import("foo.zig")`, but Zig does not
  auto-discover files from a `mod` table — the importer must name the file.
- Rust crate root ↔ Zig file that is `@import`ed. There is no `crate::` path; use-side
  references are `@import("...")` handles, so a single `pub const` per file is the
  cannonical "module handle".
- `pub` in Zig defaults everything to private unless `pub` — mirror Rust's default.
- Escaping: `rust2zig` emits Zig-keyword collisions as `@"name"` (src/translate/name.rs),
  an idiom required for e.g. `Option::and` → `fn @"and"`.

Difficulty: **mechanical**. Not a v1 blocker.

## 2. Structs + impl blocks: methods → namespaced fns, pub fields, #[repr(C)]

Rust: `struct` as data, `impl` blocks attach methods, `#[repr(C)]` fixes layout. Zig:
`struct` with pub fields; functions *inside* the struct become "methods" (namespaced).
Layout is natural (C-compatible field order) unless `packed`/`extern`; `extern struct`
is the explicit C-layout form.

```rust
#[repr(C)]
pub struct Point { pub x: i32, pub y: i32 }
impl Point {
    pub fn new(x: i32, y: i32) -> Self { Point { x, y } }
    pub fn len(&self) -> i32 { self.x + self.y }
    pub fn move_by(&mut self, dx: i32, dy: i32) { self.x += dx; self.y += dy; }
}
```

```zig
pub const Point = extern struct {
    x: i32,
    y: i32,
    pub fn new(x: i32, y: i32) Point { return .{ .x = x, .y = y }; }
    pub fn len(self: *const Point) i32 { return self.x + self.y; }
    pub fn moveBy(self: *Point, dx: i32, dy: i32) void { self.x += dx; self.y += dy; }
};
```

Trap notes:
- Zig has no implicit `self`; receivers are explicit params. `&self` → `self: *const Self`;
  `&mut self` → `self: *Self`; owned `self` → `self: Self` (by value). rust2zig uses exactly
  these (`&self` → `self: *const Self`).
- Method calls `p.len()` work through Zig's "lazy field" namespacing; `Foo.new(...)`
  needs the type qualifier only for associated fns.
- `#[repr(C)]` ↔ `extern struct`. Plain `struct` field order is also sequential and
  C-order but may be reordered/aligned; `extern struct` guarantees C ABI layout for FFI.
- Zig struct fields are `pub` by default at container scope — matching Rust's need to
  mark `pub` is unnecessary; mark `pub` only to satisfy the exporter's keying.

Difficulty: **mechanical**. Not a v1 blocker.

## 3. Enums: C-like, data-carrying, recursive, #[non_exhaustive], repr(u8)

Rust enums are tagged unions (turned into what Zig calls a tagged union). Zig's
`enum` is only the C-like tag type; `union(enum)` adds payloads.

C-like enum:
```rust
#[repr(u8)]
pub enum Color { Red = 0, Green = 1, Blue = 2 }
```
```zig
pub const Color = enum(u8) { red = 0, green = 1, blue = 2 };
```

Data-carrying enum → tagged union:
```rust
pub enum Shape { Circle(f64), Rect { w: f64, h: f64 } }
```
```zig
pub const Shape = union(enum) { circle: f64, rect: struct { w: f64, h: f64 } };
```

Recursive (Box indirection):
```rust
pub enum List { Nil, Cons(u32, Box<List>) }
```
```zig
pub const List = union(enum) {
    nil,
    cons: struct { head: u32, next: *List },   // Box => *T, explicit allocation
};
```

`#[non_exhaustive]`: Rust forces downstream crates to add a `_` arm
(https://doc.rust-lang.org/reference/attributes/type_system.html — "When pattern
matching on a non-exhaustive variant ... a StructPattern must be used which must
include a ..."). Zig has no per-variant non-exhaustiveness; the tag set is fixed.
Unhandled tags cause a compile error on `switch` (safety: `corruptSwitch` in
`std/debug.zig` — "switch on corrupt value"), so the translator must synthesize a
catch-all arm for `#[non_exhaustive]` enums.

Trap notes:
- Zig enum values are *always* lowercase by convention; `@enumToInt`/`@intFromEnum`
  explicitly convert. Auto-hash/`std.meta` works on both.
- Tagged-union member with payload maps to the Zig union payload capture on `switch`
  (`switch (s) { .circle => |r| ..., .rect => |r| ... }`), per zig.guide: "Tagged
  unions are unions that use an enum to detect which field is active."
- Unit variants (`Nil`, `None`) become `void` payloads (`nil,`) — Zig omits the `: void`.
- Recursion REQUIRES pointer indirection in both languages; in Rust via `Box`, in Zig
  via `*T` — but Zig does *not* auto-allocate; the translator must pass an allocator
  and allocate each `Cons.next` (`gpa.create(List)`), which the Box's ownership then
  owns. rust2zig's `&T`→`*const T`/`&mut T`→`*T` erases Rust's Box/lifetime safety.
- `repr(u8)` ↔ `enum(u8)`. Missing `repr` in Rust defaults to `isize`-backing; Zig
  defaults to `u32`-ish — match explicitly with `enum(u8)`/`enum(u32)`.

Difficulty: **moderate** (tagged unions map cleanly; recursion + allocation and
non-exhaustive are the traps). Not a v1 blocker for data-carrying; recursive-with-Box
needs the ownership/allocator layer (§8).

## 4. Unions: extern union vs untagged union

Rust `union` is an *untagged* C-like union (raw bytes, unsafe to read). Zig `union`
(bare) is also untagged and `extern union` fixes C layout. Zig additionally has
*packed* unions for bit-level layout; none of these have a runtime tag.

```rust
#[repr(C)]
pub union Bits { pub i: i32, pub u: u32 }
```
```zig
pub const Bits = extern union { i: i32, u: u32 };
```

Trap notes:
- Rust `union` is fundamentally for FFI/C interop and requires `unsafe` to read. Zig
  `extern union` reads require no `unsafe` keyword but are still "detectable illegal
  behaviour" to read the non-active field — zig.guide: "Accessing a field in a union
  that is not active is detectable illegal behaviour." Same semantics.
- `#[repr(C)] union` ↔ `extern union`; `#[repr(packed)]` ↔ `packed union`.
- Rust gives every union field write rules (only `Copy` types as fields); Zig allows
  any field but the safety rule is runtime, not compile-time.
- Do NOT map Rust's `enum` to `union`; map `enum` w/ data → `union(enum)` (tagged).

Difficulty: **mechanical**. Not a v1 blocker.

## 5. Generics: monomorphization → comptime type params, const generics, where clauses

Rust generics (= parametric polymorphism, monomorphized at compile time) map to Zig
comptime. Zig `fn Foo(comptime T: type)` generates code per instantiation — Zig's form
of monomorphization. rust2zig: "Rust generics are translated to Zig comptime (enums,
functions, and methods)."

```rust
pub fn max<T: Ord>(a: T, b: T) -> T { if a > b { a } else { b } }
```
```zig
pub fn max(comptime T: type, a: T, b: T) T { return if (a > b) a else b; }
```

Const generics:
```rust
pub struct Arr<T, const N: usize> { data: [T; N] }
```
```zig
pub fn Arr(comptime T: type, comptime N: usize) type {
    return struct { data: [N]T };
}
```

Trap notes:
- Zig has no `where` clause; "bounds" are checked at the call site by actual method
  presence (duck typing, §6). So `T: Ord` degrades to "whatever supports `>`" — Zig
  will error if a concrete instantiation lacks the op. rust2zig emits `@hasField`-free
  code and relies on comptime type-checking.
- Zig generic functions declare `comptime T: type` first (before runtime args). In
  methods, rust2zig places comptime params *after* `self` so the call site infers them.
- Const generics: use `comptime N: usize` param; array type is `[N]T` (not `[T; N]`).
- One generic fn with N instantiations costs N codegens — mirror Rust's monomorphization
  cost. Zig additionally memoizes per identical type.
- No higher-kinded types, no trait bounds; where-clauses vanish (see §6 difficulty).

Difficulty: **moderate** for value/type generics; const generics trivial. Not a v1
blocker for common cases.

## 6. Traits: static dispatch → comptime duck typing; dyn Trait → vtable struct

This is the hardest semantic feature. Two sub-problems.

**a) Static dispatch (`fn f<T: Trait>(...)`)** — Rust resolves at compile time; Zig's
comptime duck typing, plus `@hasDecl`/`@hasField`, expresses it.

```rust
trait Shape { fn area(&self) -> f64; }
fn total<T: Shape>(s: &T) -> f64 { s.area() }
```
```zig
fn total(comptime T: type, s: *const T) f64 { return s.area(); }
// Zig: T just needs a `.area` method — no trait bound needed.
```

**b) Dynamic dispatch (`dyn Trait`)** — a *runtime* vtable, which Zig has no built-in
support for. The Rust Reference: "Calling a method on a trait object results in virtual
dispatch at runtime: that is, a function pointer is loaded from the trait object vtable
and invoked indirectly." (https://doc.rust-lang.org/reference/types/trait-object.html).
Zig has no vtable type. The translator must synthesize one:

```rust
let shapes: Vec<Box<dyn Shape>> = ...;  // heterogeneous collection
```
```zig
const ShapeVTable = struct {
    area: *const fn (*anyopaque) f64,
};
const ShapeObj = struct { ptr: *anyopaque, vtable: *const ShapeVTable };
fn area(self: *const ShapeObj) f64 { return self.vtable.area(self.ptr); }
```

Trap notes:
- **Associated types, supertraits, HRTB, GATs, `impl Trait` return positions** have no
  direct Zig analogue; each is a manual elaboration (an extra comptime param, a needed
  `@hasDecl` guard, or a hand-written witness struct).
- `dyn` fat pointer = (data ptr, vtable ptr) — Zig has no fat pointers; the translator
  must build `{ ptr, vtable }` records (§4 union and §8 pointers combine). No prior
  transpiler does this (rust2zig has no dyn support).
- The boundary of "idiomatic": hand-writing a vtable per trait diverges from Zig norms;
  a common real-Zig pattern is a `struct` of fn pointers passed explicitly (like
  `std.mem.Allocator`, whose vtable is a `struct` of fn pointers — `mem/Allocator.zig`).
- Because dynamic dispatch changes *when* monomorphization happens (runtime, not
  comptime), it is the single biggest generalization of the hard tier.

Difficulty: **hard**. Static dispatch = moderate; `dyn` = **hard / v1 blocker** if any
crate uses heterogeneous trait objects.

## 7. Option → optional types; Result → error unions (? / try)

- `Option<T>` (core `Option`) → Zig `?T` (optional). Zig optionals cannot be switch
  cases; rust2zig lowers `match` on `Option` to an `if` with an optional capture
  ("A `match` on `core::option::Option` cannot become a switch, because Zig optionals
  are not unions.").
- `Result<T, E>` → Zig error union `E!T`, where `E` maps to an error set. `?` in Rust
  ↔ `try` in Zig; `unwrap()` ↔ `orelse`/`catch`/`std.debug.assert`.

```rust
fn parse(s: &str) -> Result<i32, ParseError> { s.parse().map_err(ParseError::new) }
fn top(s: &str) -> Result<i32, ParseError> { let v = parse(s)?; Ok(v * 2) }
```
```zig
const ParseError = error{ Invalid };
fn parse(s: []const u8) ParseError!i32 { return std.fmt.parseInt(i32, s, 10) catch return error.Invalid; }
fn top(s: []const u8) ParseError!i32 { const v: i32 = try parse(s); return v * 2; }
```

Trap notes:
- zig.guide: "An error set type and another type can be combined with the `!` operator
  to form an error union type." Map `Result<T,E>` to `E!T` only when `E` is a finite
  error set; `Box<dyn Error>` / `anyhow::Error` dynamic errors have no Zig analogue
  (would need `anyerror` — legal but coarse; loses the set).
- `?` ↔ `try`. `unwrap` ↔ `catch |err| return err` or `orelse` for Option. `expect(msg)`
  ↔ `catch unreachable` (panics on error in safety builds).
- Rust error sets are nominally typed; Zig error sets are structural and can be the
  inferred union of all `return error.X`. Use `error{...}` explicitly to keep the API.
- `Some(x)` optional capture test: `if (opt) |x| { ... } else {}`; `None` tests `== null`.

Difficulty: **moderate** (finite error sets + `?` map cleanly; dynamic `Error` objects
do not). Not a v1 blocker for typical code.

## 8. Ownership: Box/Rc/Arc/Cell/RefCell → allocator/arena; slices & borrows

Rust ownership/borrowing has **no Zig equivalent**. Zig has no borrow checker; memory
is managed by explicit allocators, `defer`, and `errdefer`. rust2zig "erases lifetimes"
and maps `&T` → `*const T`, `&mut T` → `*T`, `&[T]` → `[]const T` — the safe guarantees
are gone.

Ownership map:
- `Box<T>` → `gpa.create(T)` (plus `alignedAlloc`) with `defer gpa.destroy`/`free`.
- `Rc<T>`/`Arc<T>` → shared resource with an explicit refcount struct (`std.atomic` for
  `Arc`). Neither exists in std as a generic; hand-roll a refcounted wrapper.
- `Cell<T>` → `*T` (single-thread mutation via pointer); `RefCell<T>` → explicit runtime
  borrow flags (like a checked `*T` with a borrow counter). Atomic cells → `std.atomic`.

```rust
fn make() -> Box<i32> { Box::new(5) }
```
```zig
fn make(gpa: std.mem.Allocator) *i32 {
    const p = gpa.create(i32) catch return @ptrFromInt(0); // real: error!*i32
    p.* = 5;
    return p;
}
// caller: defer gpa.destroy(p);
```

Slices:
```rust
fn sum(xs: &[i32]) -> i32 { xs.iter().sum() }
```
```zig
fn sum(xs: []const i32) i32 { var s: i32 = 0; for (xs) |x| s += x; return s; }
```

Trap notes:
- Zig allocator interface is explicit and vtable-based — `std.mem.Allocator` core:
  `Error = error{OutOfMemory}`, `alloc`, `create`, `destroy`, `free` (mem/Allocator.zig).
  Every owning fn must thread an `Allocator` param ("Reusable code should accept an
  Allocator parameter if it needs to allocate" — andrewkelley.me, Zig async I/O post).
- `defer`/`errdefer` reproduce RAII `Drop` for scope-owned resources. rust2zig's drop
  elaboration: "`defer x.drop()` when destruction is unconditional on scope exit; alive
  flags only when destruction is path-sensitive" (design/drop.md).
- Borrowing rules *disappear* — the translator emits `*T`/`[]const T` but there is no
  compiler to enforce aliasing. Document the translated ownership contract; Zig returns
  `error.OutOfMemory`/runtime UB where Rust would have refused to compile.
- `&mut T` (unique borrow) → `*T`; the translator must not introduce aliasing that Zig
  would allow but Rust forbade. This is a *correctness* risk, not a compile error.

Difficulty: **hard** — mechanical for simple scoped ownership, hard for shared/parsed
ownership (Rc/Arc/RefCell/drop timing). **v1 blocker** for any crate relying on interior
mutability or shared ownership. Not a blocker for `no_std`-ish scoped code.

## 9. Pattern matching: match / if let / let-else → switch / if, destructuring, guards

Rust `match` is exhaustive, with `if let`, `let-else`, irrefutable patterns, guards,
and destructuring. Zig `switch` on enums/tagged unions is exhaustive at comptime; there
is no general `match` — only `switch` (enums/unions/bools), `if`, and `orelse`. Irrefutable
patterns (`let x = ...`) map to plain assignment; destructuring is manual.

```rust
match x {
  1 => 10,
  n if n > 5 => n * 2,
  _ => 0,
}
```
```zig
const r = switch (x) {
    1 => 10,
    else => blk: {
        if (x > 5) break :blk x * 2;
        break :blk 0;
    },
};
```

`if let Some(v) = opt` → Zig `if (opt) |v| {...}` (optional capture).
`let-else` (`let Some(v) = opt else { return; }`) → `const v = opt orelse return;`
(only works when the binding is a single placeholder; multi-binding needs a helper).

Trap notes:
- Zig `switch` requires exhaustiveness at comptime; a Rust `match` with `_` arm maps to
  `else`. rust2zig notes: a plain `match` on `Option` uses `if` because optionals aren't
  unions; user-defined enums use `switch`.
- Guards have no switch equivalent; lower to nested `if` inside the arm (`blk:` + breaks).
- Pattern `ref`/`ref mut` (borrow binding) map to capture syntax `|*v|` (pointer capture)
  for `&mut`, `|v|` for value — per zig.guide unions capture examples.
- Destructuring structs/tuples is manual field-by-field — Zig has no pattern
  destructuring. rust2zig's `match_ergonomics` desugar makes default binding modes
  explicit first.
- `let-else` is not directly expressible (orelse limited) — moderate difficulty.

Difficulty: **moderate**. Not a v1 blocker for enum/bool/tagged-union switches; = for
tuple/struct destructuring needs manual lowering.

## 10. Iterators / closures: Fn/FnMut/FnOnce → comptime fns / explicit loop lowering

Rust iterators + closures are `Fn`-trait objects with `map`/`filter`/`fold` chains. Zig
has no iterator trait; `for` loops over containers/slices/ranges are the idiom;
`std.meta`/comptime cover simple folds.

Closures: rust2zig translates a closure to "a struct value with a `call(self: @This(), ...) R`
method, instantiated as `}{}` (no captures) or `}{ .a = a, ... }` (with captures)" — i.e.
a callable struct. Only zero-capture and immutable-capture cases are handled; FnMut/move
are TODO in rust2zig.

```rust
let doubled: Vec<i32> = xs.iter().map(|x| x * 2).collect();
```
```zig
// Lower the chain to an explicit loop:
var list = std.ArrayList(i32){};
for (xs) |x| try list.append(x * 2);
```
```zig
// Or a zero-capture closure struct:
const Cf = struct { fn call(_: @This(), x: i32) i32 { return x * 2; } };
// call sites append `.call(...)`.
```

Trap notes:
- `for x in iterable` maps directly when the iterable is an array/slice/range; rust2zig
  translates `for (a,b) in zip(a,b)` to Zig's multi-object `for (a, b) |x, y|`, and
  `enumerate()` to `for (l, 0..) |e, i|` (index last in Zig).
- Closures capturing by value/ref: a struct + call fn matches semantic; but `FnMut`
  (mutating) and `move` need interior mutation that Zig's single-`*T` doesn't cleanly
  express — moderate-to-hard.
- Iterator adapters beyond map/filter/zip/enumerate are a "TODO" in rust2zig; every
  adapter is a manual loop rewriting problem. General `Iterator` trait impls (custom
  `.next()`) need an explicit state machine.
- Closures as *values* passed around (fn pointers) map to passing the callable-struct
  by value or a fn pointer — no closure capture in a plain fn pointer.

Difficulty: **hard** (simple map/filter loops = moderate; arbitrary closures & custom
iterators = hard). v1 blocker for iterator-heavy crates; fine for range/array loops.

## 11. Strings: String / &str / Cow → []const u8 / ArrayList(u8)

Rust `&str` → `[]const u8` (bytes; Zig strings ARE byte slices). `String` (owned) →
`std.ArrayList(u8)` (unmanaged or managed with allocator). `Cow<'a, str>` → an enum of
borrowed vs owned string (a tagged union).

```rust
let owned: String = format!("x={}", n);
let s: &str = &owned;
```
```zig
var buf = std.ArrayList(u8).empty;   // unmanaged: caller passes gpa
defer buf.deinit(gpa);
try buf.writer(gpa).print("x={d}", .{n});
const slice: []const u8 = buf.items;
```

`&str` → `[]const u8`: rust2zig: "`&str` translates to `[]const u8` and `.as_bytes()`
erases to its receiver, since a Zig string literal already is a byte slice."

Trap notes:
- String is **UTF-8 already** in both; Zig treats `[]const u8` as opaque bytes but has
  `std.unicode.utf8ValidateSlice` if validation matters.
- Zig literal `"x"` is `*const [N:0]u8`; coercible to `[]const u8` but NOT null-terminated
  by default. `[:0]const u8` is the sentinel slice — needed for C interop (pass a
  `@ptrCast`/`[0..:0]`). Rust `&str` is never null-terminated; match with `[]const u8`.
- In Zig 0.16, `std.ArrayList(u8)` (managed, allocator-storing) is **deprecated** in
  favor of unmanaged `.empty` + explicit allocator arg (array_list.zig: "Default
  initialization of this struct is deprecated; use `.empty` instead."). Emit unmanaged.
- `format!` ↔ `std.fmt.allocPrint` (allocator-returning) or a stack `bufPrint`.
- `Cow` is `enum(Cow)<B>` (Borrowed/Owned) — map to `union(enum) { borrowed: []const u8, owned: std.ArrayList(u8) }` + a `toSlice()` helper. No direct std type.

Difficulty: **moderate**. Not a v1 blocker.

## 12. Collections: Vec/HashMap/BTreeMap/HashSet/VecDeque → Zig std equivalents

| Rust | Zig 0.16 std |
|---|---|
| `Vec<T>` | `std.ArrayList(T)` (unmanaged `.empty`, allocator per call) |
| `HashMap<K,V>` | `std.AutoHashMap(K,V)` / `std.StringHashMap(V)` / `HashMap(K,V,Context,load)` |
| `BTreeMap<K,V>` | **none** in std; `std.Treap` or `std.std.enums`/sorted `ArrayList` |
| `HashSet<T>` | `std.AutoHashMap(T,void)` |
| `VecDeque<T>` | `std.Deque(T)` |

```rust
let mut h: HashMap<String, i32> = HashMap::new();
h.insert("a".into(), 1);
```
```zig
var h = std.StringHashMap(i32).init(gpa);   // or AutoHashMapUnmanaged
defer h.deinit();
try h.put("a", 1);
```

Trap notes:
- Every std container is allocator-parameterized: `init(gpa)`/`init(allocator)` and
  per-call `gpa` for growing ops (memory_fns are allocator-explicit). Trap: forgetting
  the allocator arg — the `Allocator.Error`/`error.OutOfMemory` can't be ignored; every
  mutating op returns an error union.
- `StringHashMap` hashes *contents*; `AutoHashMap([]const u8,...)` refuses via
  compileError ("std.hash.autoHash does not allow slices here ... Consider using
  std.StringHashMap for hashing the contents of []const u8"). Trample: use the right map.
- Iteration order: Zig HashMap is unordered (like Rust's `HashMap`); `BTreeMap`'s sorted
  order needs a different structure — Zig has no B-tree in std; use `std.Treap` or keep a
  sorted `ArrayList` and binary-search. This is a **difficulty trap** for ordered maps.
- Keys/values are NOT freed by `deinit` — caller owns key/value memory
  ("Key memory is managed by the caller. Keys and values will not automatically be
  freed." — hash_map.zig). Rust `HashMap` owns its keys; Zig does not. Correct deinit
  must free keys first.

Difficulty: **moderate** (Vec/HashMap easy; ordered maps = hard, no std BTreeMap;
ownership of keys is a real trap). Not a v1 blocker for standard maps.

## 13. Error handling: unwrap/expect/panic → error return + assert; catch_unwind

- `unwrap()`/`expect()` → `catch unreachable` (panics on error in safety builds) or
  `orelse unreachable` for optionals. `assert!` → `std.debug.assert` (but see trap).
- `panic!("...")` → `@panic("...")` / `std.debug.panic`.
- `catch_unwind` (panic→Result) has **no Zig equivalent** — Zig panics are not catchable
  by design; errors are returned, not unwound.

```rust
fn f(x: u8) -> u8 { assert!(x <= 10, "too big"); x + 1 }
```
```zig
fn f(x: u8) u8 { std.debug.assert(x <= 10); return x + 1; }
```

Trap notes:
- **`assert` differences**: Zig `std.debug.assert` in Debug/ReleaseSafe, but `ReleaseFast`
  elides it (`runtime_safety` in debug.zig: true only in `.Debug, .ReleaseSafe`). Rust
  `assert!` always checks. rust2zig's prior-work warning: "Zig `assert` evaluates its
  argument in all builds vs Rust `debug_assert!` erases it in release" — mirrored
  hazard here. Emit `if (!cond) @panic(...)` when checks must survive ReleaseFast.
- Integer overflow: Rust panics on overflow in debug, wraps in release; Zig has explicit
  `+%`/`*%` for wrap and panics (`integerOverflow` in debug.zig) for `+` in safety. Match
  the intended behavior explicitly, don't rely on defaults.
- `catch_unwind` cannot be translated; it signals a redesign (return an error instead).
- Bounds/safety: `ReleaseSafe` keeps bounds + overflow checks; `ReleaseFast` drops them —
  rust2zig/prior-work note "slice bounds under ReleaseSafe/ReleaseFast" is a real hazard.

Difficulty: **moderate**; `catch_unwind` is a **hard-block** (design change, not a
translation).

## 14. async/await: Zig 0.16 std.Io (no async/await keyword) — translation story

Zig **removed** the `async`/`await` keywords in the 0.15 cycle and returned in 0.16 a
different model: **`std.Io`**, an interface "that works exactly like Zig's Allocator
pattern" (https://blog.bokvi.com/blog/zig-in-2026/). The VTable (`std/Io.zig`) has
`async`, `concurrent`, `await`, `groupAsync`, `groupAwait` etc.; you call
`io.async(fn, args)` and `future.await(io)`. File system, net, sleep, process all take an
`io` param.

Andrew Kelley's async demo (https://andrewkelley.me/post/zig-new-async-io-text-version.html):
"Reusable code should accept an Allocator parameter if it needs to allocate, and it
should accept an `Io` parameter if it needs to perform I/O operations." And:
```
var a = io.async(doWork, .{ io, "hard" });
var b = io.async(doWork, .{ io, "... " });
a.await(io);
b.await(io);
```
("wait one second because these operations are happening at the same time" — Threaded Io.

**Translation story**: Rust `async fn`/`.await` define the *whole program's* scheduling
(Executor, Future, Pin). Zig `std.Io` schedules only I/O sites; plain blocking code is
still blocking. There is no 1:1 mapping.

Trap notes / honest assessment:
- Rust's `async` composes a `Future` state machine per fn and needs an executor; Zig has
  no user-visible executor — you pick a backend (`std.Io.Threaded`, `.Uring` on Linux,
  `.Kqueue`, `.Dispatch`) and pass `io` around. The *structure* of an async program
  differs fundamentally.
- Straightforward translation: an `async fn doing one I/O call then a compute step` maps
  to a plain function taking `io` and calling `io.file...` / `io.async` as needed. This
  captures *concurrency of I/O* — the common 80% case.
- Hard translation: `async`/`.await` that relies on `Future::poll` state machines,
  `Pin`, `Stream`/`Select`, `tokio::select!`, `futures::join!` all stop having direct
  analogues; that's a rewrite, not a transliteration.
- `std.Io.Threaded` (the all-backends-safe default) plus `io.async`/`io.await` gives you
  the concurrent-I/O semantics without fibers; Uring uses actual evented I/O.

Difficulty: **hard** (moderate for single-I/O-call async fns; hard for full async/await
executor composition). **v1 blocker** for any crate using tokio/async-std; fine for
synchronous I/O or `no_std`.

## 15. Macros: macro_rules!, proc macros, derive → what translation requires

Rust macros generate code BEFORE semantics. Zig has **no macro system at all**; the only
"code generation" is comptime. Translation is impossible on the syntax level — macros
must be **expanded first**, then the *expanded* code translated. rust2zig supports only
`assert_eq!`, `panic!`, `println!` directly (src/translate/mac.rs); everything else is
out of scope.

- `macro_rules!` / proc macros / derives: run the real Rust toolchain (`cargo expand` /
  `rustc -Zunpretty=expanded`) to get the expanded AST, then translate that. Prior-work
  (parsing-tooling.md) concludes: expand-via-rustc is the only sound route; `cargo expand`
  is "lossy" per its own README but fine for the translation pipeline if it only feeds a
  parser.
- `#[derive(Debug, Clone, PartialEq)]`: expand into manual Zig — `@import("std").debug`,
  a `clone` fn, an `eql` via `std.meta.eql`; derive has no direct Zig idiom.

```rust
#[derive(Debug)]
pub struct Foo { pub x: i32 }
```
```zig
pub const Foo = struct {
    x: i32,
    pub fn format(self: Foo, w: anytype) !void { try w.print("Foo{{ .x = {d} }}", .{self.x}); }
};
```

Trap notes:
- A straightforward structural translator CANNOT handle macros textually; it needs a
  pre-pass that invokes rustc/cargo to expand, then parses the result (per
  parsing-tooling.md §2.3 rustc_driver sidecar, or `cargo expand` when acceptable).
- Attribute semantics (`#[repr]`, `#[non_exhaustive]`, `#[cfg]`) are separate: `#[repr(C)]`
  maps to `extern struct`, `#[non_exhaustive]` to a synthesized `else` arm, `#[cfg]`
  needs target-aware filtering during frontend collection.
- Proc-macro output is arbitrary Rust; after expansion it is ordinary Rust and pipeline
  continues. Hygiene: expanded text isn't guaranteed to compile identically (cargo-expand
  README: "lossy ... debugging aid only") — a translation pipeline must re-type-check.
- `#[cfg(test)]`/test blocks: Zig has `test` blocks; map `#[cfg(test)] mod tests` to a
  `test "..." {}` block, but only after resolving cfg (the frontend decides).

Difficulty: **hard-block for v1** if input crates use derive/proc macros — you must
build/run the Rust toolchain to expand; no syntactic shortcut. Derive of common traits
(Debug/Clone/PartialEq) on simple structs is moderate after expansion; custom proc
macros are a hard gate.

## 16. Unsafe blocks / raw pointers: *const T / *mut T, pointer arithmetic

Rust `unsafe` + raw pointers (`*const T`/`*mut T`) map to Zig pointers DIRECTLY — Zig
has no `unsafe` keyword for pointers; every `*T` is effectively a raw pointer, and
`@ptrCast`, `@intFromPtr`, `@ptrFromInt`, `@alignCast` replace `unsafe` casts.

```rust
unsafe { (ptr as *const u8).offset(4).read() }
```
```zig
const p: *const u8 = @ptrCast(ptr);          // *anyopaque->*const u8
const q = p + 4;                              // pointer arithmetic via +
const v: u8 = q.*;
```

Trap notes:
- Zig pointer types carry a *size class*: `*T` (single), `[*]T` (many, unsized), `[N]T`
  arrays, slices `[]T`, sentinel `[:s]T`, and `[*c]T` (C-style, nullable/arithmetic).
  Rust raw ptr arithmetic ⇢ `[*c]T`/`[*]T`, not `*const T`. `@ptrCast` + `@alignCast`
  for downcasts (alignment must be asserted or stated).
- `unsafe` blocks vanish — Zig has no `unsafe`; the safety burden is fully on the
  translator. `.offset()` ⇢ `+`/`-` arithmetic; `.read()` ⇢ `x.*`; `.write()` ⇢ `x.* = v`.
- null: Rust `*const T` (incl. null) ⇢ Zig `?*T` optional, or `[*c]T` for C-style.
  `NonNull<T>` ⇢ `*T` (guaranteed non-null single pointer).
- ZSTs (zero-sized types): Rust `*const ()` etc. map to Zig zero-size types but Zig
  pointer arithmetic on them is subtle; usually drop ZST handling explicitly.
- Rust `PTR` provenance/strictness has no Zig parallel — a documented translation risk.

Difficulty: **moderate** (syntax maps one-to-one; safety semantics differ). Not a v1
blocker if the crate's unsafe is FFI-ish.

## 17. FFI items: extern "C"

Rust `extern "C" fn` ↔ Zig `extern fn` (C calling convention by default for `extern`/
`export`). Types crossing the boundary must be C-representable.

```rust
extern "C" { fn abs(x: i32) -> i32; }
#[no_mangle] pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }
```
```zig
extern fn abs(x: i32) i32;
export fn add(a: i32, b: i32) i32 { return a + b; }
```

Trap notes:
- Zig `extern`/`export` default to the C calling convention (builtin.zig: "Functions
  marked as `extern` or `export` are given this calling convention by default"). `#[no_mangle]`
  export ⇢ `export fn` (Zig mangling isn't applied by default, but `export` is explicit).
- `extern "C"` structs ⇢ `extern struct` (fixed layout, no padding guarantees otherwise).
  `repr(C)` enums ⇢ `enum(uN)` to fix the backing integer size; `repr(C)` unions ⇢
  `extern union`.
- Use sentinel-terminated strings (`[:0]const u8`) for C `char*`: a plain `[]const u8` is
  NOT guaranteed null-terminated. Box/`String` crossing the boundary must be converted
  `@cImport`-able.
- `extern "system"` ⇢ `callconv(.winapi)` on Windows targets (builtin.zig's
  `CallingConvention.winapi`). Variadic `extern "C" varargs` map to `...` Zig varargs.
- ABI mismatch traps: `bool` (Rust `bool` is 1 byte, but C `_Bool` also — match with
  `bool`), `usize` (⇢ `usize`), `#[repr(transparent)]` ⇢ single-field struct. Always
  `zig translate-c`-check the reciprocal header.

Difficulty: **mechanical** for C-representable types. Not a v1 blocker.

---

## 18. Summary table (difficulty per feature)

| # | Feature | Difficulty | v1 blocker? |
|---|---|---|---|
| 1 | Modules | mechanical | no |
| 2 | Structs + impl | mechanical | no |
| 3 | Enums (tagged/recursive/non_exhaustive) | moderate | no* (recursive+Box needs §8) |
| 4 | Unions (extern/untagged) | mechanical | no |
| 5 | Generics → comptime | moderate | no |
| 6 | Traits: static / dyn | static=moderate, **dyn=hard** | static no; **dyn yes** |
| 7 | Option/Result → ?T / E!T | moderate | no (finite error sets) |
| 8 | Ownership/borrowing | **hard** | yes (Rc/Arc/RefCell/drop) |
| 9 | Pattern matching | moderate | no |
| 10 | Iterators/closures | **hard** | yes (custom iterators/closures) |
| 11 | Strings | moderate | no |
| 12 | Collections | moderate (ordered maps hard) | no |
| 13 | Error handling (+catch_unwind) | moderate; **catch_unwind hard-block** | catch_unwind yes |
| 14 | async/await | **hard** | yes (tokio/async) |
| 15 | Macros (derive/proc) | **hard-block** (needs expansion) | yes (derives/proc) |
| 16 | Unsafe/raw pointers | moderate | no |
| 17 | FFI extern "C" | mechanical | no |

Legend: mechanical = direct 1:1; moderate = structural but trapped; hard = semantic
mismatch requiring elaboration/rewrite; hard-block = no direct translation, needs
external tooling or redesign.

*3 requires the §8 ownership layer for recursion, so pair them.

## 19. v1-blocker list (what an end-to-end slice must NOT require)

For a v1 end-to-end slice, preclude input crates that exercise:

1. **`dyn Trait` / heterogeneous trait objects** (§6) — no Zig vtable; needs a manual
   vtable-struct elaboration that no existing transpiler (rust2zig has none) provides.
2. **Ownership beyond scoped** (§8): `Rc`/`Arc`/`RefCell`/`Mutex` interior mutability and
   path-sensitive `Drop` — need an ownership/arena layer and `defer`/alive-flag
   elaboration rust2zig only partially delivers.
3. **Custom iterators & general closures** (§10): FnMut/move closures and non-trivial
   `Iterator` trait impls need per-adapter state-machine lowering.
4. **async/await with an executor** (§14): tokio/async-std composition (select/join/Stream)
   is a rewrite, not a translation; only single-I/O-call async fns map cleanly.
5. **Any macro beyond `assert!`/`panic!`/`println!`** (§15): derive + proc macros require
   running the Rust toolchain (`cargo expand`/rustc driver) to pre-expand before the
   pipeline; a pure-syntax translator cannot proceed.
6. **`catch_unwind`** (§13): impossible; requires redesign to an error-return.

A v1 slice therefore targets: `no_std`-ish, macro-free (or minimal `assert!`/`println!`),
no async, no `Rc`/`Arc`/`RefCell`, no `dyn Trait`, Fn closures limited to zero/immutable
capture — the exact dialect rust2zig's example corpus already covers (gcd, div, option,
sum, geometry, closure, iter, dot, bitset, drop, hash, random, calc).

## 20. Sources (≥6 distinct, primary, verified 2026-08-17)

1. **Zig 0.16 std — `std/mem/Allocator.zig`** (installed tree): allocator vtable +
   `pub const Error = error{OutOfMemory}`, `create`/`destroy`/`alloc`/`free`. Grounds §8.
2. **Zig 0.16 std — `std/Io.zig`** (installed tree): `VTable` with `async`/`concurrent`/
   `await`/`groupAsync`; `Operation = union(enum)`; `userdata`/`vtable` fields. Grounds §14.
3. **Zig 0.16 std — `std/array_list.zig`** (installed tree): "`ArrayList` (managed,
   allocator-storing) Deprecated"; unmanaged `Aligned(T)` with `.empty`, `initCapacity`,
   explicit `gpa` args. Grounds §11/§12.
4. **Zig 0.16 std — `std/hash_map.zig`** (installed tree): `AutoHashMap`/`StringHashMap`;
   "Key memory is managed by the caller. Keys and values will not automatically be freed."
   Grounds §12.
5. **Zig 0.16 std — `std/debug.zig`** (installed tree): `runtime_safety` true only in
   `.Debug, .ReleaseSafe`; `FullPanic` with `unwrapNull`/`integerOverflow`/`outOfBounds`.
   Grounds §13.
6. **Zig 0.16 std — `std/builtin.zig`** (installed tree): `CallingConvention = union(enum(u8))`
   with `.c` default for extern/export; `OptimizeMode`. Grounds §17.
7. **zig.guide — Unions** (https://zig.guide/language-basics/unions/): "Tagged unions are
   unions that use an enum to detect which field is active." + `union(enum)` and payload
   captures. Grounds §3/§9.
8. **zig.guide — Errors** (https://zig.guide/language-basics/errors/): "An error set type
   and another type can be combined with the `!` operator to form an error union."
   Grounds §7.
9. **Zig 0.16 release news** (https://ziglang.org/news/0.16.0-released/): release date
   2026-04-14, "2 changes dominate the release: std.Io..." Grounds target version.
10. **Andrew Kelley — Zig's New Async I/O (Text Version)** (https://andrewkelley.me/post/zig-new-async-io-text-version.html):
    "Reusable code should accept an Allocator parameter if it needs to allocate, and it
    should accept an `Io` parameter if it needs to perform I/O operations." + `io.async`/
    `await` example. Grounds §14.
11. **Rust Reference — Trait object types** (https://doc.rust-lang.org/reference/types/trait-object.html):
    "Calling a method on a trait object results in virtual dispatch at runtime: that is,
    a function pointer is loaded from the trait object vtable and invoked indirectly."
    Grounds §6 dyn.
12. **Rust Reference — Type system (non_exhaustive)** (https://doc.rust-lang.org/reference/attributes/type_system.html):
    "When pattern matching on a non-exhaustive variant ... a StructPattern must be used
    which must include a ...". Grounds §3.
13. **sanxiyn/rust2zig README** (https://github.com/sanxiyn/rust2zig): "Rust generics are
    translated to Zig comptime"; "Rust references are translated to Zig pointers, lifetimes
    are erased"; closures → callable struct; `&str` → `[]const u8`; match-on-Option → if.
    The living reference for the established mapping. Grounds §5/§8/§10/§11.

## 21. Open questions

1. **dyn Trait strategy**: is a manually-synthesized vtable struct (`{ ptr, vtable }`)
   "idiomatic Zig", or should the v1 dialect simply exclude `dyn Trait` (rust2zig has no
   support)? This decides whether trait-heavy crates are in scope.
2. **Ownership model**: do we preserve Rust's unique-borrow semantics via allocator +
   `defer`/`errdefer` alone (robust for scoped `Box`), or must we also synthesize
   `Rc`/`Arc`/`RefCell` refcount wrappers? The answer sets the whole memory layer's
   shape.
3. **Macro pre-expansion**: is running the Rust toolchain (`cargo expand` / pinned
   `rustc_driver`, per parsing-tooling.md) acceptable as a mandatory front-end step, or
   must the translator itself stay syntax-only and reject macro input for v1?
