//! ts_ext_test — the iterator-chain vocabulary the frontend lowering admits.
//!
//! Each test drives a real Rust snippet through the whole frontend and asserts
//! on the IR that comes out. A chain the backend merely stops rejecting is not
//! enough: the source expression, the adapter list, the terminal and the
//! element type all have to be right, because the backend lowers exactly those
//! and nothing re-derives them.

const std = @import("std");
const testing = std.testing;

const pipeline = @import("pipeline.zig");
const ir = @import("translate_rust.ir");
const exprs = ir.exprs;
const types = ir.types;
const infer = @import("infer.zig");

fn analyze(arena: std.mem.Allocator, source: []const u8) !ir.RustIr {
    return pipeline.analyzeSourceWithOptions(arena, "chain_vocab", "2021", source, .{});
}

/// The one chain the snippet produced, or null — null both for "no chain" and
/// for "more than one", so a snippet that fragments cannot pass by accident.
fn onlyChain(model: *const ir.RustIr) ?exprs.NodeId {
    var found: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        if (expression.kind != .iterator_chain) continue;
        if (found != null) return null;
        found = @intCast(index);
    }
    return found;
}

fn typeAt(model: *const ir.RustIr, type_id: exprs.TypeId) types.Type {
    return model.bodies.types[type_id];
}

/// Validate a translated fixture. This is a plain validation gate: the
/// model's own `validateForTranslation` error is the contract, and a test that
/// needs the refusal's recorded reason asserts it off the expression table
/// itself. This helper never prints — the suite captures no stdout contract,
/// so the diagnostic print that lived here was removed.
fn expectTranslatable(model: *const ir.RustIr) !void {
    try ir.validateForTranslation(model);
}

fn methodName(model: *const ir.RustIr, def: exprs.DefId) ?[]const u8 {
    const entity = model.graph.symbol_table.get(def) orelse return null;
    return entity.name;
}

fn adapterName(adapter: exprs.IteratorAdapter) []const u8 {
    return switch (adapter) {
        .map => "map",
        .filter => "filter",
        .flat_map => "flat_map",
        .enumerate => "enumerate",
        .zip => "zip",
        .range_rev => "range_rev",
        .other => "other",
    };
}

/// Assert the chain is rooted at a `slice.chunks(n)`-style call — the chunk
/// iterator is the chain's SOURCE, never an adapter — and that the adapters
/// and terminal are exactly what the source spells.
fn expectChain(
    model: *const ir.RustIr,
    source_method: []const u8,
    names: []const []const u8,
    terminal: exprs.IteratorTerminal,
) !exprs.IteratorChainExpr {
    const chain_id = onlyChain(model) orelse return error.NoIteratorChain;
    const chain = model.bodies.exprs[chain_id].kind.iterator_chain;
    if (chain.terminal != terminal) return error.WrongTerminal;
    if (chain.adapters.len != names.len) return error.WrongAdapterCount;
    for (chain.adapters, names) |adapter, name| {
        if (!std.mem.eql(u8, adapterName(adapter), name)) return error.WrongAdapter;
    }
    const source = switch (model.bodies.exprs[chain.source].kind) {
        .method_call => |call| call,
        else => return error.SourceIsNotACall,
    };
    const method = methodName(model, source.method) orelse return error.MissingMethod;
    if (!std.mem.eql(u8, method, source_method)) return error.WrongSourceMethod;
    return chain;
}

/// The single `core::slice::<carrier>` type in the snippet, or null. The two
/// chunk carriers differ only in the tail `remainder()` keeps.
fn chunkCarrierId(model: *const ir.RustIr, carrier: []const u8) ?exprs.TypeId {
    for (model.bodies.types, 0..) |ty, index| {
        if (isCarrier(ty, carrier)) return @intCast(index);
    }
    return null;
}

/// The element the carrier names. `chunks` and `chunks_exact` both carry the
/// element of the slice they were handed.
fn carrierElement(model: *const ir.RustIr, carrier_id: exprs.TypeId) !types.Type {
    return switch (model.bodies.types[carrier_id]) {
        .external_nominal => |external| external.args[0],
        else => error.NotACarrier,
    };
}

/// True when `ty` names `core::slice::<carrier>`.
fn isCarrier(ty: types.Type, carrier: []const u8) bool {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return false,
    };
    return external.path.len == 3 and
        std.mem.eql(u8, external.path[0], "core") and
        std.mem.eql(u8, external.path[1], "slice") and
        std.mem.eql(u8, external.path[2], carrier);
}

fn expectU8(ty: types.Type) !void {
    if (ty != .prim) return error.NotAPrim;
    if (ty.prim != .u8) return error.NotU8;
}

/// Assert `ty` is the chunked slice itself — `&[T]` or the bare `[]const T`
/// a materialised chain carries — and that its element is `T`. The borrow is
/// what Rust says `Chunks::Item` is; where the borrow is the whole value, the
/// IR spells the same slice without it.
fn expectChunkSliceOfU8(ty: types.Type) !void {
    const pointee = switch (ty) {
        .reference => |reference| reference.pointee,
        else => ty,
    };
    const slice = switch (pointee) {
        .slice => |value| value,
        else => return error.ItemIsNotAChunkSlice,
    };
    try expectU8(slice.elem);
}

test "src.chunks(n).map(..).collect() is one chain rooted at the chunk call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn mapped(src: &[u8]) -> Vec<u8> {
        \\    src.chunks(2).map(|pair| pair[0]).collect()
        \\}
    );

    const chain = try expectChain(&model, "chunks", &.{"map"}, .collect_vec);
    // The source is the `chunks(2)` call lowered whole, not the bare slice the
    // call would otherwise be reduced to.
    const source_call = switch (model.bodies.exprs[chain.source].kind) {
        .method_call => |call| call,
        else => return error.SourceIsNotACall,
    };
    if (source_call.args.len != 1) return error.WrongChunkArity;
}

test "a chunked chain is typed Chunks<u8> and collects a u8 element" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn mapped(src: &[u8]) -> Vec<u8> {
        \\    src.chunks(2).map(|pair| pair[0]).collect()
        \\}
    );

    const chain_id = onlyChain(&model) orelse return error.NoIteratorChain;
    const chain = model.bodies.exprs[chain_id].kind.iterator_chain;

    // The chunk call carries the `core::slice::Chunks<u8>` carrier the backend
    // maps onto `r2z.chunks`.
    const source_type_id = model.bodies.exprs[chain.source].ty orelse
        return error.UntypedSource;
    const carrier = chunkCarrierId(&model, "Chunks") orelse return error.NoChunksCarrier;
    if (source_type_id != carrier) return error.SourceNotTheCarrier;
    try expectU8(try carrierElement(&model, carrier));

    // `pair` is the chunked slice, so `pair[0]` is a `u8` — never the chunk's
    // own `[u8; 2]`, and never the slice's `u8` without the borrow.
    const map = chain.adapters[0].map;
    if (map.closure.params.len != 1) return error.WrongParamCount;
    const parameter = model.bodies.pats[map.closure.params[0]];
    const binding = switch (parameter.kind) {
        .binding => |value| value,
        else => return error.ParamIsNotABinding,
    };
    _ = binding;
    const reference = switch (typeAt(&model, parameter.ty orelse return error.UntypedParam)) {
        .reference => |value| value,
        else => return error.ParamIsNotAReference,
    };
    const chunk_slice = switch (reference.pointee) {
        .slice => |value| value,
        else => return error.ParamIsNotASliceReference,
    };
    try expectU8(chunk_slice.elem);

    // The collected vector holds the mapped element: `Vec<u8>`, not
    // `Vec<[u8; 2]>` and not `Vec<&[u8]>`.
    const vector = switch (typeAt(&model, model.bodies.exprs[chain_id].ty orelse
        return error.UntypedChain)) {
        .external_nominal => |external| external,
        else => return error.ChainIsNotANominal,
    };
    if (vector.path.len != 3) return error.ChainIsNotAVec;
    if (!std.mem.eql(u8, vector.path[2], "Vec")) return error.ChainIsNotAVec;
    try expectU8(vector.args[0]);
}

test "chunks_exact(n) is chain vocabulary too, under its own carrier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn exact(src: &[u8]) -> Vec<u8> {
        \\    src.chunks_exact(4).filter(|pair| pair.len() == 4).collect()
        \\}
    );

    const chain = try expectChain(&model, "chunks_exact", &.{"filter"}, .collect_vec);
    const carrier = chunkCarrierId(&model, "ChunksExact") orelse
        return error.NoChunksExactCarrier;
    try expectU8(try carrierElement(&model, carrier));
    const source_type_id = model.bodies.exprs[chain.source].ty orelse
        return error.UntypedSource;
    if (source_type_id != carrier) return error.SourceNotTheCarrier;
    // `chunks_exact` must not be answered with the `chunks` carrier: the two
    // drive different runtime adapters.
    if (chunkCarrierId(&model, "Chunks") != null) return error.ChunksCarrierPresent;
}

test "enumerate after chunks widens the element to a (usize, &[u8]) tuple" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn pairs(src: &[u8]) -> Vec<(usize, &[u8])> {
        \\    src.chunks(2).enumerate().collect()
        \\}
    );

    _ = try expectChain(&model, "chunks", &.{"enumerate"}, .collect_vec);
    const chain_id = onlyChain(&model) orelse return error.NoIteratorChain;
    const vector = switch (typeAt(&model, model.bodies.exprs[chain_id].ty orelse
        return error.UntypedChain)) {
        .external_nominal => |external| external,
        else => return error.ChainIsNotANominal,
    };
    const tuple = switch (vector.args[0]) {
        .tuple => |value| value,
        else => return error.ElementIsNotATuple,
    };
    if (tuple.len != 2) return error.TupleArity;
    if (tuple[0] != .prim or tuple[0].prim != .usize) return error.IndexNotUsize;
    try expectChunkSliceOfU8(tuple[1]);
}

test "a `let` bound from a byte-sequence AsRef borrow is a chain source" {
    // `T: AsRef<[u8]>` is the only statement in the source that the borrow is a
    // byte sequence, and the pass that reads that bound runs after this
    // lowering — so the chain root is recognised from the bound itself.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn borrowed<T: AsRef<[u8]>>(source: T) -> Vec<u8> {
        \\    let bytes = source.as_ref();
        \\    bytes.chunks(2).map(|pair| pair[0]).collect()
        \\}
    );

    const chain_id = onlyChain(&model) orelse return error.NoIteratorChain;
    const chain = model.bodies.exprs[chain_id].kind.iterator_chain;
    if (chain.terminal != .collect_vec) return error.WrongTerminal;
    // The source is the `chunks(2)` call on the borrowed local, and the borrow
    // is still in the table as the call's receiver.
    const source_call = switch (model.bodies.exprs[chain.source].kind) {
        .method_call => |call| call,
        else => return error.SourceIsNotACall,
    };
    const receiver = switch (model.bodies.exprs[source_call.receiver].kind) {
        .path => |path| path,
        else => return error.ReceiverIsNotTheBinding,
    };
    const name = model.graph.symbol_table.get(receiver.def) orelse
        return error.MissingBinding;
    if (!std.mem.eql(u8, name.name, "bytes")) return error.WrongBinding;
}

test "a borrow from a bound that is not a byte sequence stays refused" {
    // `AsRef<str>` is a different borrow. Admitting it would emit a chunk loop
    // over something that is not a slice, so no chain may form.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn borrowed<T: AsRef<str>>(source: T) -> Vec<u8> {
        \\    let text = source.as_ref();
        \\    text.iter().copied().collect()
        \\}
    );

    if (onlyChain(&model) != null) return error.UnexpectedIteratorChain;
}

test "windows(n) is not chain vocabulary: no method lowering reaches it" {
    // `r2z.windows` exists, but nothing lowers a receiver's `.windows(n)` call
    // — it is refused long before a chain could root at it. Admitting the name
    // would promise a runtime adapter the backend never emits.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn windowed(src: &[u8]) -> Vec<u8> {
        \\    src.windows(2).map(|pair| pair[0]).collect()
        \\}
    );

    if (onlyChain(&model) != null) return error.UnexpectedIteratorChain;
    // The call is refused before it can root anything, so nothing about the
    // receiver reaches the chain vocabulary at all.
}

// ── Range loops, generic associated calls, and slice `.rev()` ────────────────

/// The single `for` loop in the snippet, or null — null both for "no loop" and
/// for "more than one", so a snippet that fragments cannot pass by accident.
fn onlyFor(model: *const ir.RustIr) ?exprs.NodeId {
    var found: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        if (expression.kind != .for_) continue;
        if (found != null) return null;
        found = @intCast(index);
    }
    return found;
}

/// The snippet's one `for` loop, with the range its iterable carries. A `for`
/// whose iterable is not a `.range` node is the shape `validateIterKind`
/// refuses outright, so this is where a range loop either is or is not: the
/// bound alone is not the loop, and a loop spelled over the END expression
/// instead of the range it belongs to is a different and wrong thing.
fn forRange(model: *const ir.RustIr) !exprs.RangeExpr {
    const loop_id = onlyFor(model) orelse return error.NoForLoop;
    const iterable = model.bodies.exprs[loop_id].kind.for_.iterable;
    return switch (model.bodies.exprs[iterable].kind) {
        .range => |value| value,
        else => error.IterableIsNotARange,
    };
}

/// The end node of a bounded range. Iteration needs one; `..` has none, and a
/// loop over that has no bound to read.
fn rangeEnd(range: exprs.RangeExpr) !exprs.NodeId {
    return range.end orelse error.OpenEndedRange;
}

/// The value of an integer-literal expression node, or null.
fn intLiteral(model: *const ir.RustIr, node: exprs.NodeId) ?i128 {
    if (node >= model.bodies.exprs.len) return null;
    const literal = switch (model.bodies.exprs[node].kind) {
        .literal => |value| value,
        else => return null,
    };
    return switch (literal) {
        .int => |value| value.value,
        else => null,
    };
}

test "a `for` over `0..4` iterates the range node, not its end bound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sum() -> usize {
        \\    let mut total = 0;
        \\    for i in 0..4 {
        \\        total += i;
        \\    }
        \\    total
        \\}
    );

    // A `for` whose iterable is the bare end bound validates as nothing at all,
    // so this is the assertion that fails when the loop stops carrying a range.
    try ir.validateForTranslation(&model);

    const range = try forRange(&model);
    if (range.inclusive) return error.HalfOpenByDefault;
    if ((intLiteral(&model, range.start) orelse return error.StartIsNotALiteral) != 0) return error.WrongStart;
    if ((intLiteral(&model, try rangeEnd(range)) orelse return error.EndIsNotALiteral) != 4) return error.WrongEnd;
}

test "a `for` over `0..N` keeps a const bound as the range end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub const N: usize = 5;
        \\pub fn sum() -> usize {
        \\    let mut total = 0;
        \\    for i in 0..N {
        \\        total += i;
        \\    }
        \\    total
        \\}
    );

    try ir.validateForTranslation(&model);

    const range = try forRange(&model);
    if ((intLiteral(&model, range.start) orelse return error.StartIsNotALiteral) != 0) return error.WrongStart;
    // The bound is the `const N` item, not an inlined `5`: Rust evaluates it at
    // the use site and so must the loop.
    const end = switch (model.bodies.exprs[try rangeEnd(range)].kind) {
        .path => |path| path,
        else => return error.EndIsNotTheConstBinding,
    };
    const name = model.graph.symbol_table.get(end.def) orelse return error.MissingConst;
    if (!std.mem.eql(u8, name.name, "N")) return error.WrongBinding;
}

test "a `for` over `0..n` keeps a parameter bound as the range end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sum(n: usize) -> usize {
        \\    let mut total = 0;
        \\    for i in 0..n {
        \\        total += i;
        \\    }
        \\    total
        \\}
    );

    try ir.validateForTranslation(&model);

    const range = try forRange(&model);
    if ((intLiteral(&model, range.start) orelse return error.StartIsNotALiteral) != 0) return error.WrongStart;
    const end = switch (model.bodies.exprs[try rangeEnd(range)].kind) {
        .path => |path| path,
        else => return error.EndIsNotTheParameter,
    };
    const name = model.graph.symbol_table.get(end.def) orelse return error.MissingParameter;
    if (!std.mem.eql(u8, name.name, "n")) return error.WrongBinding;
}

test "`I::method()` on a generic parameter binds the trait method its bound declares" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub trait Zero {
        \\    fn zero() -> Self;
        \\}
        \\impl Zero for u8 {
        \\    fn zero() -> u8 { 0 }
        \\}
        \\pub fn f<I: Zero>() -> I {
        \\    I::zero()
        \\}
    );

    try ir.validateForTranslation(&model);

    var bound: ?exprs.DefId = null;
    for (model.bodies.exprs) |expression| {
        const call = switch (expression.kind) {
            .call => |value| value,
            else => continue,
        };
        bound = switch (call.call_kind) {
            .associated => |id| id,
            else => return error.NotAnAssociatedCall,
        };
    }
    const method_id = bound orelse return error.NoCall;
    const method = model.graph.symbol_table.get(method_id) orelse return error.MissingMethod;
    // A generic parameter names no impl, so the callee is the trait's own
    // method reference — the shape monomorphization binds per instantiation.
    if (method.kind != .method_ref) return error.NotATraitMethodRef;
    if (!std.mem.eql(u8, method.name, "zero")) return error.WrongMethod;
    const owner = method.parent orelse return error.NoOwningTrait;
    const trait_entity = model.graph.symbol_table.get(owner) orelse return error.MissingTrait;
    if (trait_entity.kind != .trait_) return error.OwnerIsNotATrait;
    if (!std.mem.eql(u8, trait_entity.name, "Zero")) return error.WrongTrait;
}

test "two bounds declaring the same method leave `I::method()` refused" {
    // Rust resolves this by inference on `I`; this frontend does not spell the
    // inference, and guessing one trait would emit the wrong callee.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub trait A { fn m() -> Self; }
        \\pub trait B { fn m() -> Self; }
        \\pub fn f<I: A + B>() -> I {
        \\    I::m()
        \\}
    );

    var refused = false;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .unsupported) refused = true;
    }
    if (!refused) return error.AmbiguousBoundWasGuessed;
}

test "a qualified supertrait method resolves in the trait that declares it" {
    // `private::Sealed` is written inside `Integer`, so `private` is a module
    // relative to THAT trait. Taking the path's leaf name and resolving it in
    // the caller's scope instead finds the shadowing `Sealed` imported there,
    // which declares no `twice` at all — so the bound looks like it provides
    // nothing and the call is refused.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\mod private {
        \\    pub trait Sealed { fn twice(self) -> u32; }
        \\}
        \\pub trait Sealed { fn other(self) -> u32; }
        \\pub trait Integer: private::Sealed {}
        \\pub mod caller {
        \\    use crate::Integer;
        \\    use crate::Sealed;
        \\    pub fn run<I: Integer>(v: I) -> u32 { I::twice(v) }
        \\}
    );

    var bound: ?exprs.DefId = null;
    for (model.bodies.exprs) |expression| {
        const call = switch (expression.kind) {
            .call => |value| value,
            else => continue,
        };
        bound = switch (call.call_kind) {
            .associated => |id| id,
            else => return error.NotAnAssociatedCall,
        };
    }
    const method_id = bound orelse return error.NoCall;
    const method = model.graph.symbol_table.get(method_id) orelse return error.MissingMethod;
    if (method.kind != .method_ref) return error.NotATraitMethodRef;
    if (!std.mem.eql(u8, method.name, "twice")) return error.WrongMethod;
    const owner = method.parent orelse return error.NoOwningTrait;
    const trait_entity = model.graph.symbol_table.get(owner) orelse return error.MissingTrait;
    if (trait_entity.kind != .trait_) return error.OwnerIsNotATrait;
    // The declaring trait is the one the supertrait path named — the `Sealed`
    // inside `private` — not the shadow the caller has in scope, and not the
    // `Integer` that was written as the bound.
    const sealed_module = trait_entity.parent orelse return error.TraitHasNoModule;
    const module_entity = model.graph.symbol_table.get(sealed_module) orelse
        return error.MissingModule;
    if (module_entity.kind != .module) return error.OwningTraitIsNotNested;
    if (!std.mem.eql(u8, module_entity.name, "private")) return error.WrongDeclaringModule;
}

/// The snippet's one `for` iterable expression node.
fn forIterable(model: *const ir.RustIr) !exprs.NodeId {
    const loop_id = onlyFor(model) orelse return error.NoForLoop;
    return model.bodies.exprs[loop_id].kind.for_.iterable;
}

/// The reason string on an `.unsupported` expression node, or null.
fn unsupportedReason(model: *const ir.RustIr, node: exprs.NodeId) ?[]const u8 {
    if (node >= model.bodies.exprs.len) return null;
    return switch (model.bodies.exprs[node].kind) {
        .unsupported => |value| value.reason,
        else => null,
    };
}

test "`.rev()` over a slice-backed carrier is a method call, not a chain" {
    // `r2z.Rev` exists and `core::iter::Rev` is a carrier the backend drives
    // with `next`, so reversing a slice is an ordinary method call over the
    // source it reverses — and not a chain, which only has a direction
    // adapter for a RANGE.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sum(data: &[u32]) -> u32 {
        \\    let mut total = 0;
        \\    for &pair in data.chunks(2).rev() {
        \\        total += pair[0];
        \\    }
        \\    total
        \\}
    );

    const rev_call = switch (model.bodies.exprs[try forIterable(&model)].kind) {
        .method_call => |call| call,
        else => return error.IterableIsNotTheRevCall,
    };
    const rev_name = methodName(&model, rev_call.method) orelse return error.MissingMethod;
    if (!std.mem.eql(u8, rev_name, "rev")) return error.WrongMethod;
}

test "an inline `s.iter().rev()` loop is not refused as an iterator chain" {
    // The inline spelling is the one a real crate writes. This frontend does
    // not own what the method pass then decides, so what it does own is the
    // shape it hands over: the `.rev()` call itself. Refusing it here as a
    // chain would answer the wrong question — a `Rev` carrier over a slice is
    // not a chain this IR has an adapter for.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sum(data: &[u32]) -> u32 {
        \\    let mut total = 0;
        \\    for &i in data.iter().rev() {
        \\        total += i;
        \\    }
        \\    total
        \\}
    );

    const iterable = try forIterable(&model);
    if (unsupportedReason(&model, iterable)) |reason| {
        if (std.mem.eql(u8, reason, "iterator chain")) return error.RefusedAsAChain;
        return;
    }
    switch (model.bodies.exprs[iterable].kind) {
        .method_call => {},
        else => return error.IterableIsNotTheRevCall,
    }
}

test "`.rev()` over a range is still the chain direction adapter" {
    // The other half of the split: a Zig `for` walks a range directly, so
    // reversing one is a direction flag and not a `Rev` carrier.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sum() -> u32 {
        \\    let mut total = 0;
        \\    for i in (0..4).rev() {
        \\        total += i;
        \\    }
        \\    total
        \\}
    );

    const chain = switch (model.bodies.exprs[onlyFor(&model) orelse return error.NoForLoop].kind.for_.iter_kind) {
        .adapter => |value| value,
        else => return error.RangeRevIsNotAChain,
    };
    if (chain.adapters.len != 1) return error.WrongAdapterCount;
    if (!std.mem.eql(u8, adapterName(chain.adapters[0]), "range_rev")) return error.WrongAdapter;
    switch (model.bodies.exprs[chain.source].kind) {
        .range => {},
        else => return error.ChainSourceIsNotARange,
    }
}

// ── native-endian integer byte images ──────────────────────────────────────

/// The snippet's one core call, or null. Null for none and for more than one,
/// so a snippet that fragments cannot pass by accident.
fn onlyCoreCall(model: *const ir.RustIr) ?exprs.CoreCall {
    var found: ?exprs.CoreCall = null;
    for (model.bodies.exprs) |expression| {
        switch (expression.kind) {
            .core_call => |call| {
                if (found != null) return null;
                found = call;
            },
            else => {},
        }
    }
    return found;
}

/// The snippet's one array-literal expression node, or null.
fn onlyArrayLiteral(model: *const ir.RustIr) ?exprs.NodeId {
    var found: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        if (expression.kind != .array) continue;
        if (found != null) return null;
        found = @intCast(index);
    }
    return found;
}

fn expectPrim(ty: types.Type, primitive: types.Prim) !void {
    if (ty != .prim) return error.NotAPrim;
    if (ty.prim != primitive) return error.WrongPrim;
}

/// `[u8; length]` — the shape an integer's native-endian byte image takes.
fn expectByteArray(ty: types.Type, length: u64) !void {
    const array = switch (ty) {
        .array => |value| value,
        else => return error.NotAnArray,
    };
    try expectPrim(array.elem, .u8);
    switch (array.len) {
        .literal => |len| if (len != length) return error.WrongArrayLength,
        else => return error.ArrayLengthIsNotALiteral,
    }
}

test "`x.to_ne_bytes()` is the runtime transmute, not a method with nothing to dispatch to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn f(x: u32) -> [u8; 4] {
        \\    x.to_ne_bytes()
        \\}
    );

    // The byte image of an integer is an ARRAY, so no entry in the numeric
    // dispatch table names it and the call used to reach the backend as an
    // `.unsupported` marker. Validation is where that refusal surfaces, so
    // this assertion is the one that fails without the fix.
    try ir.validateForTranslation(&model);

    const call = onlyCoreCall(&model) orelse return error.NoCoreCall;
    if (call.function != .mem_transmute) return error.NotANativeEndianTransmute;
    if (call.args.len != 1) return error.WrongTransmuteArity;
    try expectPrim(call.generic_args[0], .u32);
    try expectByteArray(call.generic_args[1], 4);
}

test "`u16::from_ne_bytes(..)` is the same transmute read back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn f(bytes: [u8; 2]) -> u16 {
        \\    u16::from_ne_bytes(bytes)
        \\}
    );

    try ir.validateForTranslation(&model);

    // The bytes are the parameter and the integer the result: the inverse of
    // `to_ne_bytes`, and the order the runtime reads them in.
    const call = onlyCoreCall(&model) orelse return error.NoCoreCall;
    if (call.function != .mem_transmute) return error.NotANativeEndianTransmute;
    if (call.args.len != 1) return error.WrongTransmuteArity;
    try expectByteArray(call.generic_args[0], 2);
    try expectPrim(call.generic_args[1], .u16);
}

test "a local bound to a core call types the array literal indexed out of it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Spelled with `core::mem::transmute` rather than `to_ne_bytes`, so this
    // pins the core-call result type on its own and not through the method
    // above. A local bound to a call has no annotation to read, and the array
    // literal is an argument rather than a `let` initialiser precisely so
    // that no annotation reaches it either: without the core-call answer
    // `[b[0], b[1]]` has no element type, and the Zig AST can only emit a
    // multi-element array literal with a named one.
    const model = try analyze(alloc,
        \\pub fn f(x: u32) -> u16 {
        \\    let b = core::mem::transmute::<u32, [u8; 4]>(x);
        \\    core::mem::transmute::<[u8; 2], u16>([b[0], b[1]])
        \\}
    );

    const literal = onlyArrayLiteral(&model) orelse return error.NoArrayLiteral;
    const literal_type = model.bodies.exprs[literal].ty orelse
        return error.ArrayLiteralHasNoType;
    if (literal_type >= model.bodies.types.len) return error.MissingTypeId;
    try expectByteArray(typeAt(&model, literal_type), 2);
}

// ── Tuple type rows: a slot the source names stands, a slot it leaves open is
// ── named by the constraints around it ─────────────────────────────────────

/// The one tuple literal the snippet produced. A Rust tuple lowers to an array
/// expression with no repeat and a `.tuple` type, so a `[..]` literal — which
/// carries an `.array` type — cannot match one by accident.
fn onlyTupleLiteral(model: *const ir.RustIr) !exprs.NodeId {
    var found: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        const literal = switch (expression.kind) {
            .array => |array| array,
            else => continue,
        };
        if (literal.repeat != null) continue;
        const type_id = expression.ty orelse continue;
        if (typeAt(model, type_id) != .tuple) continue;
        if (found != null) return error.MoreThanOneTupleLiteral;
        found = @intCast(index);
    }
    return found orelse error.NoTupleLiteral;
}

/// A lexical type parameter: one path segment naming the parameter with no
/// entity behind it, which is how `I` is spelled inside its own function.
fn isLexicalParam(ty: types.Type, name: []const u8) bool {
    const path = switch (ty) {
        .path => |value| value,
        else => return false,
    };
    return path.segments.len == 1 and path.segments[0].id == null and
        std.mem.eql(u8, path.segments[0].name, name);
}

/// A nominal for a declaration this crate wrote: one path segment carrying
/// the entity behind it, which is how a source-written type name is spelled
/// once the extractor has resolved it.
fn isEnumPathNamed(ty: types.Type, name: []const u8) bool {
    const path = switch (ty) {
        .path => |value| value,
        else => return false,
    };
    if (path.segments.len == 0) return false;
    const last = path.segments[path.segments.len - 1];
    return last.id != null and std.mem.eql(u8, last.name, name);
}

/// Whether a type still stands for something no constraint has named: a
/// refusal, or an inference placeholder. Either one is an open slot, and an
/// open slot is not a type a reader can act on.
fn isOpenType(ty: types.Type) bool {
    return switch (ty) {
        .unsupported => true,
        .external_nominal => |external| blk: {
            if (external.path.len > 0 and
                std.mem.eql(u8, external.path[external.path.len - 1], "_")) break :blk true;
            for (external.args) |argument| {
                if (isOpenType(argument)) break :blk true;
            }
            break :blk false;
        },
        .path => |path| path.segments.len > 0 and
            std.mem.eql(u8, path.segments[path.segments.len - 1].name, "_"),
        .tuple => |elements| blk: {
            for (elements) |element| {
                if (isOpenType(element)) break :blk true;
            }
            break :blk false;
        },
        .reference => |reference| isOpenType(reference.pointee),
        .raw_ptr => |raw_ptr| isOpenType(raw_ptr.pointee),
        .slice => |slice| isOpenType(slice.elem),
        .array => |array| isOpenType(array.elem),
        .option => |inner| isOpenType(inner.*),
        .result => |result| isOpenType(result.ok) or isOpenType(result.err),
        .boxed => |inner| isOpenType(inner.*),
        else => false,
    };
}

/// An `.unsupported` node whose reason is `assertion:<node id>` records an
/// `assert!` / `assert_eq!` the source actually wrote, not a refusal: the
/// canonical validator admits exactly that shape (`validateAssertionMarker`)
/// and refuses every other reason. Counting an assertion as an open marker
/// would report every crate that asserts anything as unfinished.
fn isAssertionMarker(reason: []const u8) bool {
    const prefix = "assertion:";
    if (!std.mem.startsWith(u8, reason, prefix)) return false;
    const suffix = reason[prefix.len..];
    if (suffix.len == 0) return false;
    for (suffix) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
}

/// Nothing left open anywhere. Every row in the type table is validated
/// whether or not an expression still points at it, so a slot nobody ever
/// solved is a hole in the whole crate and not only in the literal that owned
/// it.
///
/// A refusal is NAMED by its recorded reason: `error.RefusalMarkerLeftInBody`
/// on its own says only that some node was refused, and these fixtures are
/// whole crates, so a test that needs the reason asserts it off the
/// expression table itself. This helper never prints — the diagnostic print
/// that lived here was removed with the one in `expectTranslatable`.
fn expectNothingLeftOpen(model: *const ir.RustIr) !void {
    for (model.bodies.exprs) |expression| {
        switch (expression.kind) {
            .unsupported => |value| if (!isAssertionMarker(value.reason)) {
                return error.RefusalMarkerLeftInBody;
            },
            else => {},
        }
    }
    for (model.bodies.types) |ty| {
        if (isOpenType(ty)) return error.OpenSlotLeftInTypeTable;
    }
}

test "a matches macro lowers enum tuple-struct patterns to a source match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // `matches!(value, Shape::Circle(_))` is `match value { Shape::Circle(_)
    // => true, _ => false }`: the tuple-struct alternative reaches the same
    // `struct_pat` the source `match` lowering emits, whose def is the
    // variant the source names — not a text guess at it.
    const model = try analyze(arena_state.allocator(),
        \\enum Shape { Circle(i32), Square(i32), Dot }
        \\pub fn is_round(shape: Shape) -> bool { matches!(shape, Shape::Circle(_) | Shape::Square(_)) }
    );

    try expectTranslatable(&model);
    try expectNothingLeftOpen(&model);

    var matches: usize = 0;
    for (model.bodies.exprs) |expression| {
        const arms = switch (expression.kind) {
            .match => |value| value,
            else => continue,
        };
        if (arms.arms.len != 2) return error.MatchesArmsAreNotTwo;
        if (arms.arms[0].patterns.len != 2) return error.MatchesFirstArmIsNotTwoPatterns;
        for (arms.arms[0].patterns) |pattern_id| {
            const pattern = model.bodies.pats[pattern_id];
            const tuple_struct = switch (pattern.kind) {
                .struct_pat => |value| value,
                else => return error.MatchesAlternativeIsNotTupleStruct,
            };
            const variant = model.graph.symbol_table.get(tuple_struct.def) orelse
                return error.MatchesVariantHasNoEntity;
            if (variant.kind != .variant) return error.MatchesDefIsNotVariant;
        }
        for ([_]exprs.NodeId{ arms.arms[0].body, arms.arms[1].body }) |body_id| {
            const body = model.bodies.exprs[body_id];
            const literal = switch (body.kind) {
                .literal => |value| value,
                else => return error.MatchesBodyIsNotLiteral,
            };
            if (literal != .boolean) return error.MatchesBodyIsNotBoolean;
        }
        const miss_pattern = model.bodies.pats[arms.arms[1].patterns[0]];
        if (miss_pattern.kind != .wildcard) return error.MatchesMissArmIsNotWildcard;
        matches += 1;
    }
    try testing.expectEqual(@as(usize, 1), matches);
}

test "a qualified matches macro reaches the same lowering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const model = try analyze(arena_state.allocator(),
        \\enum Shape { Circle(i32), Square(i32), Dot }
        \\pub fn is_round(shape: Shape) -> bool { core::matches!(shape, Shape::Circle(_)) }
    );

    try expectTranslatable(&model);
    try expectNothingLeftOpen(&model);

    var matches: usize = 0;
    for (model.bodies.exprs) |expression| {
        const arms = switch (expression.kind) {
            .match => |value| value,
            else => continue,
        };
        if (arms.arms.len != 2) return error.MatchesArmsAreNotTwo;
        if (arms.arms[0].patterns.len != 1) return error.MatchesFirstArmIsNotOnePattern;
        const pattern = model.bodies.pats[arms.arms[0].patterns[0]];
        const tuple_struct = switch (pattern.kind) {
            .struct_pat => |value| value,
            else => return error.MatchesAlternativeIsNotTupleStruct,
        };
        const variant = model.graph.symbol_table.get(tuple_struct.def) orelse
            return error.MatchesVariantHasNoEntity;
        if (variant.kind != .variant) return error.MatchesDefIsNotVariant;
        try testing.expectEqualStrings("Circle", variant.name);
        matches += 1;
    }
    try testing.expectEqual(@as(usize, 1), matches);
}

test "a tuple tail of a parameter and a bare literal keeps `(I, usize)`" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn pair<I>(x: I) -> (I, usize) { (x, 0) }
    );

    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const literal = try onlyTupleLiteral(&model);
    const literal_type = model.bodies.exprs[literal].ty orelse return error.UntypedTupleLiteral;
    const elements = switch (typeAt(&model, literal_type)) {
        .tuple => |value| value,
        else => return error.TupleLiteralIsNotATuple,
    };
    if (elements.len != 2) return error.TupleArity;
    // `x` names the parameter and is that slot's identity; `0` names nothing,
    // and the declared return is what settles it. Naming the open slot must not
    // disturb the slot the source already named.
    if (!isLexicalParam(elements[0], "I")) return error.GenericSlotWasOverwritten;
    if (elements[1] != .prim or elements[1].prim != .usize) return error.LiteralSlotIsNotUsize;
}

/// The one tuple literal whose first slot is a tuple of its own — the nested
/// row, as opposed to the closure's tuple beside it.
fn onlyNestedTupleLiteral(model: *const ir.RustIr) !exprs.NodeId {
    var found: ?exprs.NodeId = null;
    for (model.bodies.exprs, 0..) |expression, index| {
        const literal = switch (expression.kind) {
            .array => |array| array,
            else => continue,
        };
        if (literal.repeat != null) continue;
        const type_id = expression.ty orelse continue;
        const elements = switch (typeAt(model, type_id)) {
            .tuple => |value| value,
            else => continue,
        };
        if (elements.len == 0 or elements[0] != .tuple) continue;
        if (found != null) return error.MoreThanOneNestedTupleLiteral;
        found = @intCast(index);
    }
    return found orelse error.NoNestedTupleLiteral;
}

test "a nested tuple and a closure tuple leave no slot open" {
    // The shapes that actually reach a hole: a tuple inside a tuple, and a
    // tuple a closure returns, each holding a bare integer literal that only
    // the position around it can name.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn nest(x: u8, n: usize) -> ((u8, usize), usize) {
        \\    ((x, 0), n)
        \\}
        \\pub fn pairs(src: &[u8]) -> Vec<(u8, usize)> {
        \\    src.chunks(2).map(|chunk| (chunk[0], 0)).collect()
        \\}
    );

    try expectNothingLeftOpen(&model);

    // The nested row keeps the shape the source wrote: the inner tuple in the
    // slot that position filled, and the literal slot the declared return
    // settles.
    const literal = try onlyNestedTupleLiteral(&model);
    const elements = switch (typeAt(&model, model.bodies.exprs[literal].ty orelse
        return error.UntypedTupleLiteral)) {
        .tuple => |value| value,
        else => return error.TupleLiteralIsNotATuple,
    };
    if (elements.len != 2) return error.TupleArity;
    const inner = switch (elements[0]) {
        .tuple => |value| value,
        else => return error.NestedSlotIsNotATuple,
    };
    if (inner.len != 2) return error.TupleArity;
    if (inner[0] != .prim or inner[0].prim != .u8) return error.NestedFirstSlotIsNotU8;
    if (inner[1] != .prim or inner[1].prim != .usize) return error.NestedSecondSlotIsNotUsize;
    if (elements[1] != .prim or elements[1].prim != .usize) return error.LiteralSlotIsNotUsize;
}

test "a byte string in a tuple row names its own bytes" {
    // `b"..."` is `&'static [u8; N]`: the element is a byte and the length is
    // the number of bytes written, so a tuple slot holding one is a decision
    // the source made rather than a question. Answering null for the literal
    // left the row's slot as the inference placeholder, and a row is what
    // `validate` reads whether or not an expression still points at it — so
    // the crate was refused for a slot no constraint was ever going to fill.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const model = try analyze(arena_state.allocator(),
        \\pub fn pair() { let both = (b"kiwi", b"pear"); }
    );

    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const literal = try onlyTupleLiteral(&model);
    const elements = switch (typeAt(&model, model.bodies.exprs[literal].ty orelse
        return error.UntypedTupleLiteral)) {
        .tuple => |value| value,
        else => return error.TupleLiteralIsNotATuple,
    };
    if (elements.len != 2) return error.TupleArity;
    for (elements) |slot| {
        const reference = switch (slot) {
            .reference => |value| value,
            else => return error.ByteStringSlotIsNotABorrow,
        };
        if (reference.mut) return error.ByteStringSlotIsMutable;
        try expectByteArray(reference.pointee, 4);
    }
}

test "an enum constructor in a tuple row is decided before inference runs" {
    // `(Sign::Plus, 0)`. `Sign::Plus` IS a `Sign` in the source, before any
    // constraint runs and with nothing left to ask. `knownCastOperandType` has
    // no arm for a variant at all, so extraction-time asked it, was told
    // nothing, and `attachKnownTupleType` wrote `unattributedType` — the `_`
    // placeholder — into that slot: a hole in a row the source had fully
    // determined. `refineSourceTupleRow` cannot repair it, because it writes
    // only what the solver already decided FOR THE ELEMENT, and the element
    // here is a constructor the walk names nowhere else. A row is what
    // `validate` reads whether or not an expression still points at it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const model = try analyze(arena_state.allocator(),
        \\pub enum Sign { Plus, Minus }
        \\pub fn pair() -> (Sign, usize) { (Sign::Plus, 0) }
    );

    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const literal = try onlyTupleLiteral(&model);
    const elements = switch (typeAt(&model, model.bodies.exprs[literal].ty orelse
        return error.UntypedTupleLiteral)) {
        .tuple => |value| value,
        else => return error.TupleLiteralIsNotATuple,
    };
    if (elements.len != 2) return error.TupleArity;
    // The slot the source decided is a decision and reads as one; the slot it
    // left open is the declared return's to settle, and is not this hole.
    if (isOpenType(elements[0])) return error.ConstructorSlotLeftOpen;
    if (!isEnumPathNamed(elements[0], "Sign")) return error.ConstructorSlotIsNotSign;
    if (elements[1] != .prim or elements[1].prim != .usize) return error.LiteralSlotIsNotUsize;
}

test "a blanket impl method is typed by the receiver the call site writes" {
    // `impl<I> FromRadix10Checked for I { fn from_radix_10_checked(_: &[u8]) -> (Option<I>, usize) }`
    // declares no type parameter of its own, so the `u8` in
    // `u8::from_radix_10_checked(b"256")` is a RECEIVER and not a type
    // argument list, while the declared return names the impl's own `I`. The
    // callee cannot settle `I` and the call site was the only place that ever
    // could, so the call node carried no type at all. Nothing downstream
    // recovered it: the comparison beside it had no concrete peer to ask, so
    // the `(None, 3)` row that comparison exists to type kept the `_`
    // placeholder in its first slot, and `validate` refused the crate as
    // `IncompleteGenericMetadata` — for a slot the source had determined.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const model = try analyze(arena_state.allocator(),
        \\trait FromRadix10Checked { fn from_radix_10_checked(_: &[u8]) -> (Option<Self>, usize); }
        \\impl<I> FromRadix10Checked for I {
        \\    fn from_radix_10_checked(_: &[u8]) -> (Option<I>, usize) { (None, 0) }
        \\}
        \\pub fn checked() -> bool { (None, 3) == u8::from_radix_10_checked(b"256") }
    );

    try expectTranslatable(&model);
    try expectNothingLeftOpen(&model);

    // The call answers with the receiver bound to the impl's parameter: the
    // tuple `assert_eq!((None, 3), ..)` compares against, over `u8`.
    var calls: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .call) continue;
        const type_id = expression.ty orelse return error.UntypedBlanketCall;
        const row = typeAt(&model, type_id);
        if (isOpenType(row)) return error.BlanketCallCarriesAPlaceholder;
        const elements = switch (row) {
            .tuple => |value| value,
            else => return error.BlanketCallIsNotATuple,
        };
        if (elements.len != 2) return error.BlanketCallTupleArity;
        const option = switch (elements[0]) {
            .option => |value| value,
            else => return error.BlanketCallFirstSlotIsNotAnOption,
        };
        if (!(option.* == .prim and option.*.prim == .u8)) return error.BlanketCallOptionIsNotU8;
        if (elements[1] != .prim or elements[1].prim != .usize) {
            return error.BlanketCallOffsetIsNotUsize;
        }
        calls += 1;
    }
    // One call in the snippet, and a zero would let this pass without ever
    // asking the question the receiver exists to answer.
    try testing.expectEqual(@as(usize, 1), calls);
}

/// Every tuple literal the snippet produced, in source order, up to `out.len`.
/// `onlyTupleLiteral` refuses a second literal outright, which is the right
/// shape for a snippet that has one; this snippet has two and the whole point
/// is that they answer to different positions.
fn tupleLiterals(model: *const ir.RustIr, out: []exprs.NodeId) !usize {
    var count: usize = 0;
    for (model.bodies.exprs, 0..) |expression, index| {
        const literal = switch (expression.kind) {
            .array => |array| array,
            else => continue,
        };
        if (literal.repeat != null) continue;
        const type_id = expression.ty orelse continue;
        if (typeAt(model, type_id) != .tuple) continue;
        if (count == out.len) return error.TooManyTupleLiterals;
        out[count] = @intCast(index);
        count += 1;
    }
    return count;
}

test "each tuple literal keeps the element type its own projection names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Two `let`-bound tuples whose first slots name nothing at all: `(7, true)`
    // and `(9, false)` write no type for the integer, and the only thing in the
    // source that names one is the projection that reads it — a parameter
    // declared `u8` here and `i64` there. So the demand reaches the literal
    // through `first.0` / `second.0` and through nothing else, which is the
    // shape the declared-return tests above cannot reach: those name the whole
    // literal, these name one slot each.
    const model = try analyze(alloc,
        \\fn u8_id(v: u8) -> u8 { v }
        \\fn i64_id(v: i64) -> i64 { v }
        \\pub fn run() -> bool {
        \\    let first = (7, true);
        \\    let second = (9, false);
        \\    u8_id(first.0) == 7 && i64_id(second.0) == 9 && first.1 && !second.1
        \\}
    );

    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    var literals: [2]exprs.NodeId = undefined;
    if (try tupleLiterals(&model, &literals) != literals.len) return error.WrongTupleLiteralCount;
    const first_row = model.bodies.exprs[literals[0]].ty orelse
        return error.UntypedTupleLiteral;
    const second_row = model.bodies.exprs[literals[1]].ty orelse
        return error.UntypedTupleLiteral;
    // Partial rows are private to their literal. One row shared between them
    // would be a single answer standing in for two positions that disagree.
    if (first_row == second_row) return error.TupleRowsAreShared;

    const rows = [2]exprs.TypeId{ first_row, second_row };
    var leading: [2]?types.Prim = .{ null, null };
    for (rows, 0..) |row, index| {
        const elements = switch (typeAt(&model, row)) {
            .tuple => |value| value,
            else => return error.TupleLiteralIsNotATuple,
        };
        if (elements.len != 2) return error.TupleArity;
        if (elements[1] != .prim or elements[1].prim != .bool) return error.SecondSlotIsNotBool;
        leading[index] = switch (elements[0]) {
            .prim => |prim| prim,
            else => return error.FirstSlotIsNotPrim,
        };
    }
    // Each literal takes the answer of its OWN parameter, so the two first
    // slots differ and together they are exactly the pair the two signatures
    // declare. Either one answering for both is the coupling this guards.
    if (leading[0] == leading[1]) return error.IndependentLiteralsAreCoupled;
    const ordered = (leading[0] == .u8 and leading[1] == .i64) or
        (leading[0] == .i64 and leading[1] == .u8);
    if (!ordered) return error.ProjectedSlotHasWrongType;

    // The projections themselves carry what their position stated rather than
    // the hole their slot was written as, which is what the backend emits.
    for (model.bodies.exprs) |expression| {
        const field = switch (expression.kind) {
            .field => |value| value,
            else => continue,
        };
        _ = std.fmt.parseInt(usize, field.field, 10) catch continue;
        const type_id = expression.ty orelse return error.UntypedProjection;
        if (typeAt(&model, type_id) != .prim) return error.ProjectionIsNotAPrimitive;
    }
}

test "integer limits remain target expressions and cover the full u128 range" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn wide() -> u128 { u128::MAX }
        \\pub fn wide_old() -> u128 { u128::max_value() }
        \\pub fn pointer_max() -> usize { usize::MAX }
        \\pub fn signed_min() -> isize { isize::MIN }
        \\pub fn signed_max() -> isize { isize::max_value() }
        \\pub fn width() -> u32 { usize::BITS }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var target_widths: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .core_call and
            expression.kind.core_call.function == .mem_size_of) target_widths += 1;
    }
    try testing.expect(target_widths >= 3);
}

test "raw copy and slice ownership retain their element and allocation contracts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub unsafe fn copy(src: *const u16, dst: *mut u16, n: usize) {
        \\    src.copy_to_nonoverlapping(dst, n);
        \\}
        \\pub fn own(src: &[u16]) -> Vec<u16> { src.to_vec() }
        \\pub fn cow() -> std::borrow::Cow<'static, str> {
        \\    std::borrow::Cow::<str>::Owned(String::from("owned"))
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var copy_seen = false;
    var ownership_seen = false;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        const call = expression.kind.core_call;
        if (call.function == .ptr_copy_nonoverlapping) {
            try testing.expectEqual(@as(usize, 3), call.args.len);
            try testing.expectEqual(types.Prim.u16, call.generic_args[0].prim);
            copy_seen = true;
        }
        if (call.function == .convert_from and call.generic_args[0] == .external_nominal and
            std.mem.eql(u8, call.generic_args[0].external_nominal.path[2], "Vec"))
        {
            try testing.expectEqual(types.Prim.u16, call.generic_args[0].external_nominal.args[0].prim);
            ownership_seen = true;
        }
    }
    try testing.expect(copy_seen and ownership_seen);
}

test "Hasher UFCS preserves a source override instead of the native default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use std::hash::Hasher;
        \\pub struct Little { value: u64 }
        \\impl Hasher for Little {
        \\    fn finish(&self) -> u64 { self.value }
        \\    fn write(&mut self, bytes: &[u8]) { self.value = bytes[0] as u64; }
        \\    fn write_u16(&mut self, value: u16) { self.write(&value.to_le_bytes()); }
        \\}
        \\pub fn feed(h: &mut Little, value: u16) { Hasher::write_u16(h, value); }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var source_dispatch = false;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .core_call)
            try testing.expect(expression.kind.core_call.function != .hash_write_primitive);
        if (expression.kind != .call) continue;
        const call = expression.kind.call;
        if (call.call_kind != .associated) continue;
        const entity = model.graph.symbol_table.get(call.call_kind.associated) orelse continue;
        if (std.mem.eql(u8, entity.name, "write_u16")) source_dispatch = true;
    }
    try testing.expect(source_dispatch);
}

/// No `Hasher` write was lowered as the runtime's native primitive write. The
/// native path stamps a `.prim` on the payload, which is only true of the
/// `write_<primitive>` spellings; `write` carries a byte slice.
fn expectNoFabricatedPrimitiveWrite(model: *const ir.RustIr) !void {
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        try testing.expect(expression.kind.core_call.function != .hash_write_primitive);
    }
}

test "Hasher::write with no implementation in this crate is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use std::hash::Hasher;
        \\pub struct Bare { value: u64 }
        \\pub fn feed(h: &mut Bare, bytes: &[u8]) { Hasher::write(h, bytes); }
    );
    try expectOnlyRefusal(&model, "feed", "unresolved call");
    try expectNoFabricatedPrimitiveWrite(&model);
}

test "Hasher::write refuses a receiver whose write comes from a different trait" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use std::hash::Hasher;
        \\pub struct Sink { total: u64 }
        \\trait Digest { fn write(&mut self, bytes: &[u8]); }
        \\impl Digest for Sink {
        \\    fn write(&mut self, bytes: &[u8]) { self.total = bytes.len() as u64; }
        \\}
        \\pub fn feed(h: &mut Sink, bytes: &[u8]) { Hasher::write(h, bytes); }
    );
    // The receiver HAS a `write`, and it is not the standard one. The standard
    // owner proves the trait; the impl proves the receiver; a method that
    // satisfies neither is not a substitute for either.
    try expectOnlyRefusal(&model, "feed", "unresolved call");
    try expectNoFabricatedPrimitiveWrite(&model);
}

test "primitive associated local trait methods call the declared implementation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\trait Decimal { fn max_num_digits() -> usize; fn from_radix_10_checked(v: u8) -> Option<Self> where Self: Sized; }
        \\impl Decimal for u32 {
        \\    fn max_num_digits() -> usize { 10 }
        \\    fn from_radix_10_checked(v: u8) -> Option<Self> { Some(v as u32) }
        \\}
        \\pub fn digits() -> usize { u32::max_num_digits() }
        \\pub fn digit(v: u8) -> Option<u32> { u32::from_radix_10_checked(v) }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var associated_calls: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .call and expression.kind.call.call_kind == .associated)
            associated_calls += 1;
    }
    try testing.expectEqual(@as(usize, 2), associated_calls);
}

test "rand_core helper admission retains both mutable arguments and unit result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // A crate that depends on another crate is analysed through its manifest,
    // which is where the dependency edge lives. `graph.Crate.deps` is the one
    // table that says `rand_core` is an external root, and
    // `validateTraitPathContext` reads the root of an external trait bound
    // there; a bare source snippet carries no such row, so the fixture would
    // be refused for a reason the real pipeline never produces. The manifest
    // twin below asserts the same admission through a RENAMED dependency.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "rng-consumer"
        \\version = "0.1.0"
        \\edition = "2018"
        \\[lib]
        \\path = "lib.rs"
        \\[dependencies]
        \\rand_core = "0.5.1"
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.rs", .data =
        \\extern crate rand_core;
        \\use rand_core::impls;
        \\pub fn fill<R: rand_core::RngCore>(rng: &mut R, bytes: &mut [u8]) {
        \\    impls::fill_bytes_via_next(rng, bytes);
        \\}
    });
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const model = try pipeline.analyzeCrateWithOptions(alloc, std.testing.io, directory, .{});
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var found = false;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call or expression.kind.core_call.function != .rng_fill_bytes_via_next) continue;
        const call = expression.kind.core_call;
        try testing.expectEqual(@as(usize, 0), call.generic_args.len);
        try testing.expectEqual(@as(usize, 2), call.args.len);
        for (call.args) |argument| {
            const type_id = model.bodies.exprs[argument].ty orelse return error.UntypedFillArgument;
            const ty = typeAt(&model, type_id);
            try testing.expect((ty == .reference and ty.reference.mut) or (ty == .slice and !ty.slice.const_));
        }
        found = true;
    }
    try testing.expect(found);
}

test "num_traits integer limits preserve lexical I rather than choosing a host integer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // Analysed through a manifest for the same reason as the rand_core fixture
    // above: `I: num_traits::PrimInt` is an external trait bound, and the root
    // it names has to be a dependency the IR knows about.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "numeric-limits"
        \\version = "0.1.0"
        \\edition = "2018"
        \\[lib]
        \\path = "lib.rs"
        \\[dependencies]
        \\num-traits = "0.2.14"
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.rs", .data =
        \\extern crate num_traits;
        \\pub fn low<I: num_traits::PrimInt>() -> I { I::min_value() }
        \\pub fn high<I: num_traits::PrimInt>() -> I { I::max_value() }
        \\pub fn zero<I: num_traits::PrimInt>() -> I { I::zero() }
        \\pub fn one<I: num_traits::PrimInt>() -> I { I::one() }
    });
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const model = try pipeline.analyzeCrateWithOptions(alloc, std.testing.io, directory, .{});
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var limits: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        const call = expression.kind.core_call;
        if (call.function != .numeric_min_value and call.function != .numeric_max_value) continue;
        try testing.expect(isLexicalParam(call.generic_args[0], "I"));
        try testing.expect(isLexicalParam(typeAt(&model, expression.ty orelse return error.UntypedIntegerLimit), "I"));
        limits += 1;
    }
    try testing.expectEqual(@as(usize, 2), limits);
}

test "primitive blanket trait calls carry the primitive into the source impl" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\trait Integer { fn width() -> usize; }
        \\impl Integer for u32 { fn width() -> usize { 10 } }
        \\trait Decimal { fn max_num_digits() -> usize; }
        \\impl<I: Integer> Decimal for I {
        \\    fn max_num_digits() -> usize { I::width() }
        \\}
        \\pub fn digits() -> usize { u32::max_num_digits() }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var selected: usize = 0;
    var invented: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .call or expression.kind.call.call_kind != .associated) continue;
        const callee = model.graph.symbol_table.get(expression.kind.call.call_kind.associated) orelse
            return error.MissingBlanketCallee;
        if (!std.mem.eql(u8, callee.name, "max_num_digits")) continue;
        selected += 1;
        // The primitive selects the SOURCE impl, so the callee is the `fn` the
        // blanket `impl<I: Integer> Decimal for I` declares, and that impl is
        // the declaration carrying the one type parameter this call stands in
        // for.
        const owner = model.graph.symbol_table.get(callee.parent orelse return error.NoOwningImpl) orelse
            return error.MissingOwningImpl;
        if (owner.kind != .impl_) return error.CalleeIsNotInAnImpl;
        const impl_body = switch (model.bodies.bodies[owner.id]) {
            .impl_ => |value| value,
            else => return error.OwnerHasNoImplBody,
        };
        const trait_path = impl_body.trait_path orelse return error.NotATraitImpl;
        const trait_name = trait_path.segments[trait_path.segments.len - 1].name;
        if (!std.mem.eql(u8, trait_name, "Decimal")) return error.WrongImplTrait;
        const generics = impl_body.generics orelse return error.BlanketImplHasNoGenerics;
        if (generics.params.len != 1 or generics.params[0] != .type_ or
            !std.mem.eql(u8, generics.params[0].type_.name, "I"))
        {
            return error.WrongBlanketImplParameter;
        }
        // `Decimal` declares no type parameter of its own, so `Decimal<u32>` is
        // not a type this crate wrote. Recording the call as an instantiation of
        // it is exactly the `.generic_inst` over a zero-parameter declaration
        // `validateTypeContext` calls `IncompleteGenericMetadata`; the record
        // must leave the callee's own declaration carrying the primitive.
        if (expression.ty) |type_id| {
            if (typeAt(&model, type_id) == .generic_inst) invented += 1;
        }
    }
    if (selected != 1) return error.WrongBlanketCallCount;
    if (invented != 0) return error.InventedATraitInstantiation;
}

test "atoi consumer retains checked parsing and blanket primitive associated calls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `atoi`'s `Cargo.toml` declares `num-traits`, and the bounds that carry
    // the crate's numeric defaults are `I: Bounded + Zero + One + ..` through
    // that dependency. Analysed from its directory rather than from the bare
    // source for the reason the rand_core fixture records above.
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/atoi",
        .{ .include_tests = true },
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var numeric_defaults: usize = 0;
    var checked_parsing_seen = false;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (std.mem.eql(u8, entity.name, "checked_parsing")) checked_parsing_seen = true;
    }
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        switch (expression.kind.core_call.function) {
            .numeric_zero, .numeric_one, .numeric_min_value, .numeric_max_value => numeric_defaults += 1,
            else => {},
        }
    }
    try testing.expect(numeric_defaults > 0);
    try testing.expect(checked_parsing_seen);
}

test "rand_core manifest package rename resolves through the imported impls module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "renamed-rng-consumer"
        \\version = "0.1.0"
        \\edition = "2021"
        \\[lib]
        \\path = "lib.rs"
        \\[dependencies]
        \\rng-api = { package = "rand_core", version = "0.5.1" }
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.rs", .data =
        \\use rng_api::impls as helpers;
        \\pub fn fill<R: rng_api::RngCore>(rng: &mut R, bytes: &mut [u8]) {
        \\    helpers::fill_bytes_via_next(rng, bytes);
        \\}
    });
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const model = try pipeline.analyzeCrateWithOptions(alloc, std.testing.io, directory, .{});
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var helper_calls: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .core_call and
            expression.kind.core_call.function == .rng_fill_bytes_via_next) helper_calls += 1;
    }
    try testing.expectEqual(@as(usize, 1), helper_calls);
}

test "differential source retains owner witnesses and typed iterator captures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source = try @import("ingest.zig").readFileAlloc(alloc, std.testing.io, "test/crates/differential/src/lib.rs");
    const model = try pipeline.analyzeSourceWithOptions(alloc, "differential", "2021", source, .{ .include_tests = true });
    try expectTranslatable(&model);
    try expectNothingLeftOpen(&model);

    const witnesses = [_][]const u8{
        "owner_scope_generic_string",
        "owner_scope_core_argument_block",
        "owner_scope_push_string",
        "owner_scope_move_closure",
        "owner_scope_repeat_zero",
        "owner_scope_repeat_one",
        "owner_scope_repeat_two",
        "owner_scope_repeat_local",
    };
    for (witnesses) |name| {
        var found = false;
        for (model.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .fn_ or !std.mem.eql(u8, entity.name, name)) continue;
            const function = switch (model.bodies.bodies[entity.id]) {
                .fn_ => |value| value,
                else => return error.WitnessHasNoFunctionBody,
            };
            try testing.expect(model.bodies.exprs[function.body].kind == .block);
            found = true;
        }
        try testing.expect(found);
    }

    var owner_capture_seen = false;
    var borrowed_predicates: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .closure) {
            const closure = expression.kind.closure;
            if (closure.captures.len != 1 or
                !std.mem.eql(u8, closure.captures[0].name, "value")) continue;
            try testing.expectEqual(@as(usize, 1), closure.params.len);
            try testing.expect(model.bodies.pats[closure.params[0]].kind == .wildcard);
            try testing.expectEqual(exprs.CaptureMode.by_value, closure.captures[0].mode);
            try testing.expectEqual(exprs.ClosureTrait.fn_once, closure.trait);
            const capture_type = typeAt(&model, closure.captures[0].ty);
            try testing.expect(capture_type == .external_nominal);
            try testing.expectEqual(@as(usize, 3), capture_type.external_nominal.path.len);
            for (capture_type.external_nominal.path, [_][]const u8{ "alloc", "string", "String" }) |actual, expected| {
                try testing.expectEqualStrings(expected, actual);
            }
            owner_capture_seen = true;
        }
        if (expression.kind != .iterator_chain) continue;
        for (expression.kind.iterator_chain.adapters) |adapter| {
            if (adapter != .filter) continue;
            for (adapter.filter.closure.captures) |capture| {
                if (!std.mem.eql(u8, capture.name, "cursor")) continue;
                try testing.expectEqual(exprs.CaptureMode.by_mut_ref, capture.mode);
                const capture_type = typeAt(&model, capture.ty);
                try testing.expect(capture_type == .reference and capture_type.reference.mut);
                try testing.expectEqual(types.Type{ .prim = .u32 }, capture_type.reference.pointee);
                borrowed_predicates += 1;
            }
        }
    }
    try testing.expect(owner_capture_seen);
    try testing.expectEqual(@as(usize, 2), borrowed_predicates);
}

fn fnEntityNamed(model: *const ir.RustIr, name: []const u8) ?ir.spine.EntityId {
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (!std.mem.eql(u8, entity.name, name)) continue;
        return entity.id;
    }
    return null;
}

fn paramBinding(model: *const ir.RustIr, fn_id: ir.spine.EntityId, name: []const u8) ?ir.spine.EntityId {
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .field) continue;
        if (entity.parent == null or entity.parent.? != fn_id) continue;
        if (!std.mem.eql(u8, entity.name, name)) continue;
        return entity.id;
    }
    return null;
}

fn fnBodyBlock(model: *const ir.RustIr, id: ir.spine.EntityId) !exprs.NodeId {
    const body = switch (model.bodies.bodies[id]) {
        .fn_ => |value| value,
        else => return error.NotAFunctionBody,
    };
    if (model.bodies.exprs[body.body].kind != .block) return error.BodyIsNotABlock;
    return body.body;
}

fn blockStatements(model: *const ir.RustIr, block: exprs.NodeId) []const exprs.NodeId {
    return switch (model.bodies.exprs[block].kind) {
        .block => |value| value.statements,
        else => &.{},
    };
}

fn statementExpr(model: *const ir.RustIr, block: exprs.NodeId, index: usize) ?exprs.NodeId {
    const statements = blockStatements(model, block);
    if (index >= statements.len) return null;
    return switch (model.bodies.stmts[statements[index]].kind) {
        .expr => |node| node,
        else => null,
    };
}

fn letInitializer(model: *const ir.RustIr, block: exprs.NodeId, index: usize) ?exprs.NodeId {
    const statements = blockStatements(model, block);
    if (index >= statements.len) return null;
    return switch (model.bodies.stmts[statements[index]].kind) {
        .let => |declaration| declaration.init,
        else => null,
    };
}

fn associatedDef(model: *const ir.RustIr, node: exprs.NodeId) ?exprs.DefId {
    if (node >= model.bodies.exprs.len) return null;
    const call = switch (model.bodies.exprs[node].kind) {
        .call => |value| value,
        else => return null,
    };
    return switch (call.call_kind) {
        .associated => |def| def,
        else => null,
    };
}

fn soleArgumentDef(model: *const ir.RustIr, node: exprs.NodeId) ?exprs.DefId {
    const call = switch (model.bodies.exprs[node].kind) {
        .call => |value| value,
        else => return null,
    };
    if (call.args.len != 1) return null;
    return switch (model.bodies.exprs[call.args[0]].kind) {
        .path => |value| value.def,
        else => null,
    };
}

fn expectStdAssocConstructor(
    model: *const ir.RustIr,
    def: exprs.DefId,
    owner_path: []const []const u8,
    ty_param: []const u8,
    param_name: []const u8,
) !void {
    const entity = model.graph.symbol_table.get(def) orelse return error.MissingEntityId;
    try testing.expectEqual(ir.spine.EntityKind.fn_, entity.kind);
    try testing.expectEqualStrings("new", entity.name);

    const owner_module = model.graph.symbol_table.get(
        entity.parent orelse return error.MissingParentId,
    ) orelse return error.MissingEntityId;
    try testing.expectEqualStrings(owner_path[owner_path.len - 2], owner_module.name);
    const crate_root = model.graph.symbol_table.get(
        owner_module.parent orelse return error.MissingParentId,
    ) orelse return error.MissingEntityId;
    try testing.expectEqualStrings(owner_path[0], crate_root.name);

    const fn_body = switch (model.bodies.bodies[def]) {
        .fn_ => |value| value,
        else => return error.NotAFunctionBody,
    };
    try testing.expectEqual(@as(usize, 1), fn_body.params.len);
    try testing.expectEqualStrings(param_name, fn_body.params[0].name);
    const param_ty = switch (fn_body.params[0].ty) {
        .path => |value| value,
        else => return error.ExpectedTypeParameter,
    };
    try testing.expectEqual(@as(usize, 1), param_ty.segments.len);
    try testing.expectEqualStrings(ty_param, param_ty.segments[0].name);
    try testing.expectEqual(@as(?ir.spine.EntityId, null), param_ty.segments[0].id);

    const ret = switch (fn_body.ret) {
        .external_nominal => |value| value,
        else => return error.ExpectedExternalNominal,
    };
    try testing.expectEqual(owner_path.len, ret.path.len);
    for (owner_path, ret.path) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
    try testing.expectEqual(@as(usize, 1), ret.args.len);
    const ret_arg = switch (ret.args[0]) {
        .path => |value| value,
        else => return error.ExpectedTypeParameter,
    };
    try testing.expectEqualStrings(ty_param, ret_arg.segments[0].name);

    try testing.expectEqual(@as(usize, 1), fn_body.generic_params.len);
    try testing.expectEqualStrings(ty_param, fn_body.generic_params[0]);
}

test "a block-local import binds a nested helper declared above it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn bufread(data: &[u8]) {
        \\    fn test(inner: &[u8]) -> BufReader<&[u8]> {
        \\        let buffered = BufReader::new(inner);
        \\        buffered
        \\    }
        \\    use std::io::BufReader;
        \\    test(data);
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const bufread_id = fnEntityNamed(&model, "bufread") orelse return error.MissingBufread;
    var helper: ?ir.spine.EntityId = null;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (entity.parent == null or entity.parent.? != bufread_id) continue;
        helper = entity.id;
    }
    const helper_id = helper orelse return error.MissingNestedHelper;
    const helper_ret = model.bodies.bodies[helper_id].fn_.ret;
    try testing.expect(helper_ret == .external_nominal);
    try testing.expectEqual(@as(usize, 3), helper_ret.external_nominal.path.len);
    for (helper_ret.external_nominal.path, [_][]const u8{ "std", "io", "BufReader" }) |actual, expected| {
        try testing.expectEqualStrings(expected, actual);
    }
    try testing.expectEqual(@as(usize, 1), helper_ret.external_nominal.args.len);
    try expectChunkSliceOfU8(helper_ret.external_nominal.args[0]);

    const helper_block = try fnBodyBlock(&model, helper_id);
    try testing.expectEqual(@as(usize, 1), blockStatements(&model, helper_block).len);
    const init = letInitializer(&model, helper_block, 0) orelse return error.MissingInitializer;
    try testing.expectEqual(@as(?[]const u8, null), unsupportedReason(&model, init));

    try expectStdAssocConstructor(
        &model,
        associatedDef(&model, init) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "BufReader" },
        "R",
        "inner",
    );

    try testing.expectEqual(
        paramBinding(&model, helper_id, "inner").?,
        soleArgumentDef(&model, init) orelse return error.ExpectedParameterArgument,
    );
}

test "block imports shadow module aliases and restore their enclosing scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use std::io::Cursor as Reader;
        \\pub fn outer(data: &[u8]) {
        \\    use std::io::BufReader as Reader;
        \\    let first = Reader::new(data);
        \\    {
        \\        use std::io::Cursor as Reader;
        \\        let inner = Reader::new(data);
        \\    }
        \\    let restored = Reader::new(data);
        \\}
        \\pub fn outside(data: &[u8]) {
        \\    let module_reader = Reader::new(data);
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    const outer = try fnBodyBlock(&model, fnEntityNamed(&model, "outer") orelse return error.MissingOuter);
    for ([_]usize{ 0, 2 }) |index| {
        try expectStdAssocConstructor(&model, associatedDef(&model, letInitializer(&model, outer, index) orelse return error.MissingInitializer) orelse return error.MissingConstructor, &.{ "std", "io", "BufReader" }, "R", "inner");
    }
    const inner = statementExpr(&model, outer, 1) orelse return error.MissingInnerBlock;
    const outside = try fnBodyBlock(&model, fnEntityNamed(&model, "outside") orelse return error.MissingOutside);
    for ([_]exprs.NodeId{ inner, outside }) |block| {
        try expectStdAssocConstructor(&model, associatedDef(&model, letInitializer(&model, block, 0) orelse return error.MissingInitializer) orelse return error.MissingConstructor, &.{ "std", "io", "Cursor" }, "T", "inner");
    }
}

fn expectOnlyRefusal(model: *const ir.RustIr, name: []const u8, reason: []const u8) !void {
    const block = try fnBodyBlock(
        model,
        fnEntityNamed(model, name) orelse return error.MissingFunction,
    );
    try testing.expectEqual(@as(usize, 1), blockStatements(model, block).len);
    try testing.expectEqualStrings(
        reason,
        unsupportedReason(model, statementExpr(model, block, 0) orelse return error.MissingRefusal) orelse
            return error.UnrefusedImport,
    );
}

test "a block-local glob is refused where it is written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn from_io() {
        \\    use std::io::*;
        \\}
        \\pub fn from_fmt() {
        \\    use std::fmt::*;
        \\}
    );
    try testing.expectError(error.UnsupportedExpression, ir.validateForTranslation(&model));

    for ([_][]const u8{ "from_io", "from_fmt" }) |name| {
        try expectOnlyRefusal(&model, name, "block-local use");
    }
}

test "a block-local group binds its members, its own head, and its alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn grouped(data: &[u8]) {
        \\    use std::io::{self, BufReader, Cursor};
        \\    let a = BufReader::new(data);
        \\    let b = Cursor::new(0u32);
        \\    let c = io::Cursor::new(0u32);
        \\}
        \\pub fn aliased(data: &[u8]) {
        \\    use std::io::BufReader as Reader;
        \\    let reader = Reader::new(data);
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const block = try fnBodyBlock(
        &model,
        fnEntityNamed(&model, "grouped") orelse return error.MissingFunction,
    );
    try testing.expectEqual(@as(usize, 3), blockStatements(&model, block).len);
    try expectStdAssocConstructor(
        &model,
        associatedDef(
            &model,
            letInitializer(&model, block, 0) orelse return error.MissingInitializer,
        ) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "BufReader" },
        "R",
        "inner",
    );
    try expectStdAssocConstructor(
        &model,
        associatedDef(
            &model,
            letInitializer(&model, block, 1) orelse return error.MissingInitializer,
        ) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "Cursor" },
        "T",
        "inner",
    );
    try expectStdAssocConstructor(
        &model,
        associatedDef(
            &model,
            letInitializer(&model, block, 2) orelse return error.MissingInitializer,
        ) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "Cursor" },
        "T",
        "inner",
    );

    const alias_block = try fnBodyBlock(
        &model,
        fnEntityNamed(&model, "aliased") orelse return error.MissingFunction,
    );
    try expectStdAssocConstructor(
        &model,
        associatedDef(
            &model,
            letInitializer(&model, alias_block, 0) orelse return error.MissingInitializer,
        ) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "BufReader" },
        "R",
        "inner",
    );
}

test "a block-local use of a path this crate defines resolves to that definition" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn checksum() -> u32 { 7 }
        \\pub fn read(data: &[u8]) -> u32 {
        \\    use crate::checksum;
        \\    let total = checksum();
        \\    total
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const block = try fnBodyBlock(
        &model,
        fnEntityNamed(&model, "read") orelse return error.MissingFunction,
    );
    const init = letInitializer(&model, block, 0) orelse return error.MissingInitializer;
    const call = switch (model.bodies.exprs[init].kind) {
        .call => |value| value,
        else => return error.ExpectedCall,
    };
    try testing.expectEqual(@as(usize, 0), call.args.len);
    try testing.expectEqual(
        fnEntityNamed(&model, "checksum") orelse return error.MissingFunction,
        switch (call.call_kind) {
            .free => |def| def,
            else => return error.ExpectedFreeCall,
        },
    );
}

test "adler's buffered-reader test resolves the BufReader import its own block declares" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try pipeline.analyzeCrateWithOptions(
        alloc,
        std.testing.io,
        "test/crates/adler",
        .{ .include_tests = true },
    );

    const bufread_id = fnEntityNamed(&model, "bufread") orelse return error.MissingBufread;
    const bufread_block = try fnBodyBlock(&model, bufread_id);
    try testing.expectEqual(@as(usize, 5), blockStatements(&model, bufread_block).len);

    var helper: ?ir.spine.EntityId = null;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (entity.parent == null or entity.parent.? != bufread_id) continue;
        helper = entity.id;
    }
    const helper_id = helper orelse return error.MissingNestedHelper;
    try testing.expectEqual(helper_id, switch (model.bodies.stmts[
        blockStatements(&model, bufread_block)[0]
    ].kind) {
        .item => |ref_id| ref_id,
        else => return error.MissingHelperItem,
    });

    const helper_block = try fnBodyBlock(&model, helper_id);
    const init = letInitializer(&model, helper_block, 0) orelse return error.MissingInitializer;
    try testing.expectEqual(@as(?[]const u8, null), unsupportedReason(&model, init));

    try expectStdAssocConstructor(
        &model,
        associatedDef(&model, init) orelse return error.UnresolvedConstructor,
        &.{ "std", "io", "BufReader" },
        "R",
        "inner",
    );
    try testing.expectEqual(
        paramBinding(&model, helper_id, "data") orelse return error.MissingParameterBinding,
        soleArgumentDef(&model, init) orelse return error.ExpectedParameterArgument,
    );

    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
}

test "owned closure consumption is distinct from capture placement and parameter shadowing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn implicit() -> String {
        \\    let consumed = String::from("implicit");
        \\    let closure = |_: ()| consumed;
        \\    closure(())
        \\}
        \\pub fn moved_length() -> usize {
        \\    let moved = String::from("moved");
        \\    let closure = move |_: ()| moved.len();
        \\    closure(())
        \\}
        \\pub fn shadow() -> u32 {
        \\    let value = 1u32;
        \\    let closure = move |value: u32| value;
        \\    closure(2u32)
        \\}
        \\pub fn consuming_mutation(counter: &mut u32) -> String {
        \\    let consumed = String::from("counter");
        \\    let closure = |_: ()| { *counter += 1; consumed };
        \\    closure(())
        \\}
        \\pub fn wildcard_let() -> usize {
        \\    let observed = String::from("let");
        \\    let closure = |_: ()| { let _ = observed; observed.len() };
        \\    closure(())
        \\}
        \\pub fn wildcard_match() -> usize {
        \\    let observed = String::from("match");
        \\    let closure = |_: ()| { match observed { _ => observed.len() } };
        \\    closure(())
        \\}
        \\pub fn consuming_method() -> Vec<u8> {
        \\    let consumed = String::from("bytes");
        \\    let closure = |_: ()| consumed.into_bytes();
        \\    closure(())
        \\}
        \\pub fn consuming_match() -> String {
        \\    let consumed = String::from("match");
        \\    let closure = |_: ()| { match consumed { taken => taken } };
        \\    closure(())
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var closures: usize = 0;
    var consumed_captures: usize = 0;
    var observed_captures: usize = 0;
    var counter_seen = false;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .closure) continue;
        const closure = expression.kind.closure;
        try testing.expectEqual(@as(usize, 1), closure.params.len);
        closures += 1;
        if (closure.captures.len == 0) {
            try testing.expectEqual(exprs.ClosureTrait.@"fn", closure.trait);
            try testing.expect(model.bodies.pats[closure.params[0]].kind == .binding);
        }
        for (closure.captures) |capture| {
            if (std.mem.eql(u8, capture.name, "consumed")) {
                try testing.expectEqual(exprs.CaptureMode.by_value, capture.mode);
                try testing.expectEqual(exprs.ClosureTrait.fn_once, closure.trait);
                consumed_captures += 1;
            } else if (std.mem.eql(u8, capture.name, "moved")) {
                try testing.expectEqual(exprs.CaptureMode.by_value, capture.mode);
                try testing.expectEqual(exprs.ClosureTrait.@"fn", closure.trait);
            } else if (std.mem.eql(u8, capture.name, "observed")) {
                try testing.expectEqual(exprs.CaptureMode.by_ref, capture.mode);
                try testing.expectEqual(exprs.ClosureTrait.@"fn", closure.trait);
                observed_captures += 1;
            } else if (std.mem.eql(u8, capture.name, "counter")) {
                try testing.expectEqual(exprs.CaptureMode.by_mut_ref, capture.mode);
                try testing.expectEqual(exprs.ClosureTrait.fn_once, closure.trait);
                counter_seen = true;
            } else return error.UnexpectedClosureCapture;
        }
    }
    try testing.expectEqual(@as(usize, 8), closures);
    try testing.expectEqual(@as(usize, 4), consumed_captures);
    try testing.expectEqual(@as(usize, 2), observed_captures);
    try testing.expect(counter_seen);
}

test "a typed wildcard function parameter has no destructuring prologue" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(), "pub fn ignore(_: u32) {}");
    try ir.validateForTranslation(&model);
    const block = try fnBodyBlock(&model, fnEntityNamed(&model, "ignore") orelse return error.MissingFunction);
    try testing.expectEqual(@as(usize, 0), blockStatements(&model, block).len);
}

fn expectMaybeUninit(ty: types.Type, primitive: types.Prim) !void {
    if (ty != .external_nominal) return error.UninitResultIsNotMaybeUninit;
    const owner = ty.external_nominal;
    try testing.expectEqual(@as(usize, 3), owner.path.len);
    try testing.expectEqualStrings("core", owner.path[0]);
    try testing.expectEqualStrings("mem", owner.path[1]);
    try testing.expectEqualStrings("MaybeUninit", owner.path[2]);
    try testing.expectEqual(@as(usize, 1), owner.args.len);
    try expectPrim(owner.args[0], primitive);
}

test "MaybeUninit owner turbofish lowers the repeated element in Buffer new" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use core::mem::{self, MaybeUninit};
        \\const I128_MAX_LEN: usize = 40;
        \\pub struct Buffer { bytes: [MaybeUninit<u8>; I128_MAX_LEN] }
        \\impl Buffer {
        \\    pub fn new() -> Buffer {
        \\        let bytes = [MaybeUninit::<u8>::uninit(); I128_MAX_LEN];
        \\        Buffer { bytes }
        \\    }
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    const array = model.bodies.exprs[onlyArrayLiteral(&model) orelse return error.NoRepeatedArray].kind.array;
    try testing.expectEqual(@as(?u64, 40), array.repeat);
    try testing.expectEqual(@as(usize, 1), array.elements.len);
    const element = model.bodies.exprs[array.elements[0]];
    if (element.kind != .core_call) return error.UninitIsNotACoreCall;
    const call = element.kind.core_call;
    try testing.expectEqual(exprs.CoreFunction.maybe_uninit_uninit, call.function);
    try testing.expectEqual(@as(usize, 0), call.args.len);
    try testing.expectEqual(@as(usize, 1), call.generic_args.len);
    try expectPrim(call.generic_args[0], .u8);
    try expectMaybeUninit(typeAt(&model, element.ty orelse return error.UntypedUninit), .u8);
    const array_expr = model.bodies.exprs[onlyArrayLiteral(&model).?];
    const array_type = typeAt(&model, array_expr.ty orelse return error.UntypedRepeatedArray);
    try testing.expect(array_type == .array);
    try expectMaybeUninit(array_type.array.elem, .u8);
}

test "renamed canonical MaybeUninit retains its owner type argument" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\use core::mem::MaybeUninit as RawSlot;
        \\pub fn make() -> RawSlot<u16> { RawSlot::<u16>::uninit() }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    const call = onlyCoreCall(&model) orelse return error.NoUniqueUninitCall;
    try testing.expectEqual(exprs.CoreFunction.maybe_uninit_uninit, call.function);
    try testing.expectEqual(@as(usize, 0), call.args.len);
    try testing.expectEqual(@as(usize, 1), call.generic_args.len);
    try expectPrim(call.generic_args[0], .u16);
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        try expectMaybeUninit(typeAt(&model, expression.ty orelse return error.UntypedAliasedUninit), .u16);
    }
}

test "source MaybeUninit homonym keeps its generic source callee and value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub struct MaybeUninit;
        \\impl MaybeUninit {
        \\    pub fn uninit<T>(value: T) -> T { value }
        \\}
        \\pub fn run() -> u8 { MaybeUninit::uninit::<u8>(7u8) }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var seen: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .core_call)
            try testing.expect(expression.kind.core_call.function != .maybe_uninit_uninit);
        if (expression.kind != .call) continue;
        const call = expression.kind.call;
        if (call.call_kind != .associated) continue;
        const callee_id = call.call_kind.associated;
        const callee = model.graph.symbol_table.get(callee_id) orelse return error.MissingSourceCallee;
        try testing.expect(callee.kind == .fn_);
        try testing.expectEqualStrings("uninit", callee.name);
        const source_fn = model.bodies.bodies[callee_id].fn_;
        try testing.expectEqual(@as(usize, 1), source_fn.generic_params.len);
        try testing.expectEqualStrings("T", source_fn.generic_params[0]);
        try testing.expect(source_fn.ret == .path);
        try testing.expectEqualStrings("T", source_fn.ret.path.segments[0].name);
        // The call's own result is what the source means here: the homonymous
        // `fn uninit<T>(value: T) -> T` is called at `T = u8`, so it hands back
        // the `u8`. An `.generic_inst` witness over `uninit` would name the
        // same declaration with the same argument and say strictly less — and
        // the homonym is settled by the CALLEE being the source `fn_` above,
        // not by the shape of the result.
        const witness = typeAt(&model, expression.ty orelse return error.MissingSourceCallWitness);
        if (witness != .prim or witness.prim != .u8) return error.CallResultIsNotTheInstantiatedU8;
        try testing.expectEqual(@as(usize, 1), call.args.len);
        const value = model.bodies.exprs[call.args[0]].kind.literal.int;
        try testing.expectEqual(@as(i128, 7), value.value);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "itoa source Buffer new retains forty canonical MaybeUninit byte slots" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/itoa",
        .{ .include_tests = true },
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var buffers: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .array) continue;
        const array = expression.kind.array;
        if (array.repeat != 40 or array.elements.len != 1) continue;
        const element = model.bodies.exprs[array.elements[0]];
        if (element.kind != .core_call or element.kind.core_call.function != .maybe_uninit_uninit) continue;
        try testing.expectEqual(@as(usize, 1), element.kind.core_call.generic_args.len);
        try expectPrim(element.kind.core_call.generic_args[0], .u8);
        try expectMaybeUninit(typeAt(&model, element.ty orelse return error.UntypedUninit), .u8);
        const array_type = typeAt(&model, expression.ty orelse return error.UntypedRepeatedArray);
        try testing.expect(array_type == .array);
        try expectMaybeUninit(array_type.array.elem, .u8);
        buffers += 1;
    }
    try testing.expectEqual(@as(usize, 1), buffers);
}

fn expectSourceStrReference(ty: types.Type) !void {
    try testing.expect(ty == .reference);
    try testing.expect(!ty.reference.mut);
    try testing.expect(ty.reference.pointee == .external_nominal);
    const actual = ty.reference.pointee.external_nominal;
    const expected = types.str_type.external_nominal;
    try testing.expectEqual(expected.path.len, actual.path.len);
    try testing.expectEqual(@as(usize, 0), actual.args.len);
    for (expected.path, actual.path) |expected_segment, actual_segment| {
        try testing.expectEqualStrings(expected_segment, actual_segment);
    }
}

test "source tuple strings keep canonical borrowed str identity through Hash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const source =
        \\use core::hash::{Hash, Hasher};
        \\struct Trace { state: u64 }
        \\impl Hasher for Trace {
        \\    fn finish(&self) -> u64 { self.state }
        \\    fn write(&mut self, bytes: &[u8]) {
        \\        for &byte in bytes {
        \\            self.state = (self.state ^ byte as u64).wrapping_mul(1099511628211);
        \\        }
        \\    }
        \\}
        \\fn hash<T: Hash>(value: &T) -> u64 {
        \\    let mut state = Trace { state: 14695981039346656037 };
        \\    value.hash(&mut state);
        \\    state.finish()
        \\}
        \\pub fn tuple_strings() -> bool {
        \\    let s = ("aa", "bb");
        \\    let t = ("aabb", "");
        \\    let u = ("a", "abb");
        \\    hash(&s) != hash(&t) && hash(&s) != hash(&u)
        \\}
    ;
    const model = try analyze(arena_state.allocator(), source);
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var strings: usize = 0;
    var tuples: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .literal and expression.kind.literal == .string) {
            try expectSourceStrReference(typeAt(&model, expression.ty orelse return error.UntypedString));
            strings += 1;
        }
        if (expression.kind != .array) continue;
        const ty = typeAt(&model, expression.ty orelse return error.UntypedTuple);
        if (ty != .tuple) continue;
        try testing.expectEqual(@as(usize, 2), ty.tuple.len);
        for (ty.tuple) |element| try expectSourceStrReference(element);
        tuples += 1;
    }
    try testing.expectEqual(@as(usize, 6), strings);
    try testing.expectEqual(@as(usize, 3), tuples);
}

test "nested source borrow receives u8 context without an early i32 decision" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\fn byte_ref(value: &u8) -> u8 { *value }
        \\pub fn nested_borrow() -> u8 {
        \\    let borrowed = &7;
        \\    let pair = ((borrowed, true), 0);
        \\    let result = byte_ref(pair.0.0);
        \\    let count: usize = pair.1;
        \\    result + count as u8
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var borrowed_literal: usize = 0;
    var contextual_count: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .literal or expression.kind.literal != .int) continue;
        const integer = expression.kind.literal.int;
        if (integer.value == 7) {
            try expectPrim(typeAt(&model, expression.ty orelse return error.UntypedBorrowedLiteral), .u8);
            borrowed_literal += 1;
        } else if (integer.value == 0) {
            try expectPrim(typeAt(&model, expression.ty orelse return error.UntypedTupleCount), .usize);
            contextual_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), borrowed_literal);
    try testing.expectEqual(@as(usize, 1), contextual_count);
}

test "pristine siphasher test bodies preserve canonical string hints" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/siphasher",
        .{ .include_tests = true },
    );
    // Deliberately NOT `ir.validateForTranslation`. That call is the boundary
    // this crate is PINNED to refuse at: `validateInstantiations` raises
    // `IncompleteGenericMetadata` for an instantiation whose argument list does
    // not match its declaration's generic arity, and the repository records
    // that refusal in four places — README's pinned-refusal table,
    // `test/e2e_test.zig`'s `refused_source_crates` row,
    // `test/promoted_crates_consumer.zig`, and `build.zig`'s crate matrix.
    // Gating this test on it asserts a fact the project deliberately records as
    // false, and it says nothing about the claim this test is named for.
    //
    // What is left is the claim itself: the crate analyses with no refusal
    // marker and no open slot anywhere in its type table, and every string
    // literal it contains — the `("aa", "bb")` / `("aabb", "")` / `("a", "abb")`
    // rows of `tests.rs::test_hash_no_concat_alias` among them — keeps the
    // canonical borrowed `str` identity the tuple rows are built from.
    try expectNothingLeftOpen(&model);
    var strings: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .literal or expression.kind.literal != .string) continue;
        try expectSourceStrReference(typeAt(&model, expression.ty orelse return error.UntypedString));
        strings += 1;
    }
    try testing.expect(strings >= 6);
}

test "pristine atoi source preserves Sign constructors and usize index context" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/atoi",
        .{ .include_tests = true },
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var sign_constructors: usize = 0;
    var indices: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .enum_variant) {
            const variant = expression.kind.enum_variant;
            const owner = model.graph.symbol_table.get(variant.def) orelse continue;
            if (owner.kind == .enum_ and std.mem.eql(u8, owner.name, "Sign")) {
                const ty = typeAt(&model, expression.ty orelse return error.UntypedSignConstructor);
                try testing.expect(ty == .path);
                try testing.expect(ty.path.segments.len != 0);
                try testing.expectEqualStrings("Sign", ty.path.segments[ty.path.segments.len - 1].name);
                sign_constructors += 1;
            }
        }
        if (expression.kind != .index) continue;
        const index = model.bodies.exprs[expression.kind.index.index];
        if (index.kind == .range) {
            const range = index.kind.range;
            const start = model.bodies.exprs[range.start];
            try expectPrim(typeAt(&model, start.ty orelse return error.UntypedRangeStart), .usize);
            if (range.end) |end| {
                const endpoint = model.bodies.exprs[end];
                try expectPrim(typeAt(&model, endpoint.ty orelse return error.UntypedRangeEnd), .usize);
            }
        } else {
            try expectPrim(typeAt(&model, index.ty orelse return error.UntypedIndex), .usize);
        }
        indices += 1;
    }
    try testing.expect(sign_constructors >= 2);
    try testing.expect(indices >= 1);
}

/// The canonical `<Head as Trait>::Member` projection as the IR carries it.
///
/// Exactly three path segments, and the middle one is the only one carrying an
/// id: the head is the lexical type parameter the source wrote the signature
/// on, the middle is the trait ENTITY that declares the member — module prefix
/// and `as` clause already gone — and the terminal keeps a NULL id because no
/// impl has been chosen for the receiver yet.
const AssociatedProjection = struct {
    head: []const u8,
    trait_name: []const u8,
    module_name: []const u8,
    member: []const u8,
};

fn associatedProjection(model: *const ir.RustIr, ty: types.Type) ?AssociatedProjection {
    const path = switch (ty) {
        .path => |value| value,
        else => return null,
    };
    if (path.segments.len != 3) return null;
    const head = path.segments[0];
    const trait_id = path.segments[1].id orelse return null;
    const member = path.segments[2];
    if (head.id != null or member.id != null) return null;
    const trait_entity = model.graph.symbol_table.get(trait_id) orelse return null;
    if (trait_entity.kind != .trait_) return null;
    const module_id = trait_entity.parent orelse return null;
    const module_entity = model.graph.symbol_table.get(module_id) orelse return null;
    if (module_entity.kind != .module) return null;
    return .{
        .head = head.name,
        .trait_name = trait_entity.name,
        .module_name = module_entity.name,
        .member = member.name,
    };
}

/// Assert `ty` is the `<I as private::Sealed>::Buffer` projection: the
/// generic parameter the signature is written on, the sealed trait reached
/// through the nested module that declares it — not a `Sealed` the caller
/// happened to have in scope — and the trait's own member name.
fn expectSealedBufferProjection(model: *const ir.RustIr, ty: types.Type) !void {
    const projection = associatedProjection(model, ty) orelse return error.NotAnAssociatedProjection;
    try testing.expectEqualStrings("I", projection.head);
    try testing.expectEqualStrings("Sealed", projection.trait_name);
    try testing.expectEqualStrings("private", projection.module_name);
    try testing.expectEqualStrings("Buffer", projection.member);
}

/// Assert the projection type table entry really is the open form: the head
/// carries no id, the middle is the trait, and the terminal is the member NAME
/// with no id. An id on the terminal is an impl's `type Buffer = ...` standing
/// in for the generic, which is exactly the decision this shape refuses.
fn expectOpenProjectionSegments(model: *const ir.RustIr, ty: types.Type) !void {
    const path = switch (ty) {
        .path => |value| value,
        else => return error.ProjectionIsNotAPath,
    };
    try testing.expectEqual(@as(usize, 3), path.segments.len);
    try testing.expect(path.segments[0].id == null);
    const trait_id = path.segments[1].id orelse return error.ProjectionHasNoTraitId;
    const trait_entity = model.graph.symbol_table.get(trait_id) orelse return error.ProjectionHasNoTraitEntity;
    try testing.expectEqualStrings(trait_entity.name, path.segments[1].name);
    try testing.expect(path.segments[2].id == null);
    try testing.expectEqualStrings("Buffer", path.segments[2].name);
}

/// The two primitive impls of the sealed trait name their own array lengths, so
/// the count is what says the extractor did not pick one of them for `I`.
fn implBufferLengths(model: *const ir.RustIr) ![2]u64 {
    var lengths: [2]u64 = undefined;
    var seen: usize = 0;
    for (model.bodies.bodies) |body| {
        const impl_body = switch (body) {
            .impl_ => |value| value,
            else => continue,
        };
        // `impl Sealed for i8 { type Buffer = [u8; 4]; }` binds `Buffer` as an
        // item INSIDE the impl, so it lands in `assoc_items` as its own
        // `.type_alias` body. `trait_associated_types` is the other shape
        // entirely — the `as Sealed<Buffer = ..>` clause on the impl HEAD —
        // and is empty for this source. Reading the wrong one reports zero
        // layouts and calls a disagreement between the impls "too few".
        for (impl_body.assoc_items) |item_id| {
            const entity = model.graph.symbol_table.get(item_id) orelse
                return error.MissingAssociatedItemEntity;
            if (!std.mem.eql(u8, entity.name, "Buffer")) continue;
            const alias = switch (model.bodies.bodies[@as(usize, item_id)]) {
                .type_alias => |value| value,
                else => return error.BufferBindingIsNotATypeAlias,
            };
            if (seen == lengths.len) return error.TooManyImplLayouts;
            lengths[seen] = switch (alias.target) {
                .array => |array| switch (array.len) {
                    .literal => |len| len,
                    else => return error.ImplLayoutLengthIsNotALiteral,
                },
                else => return error.ImplLayoutIsNotAnArray,
            };
            seen += 1;
        }
    }
    if (seen != lengths.len) return error.TooFewImplLayouts;
    return lengths;
}

test "a generic pointer cast keeps `<I as Sealed>::Buffer` open across two primitive impl layouts" {
    // `itoa`'s `format` re-labels the receiver's own `[u8; 20]` storage as the
    // sealed trait's associated buffer. Every primitive impl declares its OWN
    // length, so answering `I` here with either one would settle the layout
    // before the receiver is chosen — the target stays a projection, and the
    // backend pairs it with the trait descriptor instead.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\mod private {
        \\    pub trait Sealed {
        \\        type Buffer: 'static;
        \\    }
        \\}
        \\pub struct Buffer { bytes: [u8; 20] }
        \\impl Buffer {
        \\    pub fn format<I: private::Sealed>(&mut self, value: I) -> u8 {
        \\        let slot = unsafe {
        \\            &mut self.bytes as *mut [u8; 20]
        \\                as *mut <I as private::Sealed>::Buffer
        \\        };
        \\        self.bytes[0]
        \\    }
        \\}
        \\impl private::Sealed for i8 { type Buffer = [u8; 4]; }
        \\impl private::Sealed for u64 { type Buffer = [u8; 20]; }
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    // The two primitive impls really do disagree about the layout.
    const lengths = try implBufferLengths(&model);
    try testing.expect(lengths[0] != lengths[1]);
    const four: ?u64 = 4;
    const twenty: ?u64 = 20;
    try testing.expect((lengths[0] == four and lengths[1] == twenty) or
        (lengths[0] == twenty and lengths[1] == four));

    var projections: usize = 0;
    var compared_layouts: usize = 0;
    for (model.bodies.exprs) |expression| {
        const cast = switch (expression.kind) {
            .cast => |value| value,
            else => continue,
        };
        const pointer = switch (typeAt(&model, cast.target)) {
            .raw_ptr => |value| value,
            else => continue,
        };
        if (associatedProjection(&model, pointer.pointee) == null) continue;
        try expectOpenProjectionSegments(&model, pointer.pointee);
        try expectSealedBufferProjection(&model, pointer.pointee);
        // Neither impl's own layout may stand in for the generic: the two
        // disagree about the length, so the target cannot be either of them.
        for (model.bodies.bodies) |body| {
            const impl_body = switch (body) {
                .impl_ => |value| value,
                else => continue,
            };
            for (impl_body.assoc_items) |item_id| {
                const entity = model.graph.symbol_table.get(item_id) orelse
                    return error.MissingAssociatedItemEntity;
                if (!std.mem.eql(u8, entity.name, "Buffer")) continue;
                const binding = switch (model.bodies.bodies[@as(usize, item_id)]) {
                    .type_alias => |value| value.target,
                    else => return error.BufferBindingIsNotATypeAlias,
                };
                // `types.Type` is a tagged union, so the two are compared as
                // types, not as addresses — `types.deepEqual` is the IR's own
                // semantic equality. The difference is structural and
                // expected: the cast target is the three-segment projection
                // above with an open terminal, while each impl's binding is
                // that impl's own concrete layout, and the two layouts
                // disagree about the length (proved just above). So the
                // target is neither of them, and no impl was picked for `I`.
                const layout = switch (binding) {
                    .array => |value| value,
                    else => return error.BufferBindingIsNotAnArray,
                };
                switch (layout.len) {
                    .literal => {},
                    else => return error.BufferBindingLengthIsNotLiteral,
                }
                try testing.expect(!types.deepEqual(pointer.pointee, binding));
                compared_layouts += 1;
            }
        }
        projections += 1;
    }
    try testing.expectEqual(@as(usize, 1), projections);
    // Every projection is compared against BOTH impls' layouts, so the check
    // cannot pass by finding nothing to compare.
    try testing.expectEqual(projections * 2, compared_layouts);
}

test "pristine itoa keeps the Buffer cast target as the Sealed projection" {
    // `test/crates/itoa` is the real crate: `format` writes
    // `*mut <I as private::Sealed>::Buffer`, and the nested module the trait is
    // declared in is what makes the middle segment resolve to that trait rather
    // than to any `Sealed` in scope. Metadata only — no golden file decides it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/itoa",
        .{ .include_tests = true },
    );
    try ir.validateForTranslation(&model);
    var projections: usize = 0;
    for (model.bodies.types) |ty| {
        if (associatedProjection(&model, ty) == null) continue;
        try expectSealedBufferProjection(&model, ty);
        try expectOpenProjectionSegments(&model, ty);
        projections += 1;
    }
    try testing.expect(projections >= 1);
}

/// The name a lowered path reads, or null when the node is not a path.
fn pathBindingName(model: *const ir.RustIr, node: exprs.NodeId) ?[]const u8 {
    const path = switch (model.bodies.exprs[node].kind) {
        .path => |value| value,
        else => return null,
    };
    const entity = model.graph.symbol_table.get(path.def) orelse return null;
    return entity.name;
}

test "a comment between call arguments is not an argument" {
    // A `//` comment is a tree-sitter `extra`, so it is attached to the node
    // whose span contains it: a comment written between two arguments is a
    // named child of the `arguments` node, positioned among the operands, and
    // so is one written between the last two operands of the argument before
    // it. Neither carries a value, so the call must still receive exactly the
    // two expressions the source wrote, and the term written after the first
    // comment must still be one whole `^ extra` with both its own operands. A
    // comment read as a positional argument either refuses the whole
    // translation with the comment's node kind as the reason, or shifts the
    // term that follows it into the wrong slot.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn mix(left: u64, right: u64) -> u64 {
        \\    left ^ right
        \\}
        \\pub fn total(a: u64, b: u64, c: u64, d: u64, extra: u64) -> u64 {
        \\    mix(
        \\        a ^ b ^ c ^ d
        \\        // the number of written bytes
        \\        ^ extra,
        \\        // and the value folded in beside them
        \\        extra,
        \\    )
        \\}
    );

    // The lowered comment would sit in the table as an `unsupported` node, and
    // that is what this rejects before any structural assertion runs.
    try ir.validateForTranslation(&model);

    var calls: usize = 0;
    for (model.bodies.exprs) |expression| {
        const args = switch (expression.kind) {
            .call => |call| call.args,
            .method_call => |call| call.args,
            else => continue,
        };
        calls += 1;
        if (args.len != 2) return error.CommentBecameAnArgument;
        // `a ^ b ^ c ^ d ^ extra` is the argument the first comment splits, and
        // its `^ extra` tail is still one whole term.
        const head = switch (model.bodies.exprs[args[0]].kind) {
            .binary => |value| value,
            else => return error.FirstArgumentIsNotTheXor,
        };
        if (head.op != .bit_xor) return error.WrongHeadOperator;
        if (model.bodies.exprs[head.lhs].kind != .binary) return error.TailLostItsLeftOperand;
        const bound = pathBindingName(&model, head.rhs) orelse
            return error.TailLostItsRightOperand;
        if (!std.mem.eql(u8, bound, "extra")) return error.WrongTailOperand;
        // `extra` is the argument the second comment stands between.
        const second = pathBindingName(&model, args[1]) orelse
            return error.SecondArgumentIsNotThePath;
        if (!std.mem.eql(u8, second, "extra")) return error.WrongSecondArgument;
    }
    if (calls != 1) return error.WrongCallCount;
}

test "a comment at an operand, receiver or unary boundary keeps both sides" {
    // The same `extra` attaches a comment to whichever node spans it, so it
    // lands among the named children of a binary operand, of a receiver's
    // field access, and of a unary operand. Each of those is read
    // positionally, so each has to step over the comment — and the executable
    // node that follows it has to survive on its own side.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const model = try analyze(alloc,
        \\pub fn sizes(count: u64) -> u64 {
        \\    let first = 1;
        \\    let second =
        \\        first
        \\        // the comment sits between the operand and the operator
        \\        + count;
        \\    second
        \\}
        \\pub struct Pair {
        \\    left: u64,
        \\    right: u64,
        \\}
        \\pub fn first(pair: Pair) -> u64 {
        \\    pair
        \\    // the comment sits between the receiver and the field
        \\    .left
        \\}
        \\pub fn negated(value: i64) -> i64 {
        \\    -
        \\    // the comment sits before the operand
        \\    value
        \\}
    );

    try ir.validateForTranslation(&model);

    var sums: usize = 0;
    var fields: usize = 0;
    var negations: usize = 0;
    for (model.bodies.exprs) |expression| {
        switch (expression.kind) {
            .binary => |binary| {
                if (binary.op != .add) continue;
                const lhs = pathBindingName(&model, binary.lhs) orelse
                    return error.SumLostItsLeftOperand;
                const rhs = pathBindingName(&model, binary.rhs) orelse
                    return error.SumLostItsRightOperand;
                if (!std.mem.eql(u8, lhs, "first")) return error.WrongSumLeftOperand;
                if (!std.mem.eql(u8, rhs, "count")) return error.WrongSumRightOperand;
                sums += 1;
            },
            .field => |access| {
                const recv = pathBindingName(&model, access.base) orelse
                    return error.FieldAccessLostItsReceiver;
                if (!std.mem.eql(u8, recv, "pair")) return error.WrongFieldReceiver;
                // The comment sat between the two, so a positional read that
                // did not step over it took the comment's own text as the
                // field name.
                if (!std.mem.eql(u8, access.field, "left")) return error.WrongFieldName;
                fields += 1;
            },
            .unary => |unary| {
                if (unary.op != .negate) continue;
                const operand = pathBindingName(&model, unary.operand) orelse
                    return error.NegationLostItsOperand;
                if (!std.mem.eql(u8, operand, "value")) return error.WrongUnaryOperand;
                negations += 1;
            },
            else => {},
        }
    }
    if (sums != 1) return error.WrongSumCount;
    if (fields != 1) return error.WrongFieldCount;
    if (negations != 1) return error.WrongNegationCount;
}

test "an associated type on an impl binds its own concrete type in a method parameter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub trait SeedableRng {
        \\    type Seed;
        \\    fn from_seed(seed: Self::Seed) -> Self;
        \\}
        \\pub struct WyRng { state: u64 }
        \\impl SeedableRng for WyRng {
        \\    type Seed = [u8; 8];
        \\    fn from_seed(seed: Self::Seed) -> Self { WyRng { state: 0 } }
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);

    const def = fnEntityNamed(&model, "from_seed") orelse return error.MissingFromSeed;
    const fn_body = switch (model.bodies.bodies[def]) {
        .fn_ => |value| value,
        else => return error.NotAFunctionBody,
    };
    if (fn_body.params.len != 1) return error.WrongParameterCount;
    // `Self::Seed` is the impl's OWN `type Seed = [u8; 8]`. A `.path` still
    // carrying the `Self` segment resolves against nothing, and the failure
    // surfaces far away as `UnresolvedNominalType` deep inside body extraction,
    // long after the binder that should have substituted it has run.
    const param_ty = switch (fn_body.params[0].ty) {
        .array => |value| value,
        else => return error.SeedIsNotTheImplsArray,
    };
    if (param_ty.elem != .prim or param_ty.elem.prim != .u8) return error.SeedElementIsNotU8;
    if (param_ty.len != .literal) return error.SeedLengthIsNotLiteral;
    try testing.expectEqual(@as(u64, 8), param_ty.len.literal);
}

test "a `for` capture that names its own receiver still reads the parameter" {
    // `for data in data.chunks(4)` is valid Rust: the iterable is evaluated
    // before the capture exists. If the pattern is lowered first the capture
    // enters local scope through `pushLocal`, `resolveName` reverse-resolves
    // the name to the most recent local, and the ITERABLE RECEIVER becomes the
    // capture entity. The backend then renames the capture away from the
    // parameter and the emitted loop reads an identifier nothing declared —
    // `use of undeclared identifier 'bytes_1'` in wyhash's chunk loop. It is
    // invisible whenever the capture's name differs from its receiver's, so
    // the fixture aliases them deliberately.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn aliasing(data: &[u8]) -> usize {
        \\    let mut total = 0;
        \\    for data in data.chunks(4) {
        \\        total += data.len();
        \\    }
        \\    total
        \\}
    );
    try ir.validateForTranslation(&model);

    const fn_id = fnEntityNamed(&model, "aliasing") orelse return error.MissingFunction;
    // The parameter and the capture are both `.field` entities under the fn
    // and both named `data`. Parameters are registered first, so the first
    // match is the parameter and the last is the capture; both are checked so
    // the fixture cannot stop aliasing and pass for the wrong reason.
    var parameter: ?ir.spine.EntityId = null;
    var capture: ?ir.spine.EntityId = null;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .field) continue;
        if (entity.parent == null or entity.parent.? != fn_id) continue;
        if (!std.mem.eql(u8, entity.name, "data")) continue;
        if (parameter == null) parameter = entity.id;
        capture = entity.id;
    }
    const parameter_def = parameter orelse return error.MissingParameterBinding;
    const capture_def = capture orelse return error.MissingCaptureBinding;
    if (parameter_def == capture_def) return error.ParameterAndCaptureAreOneEntity;

    var loops: usize = 0;
    for (model.bodies.exprs) |expression| {
        const loop_expr = switch (expression.kind) {
            .for_ => |value| value,
            else => continue,
        };
        loops += 1;
        const binding = switch (model.bodies.pats[loop_expr.pattern].kind) {
            .binding => |value| value,
            else => return error.LoopCaptureIsNotABinding,
        };
        if (!std.mem.eql(u8, binding.name, "data")) return error.LoopCaptureHasTheWrongName;
        const receiver = switch (model.bodies.exprs[loop_expr.iterable].kind) {
            .method_call => |value| value.receiver,
            else => return error.IterableIsNotAMethodCall,
        };
        const receiver_def = switch (model.bodies.exprs[receiver].kind) {
            .path => |value| value.def,
            else => return error.ReceiverIsNotAPath,
        };
        if (receiver_def == capture_def) return error.CaptureShadowedTheIterableReceiver;
        if (receiver_def != parameter_def) return error.ReceiverIsNotTheParameter;
    }
    if (loops != 1) return error.WrongLoopCount;
}

test "a numeric default reached only through an external supertrait still lowers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // `I: Signed` grants `One` only through `Signed: Num: One`. `num_traits` is
    // an external crate, so there is no graph trait entity to read that chain
    // from — which is exactly how `atoi` writes `Sign::signum`.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Cargo.toml", .data =
        \\[package]
        \\name = "signum-consumer"
        \\version = "0.1.0"
        \\edition = "2018"
        \\[lib]
        \\path = "lib.rs"
        \\[dependencies]
        \\num-traits = "0.2.14"
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.rs", .data =
        \\extern crate num_traits;
        \\pub fn signum<I>(positive: bool) -> I
        \\where
        \\    I: num_traits::Signed,
        \\{
        \\    if positive { I::one() } else { -I::one() }
        \\}
    });
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const model = try pipeline.analyzeCrateWithOptions(alloc, std.testing.io, directory, .{});
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    var ones: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .core_call) continue;
        if (expression.kind.core_call.function != .numeric_one) continue;
        // The bound is `I`, so the core call carries the lexical parameter and
        // not a host integer chosen for it.
        try testing.expect(isLexicalParam(expression.kind.core_call.generic_args[0], "I"));
        ones += 1;
    }
    try testing.expectEqual(@as(usize, 2), ones);
}

/// `String` as `mapCstType` and the standard associated signatures write it:
/// a three-segment external root with no arguments.
const string_type: types.Type = .{ .external_nominal = .{
    .path = &.{ "alloc", "string", "String" },
    .args = &.{},
} };

/// The `Result` the one construction of `variant` in this snippet carries.
///
/// Null for no construction and for more than one, so a snippet that grew a
/// second pair cannot pass by checking only the one that was built right.
fn singleVariantResult(model: *const ir.RustIr, variant: []const u8) ?*const types.Result {
    var found: ?*const types.Result = null;
    for (model.bodies.exprs) |expression| {
        const construction = switch (expression.kind) {
            .enum_variant => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, construction.variant, variant)) continue;
        if (found != null) return null;
        found = switch (typeAt(model, expression.ty orelse return null)) {
            .result => |value| value,
            else => return null,
        };
    }
    return found;
}

/// Assert a pair holds exactly the two types its own arms carry.
///
/// A slot that names nothing — the `_` stand-in, or a nominal path no
/// declaration backs — is what an unannotated pair used to leave behind, and
/// the row it left is the one validation refused.
fn expectArmCarried(pair: *const types.Result, ok: types.Type, err: types.Type) !void {
    if (!infer.typeEqual(pair.ok, ok)) return error.OkSlotIsNotTheArmsType;
    if (!infer.typeEqual(pair.err, err)) return error.ErrSlotIsNotTheArmsType;
}

/// Assert a slot is a borrow of a `[u8]`, however the slice spells itself.
///
/// `&[u8]` is a fat pointer, and this translator spells a borrow of a slice as
/// the slice itself: `cstSlice` builds that row, and it is the row a parameter
/// of type `&[u8]` carries. `&str` — a borrow of an external nominal — keeps its
/// `.reference`, so an arm written `Ok(&bytes)` holds the reference over the
/// slice and one written `Ok(bytes)` holds the slice. Both spell the borrow the
/// source wrote.
fn expectBorrowedU8Slice(ty: types.Type) !void {
    const borrowed = switch (ty) {
        .reference => |reference| reference.pointee,
        .slice => ty,
        else => return error.SlotIsNotABorrow,
    };
    const slice = switch (borrowed) {
        .slice => |value| value,
        else => return error.BorrowIsNotASlice,
    };
    try expectU8(slice.elem);
}

/// Assert a slot is the lexical type parameter named `name`.
fn expectTypeParameter(ty: types.Type, name: []const u8) !void {
    const path = switch (ty) {
        .path => |value| value,
        else => return error.SlotIsNotANominalPath,
    };
    if (path.segments.len != 1) return error.NotASingleSegmentPath;
    if (!std.mem.eql(u8, path.segments[0].name, name)) return error.WrongTypeParameter;
}

/// The `Ok`/`Err` pair of `String` over `u8`, which every shape below builds.
fn expectStringU8Pair(model: *const ir.RustIr) !void {
    const ok = singleVariantResult(model, "Ok") orelse return error.NoOkConstruction;
    const err = singleVariantResult(model, "Err") orelse return error.NoErrConstruction;
    try expectArmCarried(ok, string_type, .{ .prim = .u8 });
    try expectArmCarried(err, string_type, .{ .prim = .u8 });
}

test "a matched unannotated Result pair carries the ok and err its own arms carry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The subject is a temporary no annotation names, so the pair of arms is
    // the only place the two types of the union are written at all. Reading
    // them off the arms is what the match binds its payload against; without
    // that the pair left a type-table row no later pass filled in, and the
    // whole crate was refused.
    const model = try analyze(arena_state.allocator(),
        \\pub fn owner_arm_payload_move(take: bool) -> String {
        \\    match if take {
        \\        Ok(String::from("moved"))
        \\    } else {
        \\        Err(3u8)
        \\    } {
        \\        Ok(inner) => inner,
        \\        Err(_) => String::from("other"),
        \\    }
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectStringU8Pair(&model);
}

test "the same unannotated pair over primitives carries u32 and u8" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Nothing but integers here, so the pair cannot be short of a type because
    // `String` or `Vec` was the shape that was missing.
    const model = try analyze(arena_state.allocator(),
        \\pub fn p(take: bool) -> u32 {
        \\    match if take {
        \\        Ok(7u32)
        \\    } else {
        \\        Err(1u8)
        \\    } {
        \\        Ok(x) => x,
        \\        Err(_) => 0u32,
        \\    }
        \\}
    );
    try ir.validateForTranslation(&model);
    const ok = singleVariantResult(&model, "Ok") orelse return error.NoOkConstruction;
    const err = singleVariantResult(&model, "Err") orelse return error.NoErrConstruction;
    try expectArmCarried(ok, .{ .prim = .u32 }, .{ .prim = .u8 });
    try expectArmCarried(err, .{ .prim = .u32 }, .{ .prim = .u8 });
}

test "a Result bound from an unannotated conditional carries its pair to the match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Same pair, one binding further out: the conditional is what the `let`
    // takes, and the binding is what the match reads, so the identity has to
    // survive the hop rather than stop at the arms.
    const model = try analyze(arena_state.allocator(),
        \\pub fn p(take: bool) -> String {
        \\    let r = if take {
        \\        Ok(String::from("held"))
        \\    } else {
        \\        Err(5u8)
        \\    };
        \\    match r {
        \\        Ok(x) => x,
        \\        Err(_) => String::from("other"),
        \\    }
        \\}
    );
    try ir.validateForTranslation(&model);
    try expectStringU8Pair(&model);
}

test "an unannotated Result pair carries the element a vec! payload holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn p(take: bool) -> u32 {
        \\    match if take {
        \\        Ok(vec![1u8])
        \\    } else {
        \\        Err(1u8)
        \\    } {
        \\        Ok(_) => 0u32,
        \\        Err(_) => 0u32,
        \\    }
        \\}
    );
    const vector: types.Type = .{ .external_nominal = .{
        .path = &.{ "alloc", "vec", "Vec" },
        .args = &.{.{ .prim = .u8 }},
    } };
    const ok = singleVariantResult(&model, "Ok") orelse return error.NoOkConstruction;
    const err = singleVariantResult(&model, "Err") orelse return error.NoErrConstruction;
    try expectArmCarried(ok, vector, .{ .prim = .u8 });
    try expectArmCarried(err, vector, .{ .prim = .u8 });
}

test "an unannotated Result pair carries the slice a borrow payload holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn p(bytes: &[u8], take: bool) -> u32 {
        \\    match if take {
        \\        Ok(bytes)
        \\    } else {
        \\        Err(1u8)
        \\    } {
        \\        Ok(_) => 0u32,
        \\        Err(_) => 1u32,
        \\    }
        \\}
    );
    const ok = singleVariantResult(&model, "Ok") orelse return error.NoOkConstruction;
    const err = singleVariantResult(&model, "Err") orelse return error.NoErrConstruction;
    try expectBorrowedU8Slice(ok.ok);
    try expectBorrowedU8Slice(err.ok);
    try expectU8(ok.err);
    try expectU8(err.err);
}

test "an unannotated Result pair carries the type parameter its payload holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try analyze(arena_state.allocator(),
        \\pub fn p<T>(value: T, take: bool) -> u32 {
        \\    match if take {
        \\        Ok(value)
        \\    } else {
        \\        Err(1u8)
        \\    } {
        \\        Ok(_) => 0u32,
        \\        Err(_) => 1u32,
        \\    }
        \\}
    );
    const ok = singleVariantResult(&model, "Ok") orelse return error.NoOkConstruction;
    const err = singleVariantResult(&model, "Err") orelse return error.NoErrConstruction;
    try expectTypeParameter(ok.ok, "T");
    try expectTypeParameter(err.ok, "T");
    try expectU8(ok.err);
    try expectU8(err.err);
}

/// The external nominal `ty` names, or an error naming the shape it is not.
fn expectExternalPath(ty: types.Type, wanted: []const []const u8) !types.ExternalNominal {
    const external = switch (ty) {
        .external_nominal => |value| value,
        else => return error.NotAnExternalNominal,
    };
    if (external.path.len != wanted.len) return error.WrongExternalPath;
    for (external.path, wanted) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) return error.WrongExternalPath;
    }
    return external;
}

/// The declared type of one struct field, read from the field itself.
fn declaredFieldType(model: *const ir.RustIr, name: []const u8) ?types.Type {
    for (model.bodies.bodies) |body| {
        const structure = switch (body) {
            .struct_ => |value| value,
            else => continue,
        };
        for (structure.fields) |field| {
            if (!std.mem.eql(u8, field.name, name)) continue;
            return field.ty;
        }
    }
    return null;
}

test "a container type binds every argument its deferred head carries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `Vec` names the standard library's own container, which no entity in this
    // crate declares, so a bare `Vec<..>` head is DEFERRED: `mapNamedType` waits
    // for the complete graph before it can say what the head names, because a
    // declaration written further down the file outranks the standard name. An
    // argument that comes out of that wait still carrying a bare name is a name
    // no entity backs, and the external nominal that carries one is exactly
    // what `UnresolvedTypePath` refuses.
    const model = try analyze(arena_state.allocator(),
        \\pub struct Elem { pub v: u8 }
        \\pub struct Holder {
        \\    pub over_string: Vec<String>,
        \\    pub over_primitive: Vec<u8>,
        \\    pub over_local: Vec<Elem>,
        \\    pub nested: Option<Vec<String>>,
        \\    pub doubled: Vec<Vec<u8>>,
        \\}
        \\pub fn unused() -> u8 { 0u8 }
    );
    try ir.validateForTranslation(&model);

    const strings = try expectExternalPath(
        declaredFieldType(&model, "over_string") orelse return error.NoOverStringField,
        &.{ "alloc", "vec", "Vec" },
    );
    if (strings.args.len != 1) return error.WrongArgumentCount;
    _ = try expectExternalPath(strings.args[0], &.{ "alloc", "string", "String" });

    const primitives = try expectExternalPath(
        declaredFieldType(&model, "over_primitive") orelse return error.NoOverPrimitiveField,
        &.{ "alloc", "vec", "Vec" },
    );
    if (primitives.args.len != 1) return error.WrongArgumentCount;
    try expectPrim(primitives.args[0], .u8);

    // The local declaration is the argument the prelude cannot supply, so this
    // is where a binder that resolves only the head leaves a name behind.
    const over_local = try expectExternalPath(
        declaredFieldType(&model, "over_local") orelse return error.NoOverLocalField,
        &.{ "alloc", "vec", "Vec" },
    );
    if (over_local.args.len != 1) return error.WrongArgumentCount;
    const local_argument = switch (over_local.args[0]) {
        .path => |value| value,
        else => return error.LocalArgumentIsNotANominal,
    };
    if (local_argument.segments.len != 1) return error.LocalArgumentIsNotASingleSegment;
    const local_id = local_argument.segments[0].id orelse return error.LocalArgumentHasNoEntity;
    const local_entity = model.graph.symbol_table.get(local_id) orelse
        return error.LocalArgumentNamesNoEntity;
    try testing.expectEqualStrings("Elem", local_entity.name);

    const nested = declaredFieldType(&model, "nested") orelse return error.NoNestedField;
    const nested_payload = switch (nested) {
        .option => |inner| inner.*,
        else => return error.NestedIsNotAnOption,
    };
    const nested_vector = try expectExternalPath(nested_payload, &.{ "alloc", "vec", "Vec" });
    if (nested_vector.args.len != 1) return error.WrongArgumentCount;
    _ = try expectExternalPath(nested_vector.args[0], &.{ "alloc", "string", "String" });

    const doubled = try expectExternalPath(
        declaredFieldType(&model, "doubled") orelse return error.NoDoubledField,
        &.{ "alloc", "vec", "Vec" },
    );
    if (doubled.args.len != 1) return error.WrongArgumentCount;
    const doubled_inner = try expectExternalPath(doubled.args[0], &.{ "alloc", "vec", "Vec" });
    if (doubled_inner.args.len != 1) return error.WrongArgumentCount;
    try expectPrim(doubled_inner.args[0], .u8);
}

/// One standard-container constructor as this translator declared it.
const DeclaredCtor = struct {
    ret: types.Type,
    param_count: usize,
    type_param_count: usize,
};

/// The declaration `root::module::name` carries, or null when there is none.
///
/// A standard declaration lives under the module chain the standard library
/// publishes it in, and the function's parent is that chain's last module — not
/// the owner type, because no entity stands for a type outside this crate. The
/// snippet's own calls are what put it there, so a call that fell back to a
/// refusal leaves nothing to find, and two declarations under one chain answer
/// null rather than letting the test read whichever came first.
fn declaredConstructor(
    model: *const ir.RustIr,
    root: []const u8,
    module_name: []const u8,
    name: []const u8,
) ?DeclaredCtor {
    var found: ?DeclaredCtor = null;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .fn_) continue;
        if (!std.mem.eql(u8, entity.name, name)) continue;
        const module_id = entity.parent orelse continue;
        const module_entity = model.graph.symbol_table.get(module_id) orelse continue;
        if (!std.mem.eql(u8, module_entity.name, module_name)) continue;
        const root_id = module_entity.parent orelse continue;
        const root_entity = model.graph.symbol_table.get(root_id) orelse continue;
        if (!std.mem.eql(u8, root_entity.name, root)) continue;
        if (entity.id >= model.bodies.bodies.len) continue;
        const body = switch (model.bodies.bodies[entity.id]) {
            .fn_ => |value| value,
            else => continue,
        };
        if (found != null) return null;
        found = .{
            .ret = body.ret,
            .param_count = body.params.len,
            .type_param_count = body.generic_params.len,
        };
    }
    return found;
}

/// The element type `Vec::new` leaves open, which is its own `T` and nothing
/// else: the call writes no argument, so a fixed element would be a guess.
fn expectOpenTypeParameter(ty: types.Type, name: []const u8) !void {
    const path = switch (ty) {
        .path => |value| value,
        else => return error.NotAnOpenParameter,
    };
    if (path.segments.len != 1) return error.NotASingleSegmentPath;
    if (!std.mem.eql(u8, path.segments[0].name, name)) return error.WrongTypeParameter;
    if (path.segments[0].id != null) return error.OpenParameterHasAnEntity;
}

fn expectNoUnresolvedCalls(model: *const ir.RustIr) !void {
    for (model.bodies.exprs) |expression| {
        if (expression.kind != .unsupported) continue;
        if (!std.mem.eql(u8, expression.kind.unsupported.reason, "unresolved call")) continue;
        return error.CallStillRefused;
    }
}

test "a standard container's constructor lowers with the signature std declares" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The TYPE side of each of these declarations already resolved before this
    // wave; what did not resolve is the CALL through a standard container. Each
    // one is declared here with the signature the standard library states, and
    // the test reads that signature back out of the graph rather than accepting
    // the call as "not refused".
    const model = try analyze(arena_state.allocator(),
        \\use std::collections::HashMap;
        \\pub fn empty() -> String { String::new() }
        \\pub fn copied() -> String { String::from("a") }
        \\pub fn vector() -> Vec<u8> { Vec::new() }
        \\pub fn rooted() -> Vec<u8> { std::vec::Vec::new() }
        \\pub fn mapped() -> HashMap<String, u8> { HashMap::new() }
    );
    try expectNoUnresolvedCalls(&model);

    // `impl String { pub const fn new() -> String }`
    const empty = declaredConstructor(&model, "alloc", "string", "new") orelse
        return error.NoDeclaredStringNew;
    if (empty.param_count != 0 or empty.type_param_count != 0) {
        return error.StringNewIsNotTheDeclaredSignature;
    }
    const empty_result = try expectExternalPath(empty.ret, &.{ "alloc", "string", "String" });
    if (empty_result.args.len != 0) return error.StringNewIsGeneric;

    // `String::from(..)` is the `From` impl for `String`, and this translator
    // lowers it as the core conversion: whatever the argument is, the impl it
    // belongs to is the one for `String`, and that is the type argument.
    var conversions: usize = 0;
    for (model.bodies.exprs) |expression| {
        const call = switch (expression.kind) {
            .core_call => |value| value,
            else => continue,
        };
        if (call.function != .convert_from) continue;
        if (call.generic_args.len != 1) return error.ConversionHasNoTarget;
        const target = try expectExternalPath(
            call.generic_args[0],
            &.{ "alloc", "string", "String" },
        );
        if (target.args.len != 0) return error.StringConversionIsGeneric;
        conversions += 1;
    }
    if (conversions != 1) return error.NoDeclaredStringFrom;

    // `impl<T> Vec<T> { pub const fn new() -> Vec<T> }`
    const vector = declaredConstructor(&model, "alloc", "vec", "new") orelse
        return error.NoDeclaredVecNew;
    if (vector.param_count != 0 or vector.type_param_count != 1) {
        return error.VecNewIsNotTheDeclaredSignature;
    }
    const vector_result = try expectExternalPath(vector.ret, &.{ "alloc", "vec", "Vec" });
    if (vector_result.args.len != 1) return error.VecNewHasNoElementParameter;
    try expectOpenTypeParameter(vector_result.args[0], "T");

    // `impl<K, V> HashMap<K, V> { pub fn new() -> HashMap<K, V> }`
    const mapped = declaredConstructor(&model, "std", "collections", "new") orelse
        return error.NoDeclaredHashMapNew;
    if (mapped.param_count != 0 or mapped.type_param_count != 2) {
        return error.HashMapNewIsNotTheDeclaredSignature;
    }
    const mapped_result = try expectExternalPath(mapped.ret, &.{ "std", "collections", "HashMap" });
    if (mapped_result.args.len != 2) return error.HashMapNewHasNoKeyAndValue;
    try expectOpenTypeParameter(mapped_result.args[0], "K");
    try expectOpenTypeParameter(mapped_result.args[1], "V");
}

test "the alloc root of a container names the declaration the std root does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `std::vec::Vec` and `alloc::vec::Vec` are one item the standard library
    // publishes under both roots, so both spellings reach a constructor, and
    // the one each root declares states the signature the standard library
    // does — the same result either way, reached through one alias list rather
    // than a second table entry that could answer differently.
    const model = try analyze(arena_state.allocator(),
        \\pub fn rooted() -> Vec<u8> { std::vec::Vec::new() }
        \\pub fn allocated() -> Vec<u8> { alloc::vec::Vec::new() }
    );
    try expectNoUnresolvedCalls(&model);
    for ([_][]const u8{ "std", "alloc" }) |root| {
        const declared = declaredConstructor(&model, root, "vec", "new") orelse
            return error.ContainerConstructorIsNotDeclaredUnderBothRoots;
        if (declared.param_count != 0 or declared.type_param_count != 1) {
            return error.VecNewIsNotTheDeclaredSignature;
        }
        const result = try expectExternalPath(declared.ret, &.{ "alloc", "vec", "Vec" });
        if (result.args.len != 1) return error.VecNewHasNoElementParameter;
        try expectOpenTypeParameter(result.args[0], "T");
    }
}

test "a use that leads back into the module it came from terminates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // `b` re-exports what `a` re-exports and `a` re-exports what `b` publishes,
    // so naming `Alias` from either side walks straight back into the lookup
    // already in progress and no amount of descending decides it. The walk ends
    // on the pair it is already inside and answers null — what a path this crate
    // cannot decide gets everywhere else — instead of recursing until the stack
    // dies.
    //
    // The cycle is entered through `q`, where an undecided name can only cost a
    // refusal, and no TYPE here depends on it: a signature written over an
    // undecided name is refused outright, which is a fact about this fixture
    // rather than about the bound. `p` is here to show the rest of the crate
    // still resolves.
    const model = try analyze(arena_state.allocator(),
        \\mod a {
        \\    pub use crate::b::Alias;
        \\}
        \\mod b {
        \\    pub use crate::a::Alias;
        \\    pub struct Alias(pub u8);
        \\}
        \\pub fn p(x: u8) -> u8 { x }
        \\pub fn q() -> u8 {
        \\    let named = a::Alias(1u8);
        \\    let _ = named;
        \\    0u8
        \\}
    );
    // The declaration the re-exports name is still one declaration.
    var aliases: usize = 0;
    for (model.graph.symbol_table.entities.items) |entity| {
        if (entity.kind != .struct_) continue;
        if (!std.mem.eql(u8, entity.name, "Alias")) continue;
        aliases += 1;
    }
    try testing.expectEqual(@as(usize, 1), aliases);
    // The cycle really was entered: the call the walk could not decide is a
    // refusal, which is the answer this test is about.
    try testing.expect(refusedAny(&model));
}

/// Whether the snippet left any node refused at all.
fn refusedAny(model: *const ir.RustIr) bool {
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .unsupported) return true;
    }
    return false;
}

// `siphasher` is refused by no digit separator.
//
// The crate writes both of its upstream vector keys as
// `0x_07_06_05_04_03_02_01_00` and `0x_0f_0e_0d_0c_0b_0a_09_08` —
// `src/tests.rs:127-128`, `src/tests.rs:221-222`, `src/tests128.rs:50-51` and
// `src/tests128.rs:81-82`. `parseIntLiteral` handed that spelling straight to
// `std.fmt.parseInt`, which reads no separator at all, so each key came back
// as an `.unsupported` node whose reason blamed the literal's RANGE. That
// reason does not begin with `assertion:`, so `validate.zig`'s
// `rejectUnsupportedMarker` turned it into `error.UnsupportedExpression`.
//
// The keys live in `#[cfg(test)]` modules, which is the whole reason
// `--dump rustir` (include_tests = FALSE) reported the crate clean while
// `translate-rust` (include_tests = TRUE) refused it.
//
// This pins the fix at its own altitude: the two keys must be READ, with the
// values the crate documents, and no node anywhere in the crate may carry the
// false range refusal. What boundary the crate reaches after that is a
// question for the next run, not something this asserts.
test "pristine siphasher folds its underscore-separated vector keys to their documented values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/siphasher",
        .{ .include_tests = true },
    );

    // Both upstream tables are generated with these two keys, and each of the
    // four `#[test]`s writes the pair once.
    const key0: i128 = 506097522914230528; // 0x0706050403020100
    const key1: i128 = 1084818905618843912; // 0x0f0e0d0c0b0a0908
    var key0_rows: usize = 0;
    var key1_rows: usize = 0;
    for (model.bodies.exprs) |expression| {
        if (expression.kind == .unsupported) {
            const marker = expression.kind.unsupported;
            try testing.expect(!std.mem.eql(u8, marker.reason, "integer literal out of range"));
        }
        const integer = switch (expression.kind) {
            .literal => |literal| switch (literal) {
                .int => |value| value,
                else => continue,
            },
            else => continue,
        };
        if (integer.base != .hex) continue;
        if (integer.value == key0) key0_rows += 1;
        if (integer.value == key1) key1_rows += 1;
    }
    try testing.expect(key0_rows >= 4);
    try testing.expect(key1_rows >= 4);
}

// `atoi` reaches the backend: the frontend admits the whole crate.
//
// `test/e2e_test.zig`'s `refused_source_crates` row records `atoi` as
// `UnsupportedExpression` "an operator node the frontend marked `operator
// requires primitive operands`". That string is stamped into the crate's own
// expression table by the method pass, so a crate still carrying it could not
// clear `validateForTranslation` — which is the call `src/driver/pipeline.zig`
// makes at line 176, BEFORE `lowerRustIr` at line 177. Asserting that the
// validation passes is therefore the proof that `translate-rust` gets past
// the frontend and into the backend, which is where a refusal of this crate
// now has to come from.
//
// This also pins the row's own words: the node that reason names is gone, so
// the row's `stops_at` text can no longer describe the crate it is about.
test "pristine atoi reaches the backend with no operator refusal the frontend owns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/atoi",
        .{ .include_tests = true },
    );
    try ir.validateForTranslation(&model);
    try expectNothingLeftOpen(&model);
    for (model.bodies.exprs) |expression| {
        const marker = switch (expression.kind) {
            .unsupported => |value| value,
            else => continue,
        };
        try testing.expect(!std.mem.eql(u8, marker.reason, "operator requires primitive operands"));
    }
}

// `leb128` is refused by `use std;`, not by the dev-dependency re-export the
// refusal row names.
//
// The row says the crate stops because "`tests/quickchecks.rs` opens with
// `use quickcheck;`". That file is never read. `analyzeCrateWithOptions`
// starts at the manifest root (`src/lib.rs`) and follows `mod` declarations
// only — `cst.zig` resolves a child module to `<base_dir>/<name>.rs` or
// `<base_dir>/<name>/mod.rs` — and a Cargo `tests/` integration target is not
// reachable that way. `quickcheck` is unreachable a second way as well:
// `pipeline.zig:1063` builds `graph.Crate.deps` from `manifest.dependencies`
// alone, so a `[dev-dependencies]` entry never becomes an external root that
// `names.zig`'s `isExternalRootName` can answer for.
//
// The one external import the crate really carries is the single-segment
// `use std;` at `src/lib.rs:246`, inside its `#[cfg(test)] mod tests` — which
// is also why `--dump rustir` reported this crate clean. A one-segment
// `core`/`std`/`alloc` import is a name the target already has in scope, so
// the obstacle is representable and belongs to the lowerer, which is not
// this file's to change.
test "pristine leb128 refuses on `use std;` alone, and quickcheck is never analysed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try pipeline.analyzeCrateWithOptions(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/leb128",
        .{ .include_tests = true },
    );
    // `src/driver/pipeline.zig` validates before it lowers, so a crate that
    // refuses in the lowerer got past this call.
    try ir.validateForTranslation(&model);

    var single_segment: usize = 0;
    for (model.graph.uses.items) |use_decl| {
        const external = switch (use_decl.kind) {
            .external => |value| value,
            else => continue,
        };
        for (external.path) |segment| {
            try testing.expect(!std.mem.eql(u8, segment, "quickcheck"));
        }
        if (external.path.len != 1) continue;
        // The bare `std` root, imported by name and nothing more.
        try testing.expectEqualStrings("std", external.path[0]);
        try testing.expect(!use_decl.is_pub_export);
        single_segment += 1;
    }
    // `src/lib.rs:246` writes it once. Every other import in the crate is
    // `super::…`, a glob, or a two-segment `std::` path the lowerer admits.
    try testing.expectEqual(@as(usize, 1), single_segment);

    // The manifest does name `quickcheck`, and only as a dev dependency —
    // which is the whole of why no analysed path roots at it.
    const manifest = try @import("ingest.zig").loadCrateManifest(
        arena_state.allocator(),
        std.testing.io,
        "test/crates/leb128",
    );
    try testing.expectEqual(@as(usize, 0), manifest.dependencies.len);
    var dev_named = false;
    for (manifest.dev_dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.name, "quickcheck")) dev_named = true;
    }
    try testing.expect(dev_named);
}
