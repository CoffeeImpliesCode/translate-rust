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
