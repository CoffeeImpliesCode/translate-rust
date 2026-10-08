//! Explicit-allocation compatibility types for Rust `alloc` operations.
//!
//! Mapping contract:
//! * `alloc::vec::Vec<T>` maps to `r2z.alloc.Vec(T)`.
//! * `alloc::string::String` maps to `r2z.alloc.String`.
//! * `alloc::borrow::Cow<[T]>` maps to `r2z.alloc.CowSlice(T)`.
//! * `alloc::borrow::Cow<str>` maps to `r2z.alloc.CowStr`.
//!
//! No type here stores an allocator. `Vec` is an unmanaged list; `String` and
//! the owned arms of `CowSlice` and `CowStr` carry storage only, and every
//! fallible mutation and every release takes the allocator that made the
//! storage. A `Cow` in its borrowed arm names storage the caller still owns
//! and frees nothing.
//!
//! One owner, one release. Each owned value is released by exactly one
//! `deinit`, and the receiver is left empty afterwards, so a release that
//! reaches an already-released or moved-from value frees nothing. Assignment
//! copies the handle and not the storage. A copied `String` names the same
//! allocation, not another cleanup owner. Releasing both copies is a double free.
//! `clone` is the operation that produces an independent owner, and
//! `takeOwned` is the operation that transfers one.
//!
//! `dropTemporary` carries that same promise over every shape a translated
//! value arrives in, because it is the one release the emitter can emit for
//! an operand of unknown shape. It leaves whatever it released holding
//! nothing, so reaching one block twice frees the first time only. That
//! includes `Vec(T)`, whose own `deinit` leaves the descriptor `undefined`
//! rather than empty, and it includes every wrapper built over it: a wrapper
//! is idempotent exactly when its payloads are.
//!
//! Slices returned by `as_str`, `as_bytes`, `as_mut_str` and `as_ref` borrow
//! storage. They become invalid after `deinit` or a mutation that reallocates.
//! `into_bytes` transfers the buffer to a new vector owner and empties the String.

const std = @import("std");
const character = @import("character.zig");
const Result = @import("result.zig").Result;
/// A growable, explicitly allocator-threaded byte or element vector.
///
/// `Vec` is an unmanaged standard-library list. It never stores an allocator, so
/// every operation which can allocate takes the allocator at the call site.
pub fn Vec(comptime T: type) type {
    return std.ArrayList(T);
}

/// Drop a temporary runtime container, or the active owned payload of an
/// Option/Result wrapper. `value` must point at uniquely owned storage created
/// with `gpa`; borrowed pointers and slices are never followed or freed.
///
/// The runtime has a release for the containers it maps, so the types this
/// helper frees are fixed: `String`, `FromUtf8Error`, `Vec(T)`, owned `Cow`
/// arms, tuples, arrays, and active tagged-union, `Option`, or error-union
/// payloads. A container releases its elements before releasing itself.
/// Non-owning elements generate no loop. Borrowed pointers and slices, foreign
/// named structs, and untagged unions are never followed. Only known runtime
/// containers are released; no foreign or user destructor is called.
///
/// The release is idempotent. A second call on the same block frees nothing,
/// whatever the first one reached: a container this file owns ends at its own
/// `empty`, and a wrapper ends because the payload under its active tag does.
/// A tag, a borrow, and a scalar are descriptors rather than owners and are
/// never rewritten, so a released union keeps naming an arm whose payload now
/// holds nothing, and a second pass over that arm frees nothing either.
pub fn dropTemporary(gpa: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value.*);
    if (comptime !ownsTemporaryStorage(T)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |structure| {
            if (T == String or T == FromUtf8Error) {
                value.deinit(gpa);
            } else if (comptime vecElementType(T) != null) {
                // The `comptime` gate is what lets this body name `items`:
                // a struct that is not a vector has no such field.
                dropTemporaryElements(gpa, value.items);
                value.deinit(gpa);
                // `std.ArrayList.deinit` leaves the receiver `undefined`
                // rather than empty, so without this a second release on the
                // same block would read that undefined descriptor and hand
                // the allocator a pointer it no longer owns. Resetting here
                // is what makes every wrapper below idempotent too: an option,
                // an error union, a tagged union, a fixed-length array and a
                // tuple are released exactly when their payloads are.
                value.* = .empty;
            } else if (comptime structure.is_tuple) {
                inline for (structure.fields) |field| {
                    if (!field.is_comptime) dropTemporary(gpa, &@field(value.*, field.name));
                }
            }
        },
        .@"union" => |union_type| {
            if (comptime T == CowStr or cowSliceElementType(T) != null) {
                switch (value.*) {
                    .Borrowed => {},
                    .Owned => |*payload| dropTemporary(gpa, payload),
                }
                value.* = .empty;
            } else if (comptime union_type.tag_type != null) {
                // The tag survives, because a tag describes the shape rather
                // than naming storage, and this file owns no empty arm to
                // rewrite it into. Idempotency comes from the payload: the
                // release leaves whatever it reached holding nothing, so the
                // arm this tag still names owns nothing, and a second pass
                // over that arm frees nothing either.
                switch (value.*) {
                    inline else => |*payload| dropTemporary(gpa, payload),
                }
            }
        },
        .array => |array| {
            // A fixed-length list holds its elements where they stand, so the
            // rule that releases a vector's elements applies to them as well.
            dropTemporaryElements(gpa, @as([]array.child, value));
        },
        .optional => {
            if (value.*) |*payload| dropTemporary(gpa, payload);
        },
        .error_union => {
            if (value.*) |*payload| {
                dropTemporary(gpa, payload);
            } else |_| {}
        },
        else => {},
    }
}

/// Hand a runtime container's storage, or the owner storage inside a finite
/// wrapper, to a new owner and empty the source.
///
/// A translated Rust move passes an owned payload by value, so the destination
/// becomes the sole owner of the allocation and the source must not release it
/// a second time. The transfer is the descriptor itself: no byte is copied and
/// nothing is allocated. A moved container is reset to the empty state the same
/// container writes when it releases storage, and a moved wrapper is emptied in
/// place, one reachable field at a time, rather than by building a second
/// wrapper of empties. A `defer` the source scope still runs therefore finds
/// nothing to free, and the new owner is freed exactly once.
///
/// The movable types are a finite set, because only storage this file owns has
/// a state to reset. The roots are the containers it owns — `String`, `Vec(T)`,
/// `CowStr`, `CowSlice(T)`, and `FromUtf8Error` — and the finite wrappers built
/// over them: a tuple, a fixed-length array, an optional, an error union, and
/// the runtime `Result`. A wrapper qualifies only when one of its fields
/// reaches a container, so a value owning no storage is not mistaken for a
/// move. A borrowed `Cow` moves as well; it hands over a pointer, and neither
/// the source nor the owner ever frees the input.
///
/// Inside a moved wrapper only the reachable owner storage is rewritten. A
/// borrow and a scalar keep their values, and an optional, an error union, and
/// the runtime `Result` keep whichever arm was active, because a tag describes
/// the shape rather than naming storage. Every other root is a compile error,
/// not a copy that quietly leaves the source owning the payload, and a nested
/// tagged union this file does not own is refused for the same reason: a
/// release would follow its active payload, so a move that left that payload
/// standing would give one allocation two owners.
pub fn takeOwned(comptime T: type, source: *T) T {
    if (comptime !supportsOwnedMove(T)) @compileError(
        "takeOwned moves r2z.alloc.String, r2z.alloc.Vec(T), r2z.alloc.CowStr, " ++
            "r2z.alloc.CowSlice(T), r2z.alloc.FromUtf8Error, and a finite wrapper " ++
            "built over them (a tuple, a fixed-length array, an optional, an " ++
            "error union, or the runtime Result), not " ++ @typeName(T),
    );
    const owner = source.*;
    resetMovedFrom(T, source);
    return owner;
}

/// The runtime containers `takeOwned` moves.
const OwnedContainer = enum {
    string,
    vec,
    cow_str,
    cow_slice,
    utf8_error,
};

/// The kind of runtime container `T` is, or null for a type this file does not
/// own.
///
/// Identity decides, not shape: `String`, `CowStr`, and `FromUtf8Error` are the
/// exact types declared here, `Vec(T)` is the list `Vec` builds, and a
/// `CowSlice(T)` is the union `CowSlice` builds. A user struct carrying a
/// vector, a borrowed slice, or a method named `deinit` is none of them, so a
/// move of one is refused rather than faked.
fn ownedContainerKind(comptime T: type) ?OwnedContainer {
    if (T == String) return .string;
    if (T == CowStr) return .cow_str;
    if (T == FromUtf8Error) return .utf8_error;
    if (comptime vecElementType(T) != null) return .vec;
    if (comptime cowSliceElementType(T) != null) return .cow_slice;
    return null;
}

/// True when a release follows an active payload of `T` that this file owns no
/// moved-from state for, at any depth a move would walk.
///
/// A tagged union a user declared is refused by `resetMovedFrom`, because a
/// release reaches its active payload and naming that payload's moved-from
/// state is not this file's to do. A wrapper that holds one beside an owner it
/// could hand over is refused with it, because the move visits every reachable
/// field rather than the first one that answers. A union with no owned arm
/// anywhere is not one of these: nothing for a release to follow, so a move
/// over it carries a descriptor and nothing else. The runtime containers and
/// the runtime `Result` are excluded here; each names its own empty state.
fn carriesUnmovedOwner(comptime T: type) bool {
    if (comptime ownedContainerKind(T) != null) return false;
    return switch (@typeInfo(T)) {
        .@"struct" => |structure| fields: {
            if (!structure.is_tuple) break :fields false;
            // `inline`, because the recursive call takes `comptime T` and this
            // only ever runs at comptime: a runtime loop would have to make the
            // field type a value.
            inline for (structure.fields) |field| {
                if (field.is_comptime) continue;
                if (carriesUnmovedOwner(field.type)) break :fields true;
            }
            break :fields false;
        },
        .array => |array| array.len != 0 and carriesUnmovedOwner(array.child),
        .optional => |optional| carriesUnmovedOwner(optional.child),
        .error_union => |error_union| carriesUnmovedOwner(error_union.payload),
        .@"union" => |union_type| arms: {
            // A user union is refused exactly when a release follows its active
            // payload, which is the same question `resetMovedFrom` asks before
            // it refuses. The runtime `Result` names a moved-from state for each
            // arm, so its answer comes from the arms themselves.
            if (!isOwnedVecResult(T)) break :arms ownsTemporaryStorage(T);
            inline for (union_type.fields) |field| {
                if (carriesUnmovedOwner(field.type)) break :arms true;
            }
            break :arms false;
        },
        else => false,
    };
}

/// True when `takeOwned` can hand `T` over: a runtime container, or a finite
/// wrapper built over one.
///
/// The finite wrappers are the shapes whose reachable owner storage this file
/// can name a moved-from state for, and whose shape survives the move: a
/// tuple, a fixed-length array, an optional, an error union, and the runtime
/// `Result` — the last only when it is the one `Result` builds, so a user union
/// with equal arm names does not acquire a move. A wrapper qualifies only when
/// one of its fields reaches a container, so an unowned tuple or scalar
/// wrapper is refused rather than copied, and it is refused when any field it
/// holds is a tagged union no moved-from state can be named for, even beside a
/// container it could hand over. Identity decides for the containers, and the
/// recursion decides for the wrappers.
fn isFiniteOwnedMove(comptime T: type) bool {
    // The question is what the move does, and the move rewrites every reachable
    // field. A wrapper holding one tagged union this file cannot empty is
    // therefore refused even when another field is an owner it could hand over:
    // answering true here would leave `takeOwned` refusing the very type its own
    // capability gate accepted, which is the one answer a caller cannot recover
    // from, because the refusal is a compile error rather than a false branch.
    //
    // This is a property of the WHOLE shape, so it is decided here, once, at the
    // top. The walk below asks only whether some field reaches a container, and
    // never re-enters this check.
    if (comptime carriesUnmovedOwner(T)) return false;
    return isFiniteOwnedShape(T);
}

/// True when `T` is a runtime container, or some reachable field of it is.
///
/// This is the permission half of the capability question, and it is the only
/// part the recursion needs: the refusal half is a property of the whole shape
/// and `isFiniteOwnedMove` decides it before calling here.
fn isFiniteOwnedShape(comptime T: type) bool {
    if (comptime ownedContainerKind(T) != null) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |structure| tuple: {
            if (!structure.is_tuple) break :tuple false;
            inline for (structure.fields) |field| {
                if (field.is_comptime) continue;
                if (isFiniteOwnedShape(field.type)) break :tuple true;
            }
            break :tuple false;
        },
        .array => |array| array.len != 0 and isFiniteOwnedShape(array.child),
        .optional => |optional| isFiniteOwnedShape(optional.child),
        .error_union => |error_union| isFiniteOwnedShape(error_union.payload),
        .@"union" => |union_type| wrapper: {
            if (!isOwnedVecResult(T)) break :wrapper false;
            inline for (union_type.fields) |field| {
                if (isFiniteOwnedShape(field.type)) break :wrapper true;
            }
            break :wrapper false;
        },
        else => false,
    };
}

/// True when `takeOwned` can hand a value of `T` over: one of the five runtime
/// containers, or a finite wrapper built over one.
///
/// This is a pure capability question answered while the branch is still a
/// branch. It allocates nothing, frees nothing, copies nothing, and installs no
/// destructor: the release a moved value still owns is `dropTemporary`, and the
/// transfer is still `takeOwned`. It answers true only for `String`, `Vec(T)`,
/// `CowStr`, `CowSlice(T)`, `FromUtf8Error`, and the finite wrappers over them —
/// a tuple, a fixed-length array, an optional, an error union, and the exact
/// runtime `Result` — where at least one field reaches a container.
///
/// Everything else answers false, and `takeOwned` keeps refusing it: a scalar, a
/// borrow, a slice or a raw pointer, a foreign named struct, an arbitrary user
/// tagged union, a `[0]` array, and any wrapper whose every field owns nothing.
/// A wrapper that holds such a union beside an owner it could hand over is
/// refused as well, so this gate never accepts a type the move itself refuses.
/// A false answer is not a licence to copy the value bitwise; a caller that
/// cannot move an owned type must not pretend that it did.
///
/// The `inline` and the `comptime` result are the point. The question is
/// decided before the code is generated, so the caller pays nothing for it and
/// the private recursion above is never reached at run time.
pub inline fn supportsOwnedMove(comptime T: type) bool {
    return comptime isFiniteOwnedMove(T);
}

/// Write the state a source holds once its reachable owner storage has been
/// handed over, in place and one field at a time.
///
/// Exactly the storage `dropTemporary` reaches is rewritten: every known
/// container becomes its own `empty`, and a wrapper keeps its shape, because a
/// borrow, a scalar, and an active tag are descriptors rather than owners and
/// stay as they were. A foreign named struct is one no release follows, so it
/// is one this move does not rewrite either. Nothing is allocated and no
/// payload byte is copied, so a source this ran over holds nothing a later
/// release can reach, and the descriptor returned by `takeOwned` is the only
/// owner left.
fn resetMovedFrom(comptime T: type, source: *T) void {
    if (comptime ownedContainerKind(T)) |kind| {
        source.* = switch (kind) {
            .string => String.empty,
            .cow_str => CowStr.empty,
            .utf8_error => FromUtf8Error.empty,
            // A vector and a byte `Cow` are types a generic function builds, so
            // each instantiation names its own empty state.
            .vec, .cow_slice => T.empty,
        };
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |structure| {
            if (comptime structure.is_tuple) {
                inline for (structure.fields) |field| {
                    if (field.is_comptime) continue;
                    resetMovedFrom(field.type, &@field(source.*, field.name));
                }
            }
        },
        .array => |array| {
            inline for (0..array.len) |index| resetMovedFrom(array.child, &source.*[index]);
        },
        .optional => |optional| {
            if (source.*) |*payload| resetMovedFrom(optional.child, payload);
        },
        .error_union => |error_union| {
            if (source.*) |*payload| {
                resetMovedFrom(error_union.payload, payload);
            } else |_| {}
        },
        .@"union" => {
            if (comptime !isOwnedVecResult(T)) {
                // A tagged union this file does not own still has an active
                // payload a release follows, and this file owns no way to name
                // that payload's moved-from state.
                if (comptime ownsTemporaryStorage(T)) @compileError(
                    "takeOwned cannot empty the active payload of " ++ @typeName(T) ++
                        ", which a release follows; move a runtime container, " ++
                        "or a tuple, array, optional, error union, or runtime " ++
                        "Result whose payloads are those",
                );
                // A union owning nothing is a descriptor this move carries.
                return;
            }
            switch (source.*) {
                inline else => |*payload, tag| {
                    resetMovedFrom(@FieldType(T, @tagName(tag)), payload);
                },
            }
        },
        else => {},
    }
}

/// The element type of a `CowSlice(E)`, or null for every other type.
///
/// The borrowed arm names the elements, and the answer only stands when the
/// whole union is the one `CowSlice` builds. A foreign union that also stores a
/// slice beside a vector is a user type: the runtime owns no release for it and
/// no empty state to move it into.
fn cowSliceElementType(comptime T: type) ?type {
    const union_type = switch (@typeInfo(T)) {
        .@"union" => |declared| declared,
        else => return null,
    };
    // An untagged union reports no active payload, so it holds nothing to move.
    if (union_type.tag_type == null) return null;
    for (union_type.fields) |field| {
        if (!std.mem.eql(u8, field.name, "Owned")) continue;
        const Element = vecElementType(field.type) orelse return null;
        if (T != CowSlice(Element)) return null;
        return Element;
    }
    return null;
}

/// The element type of a `Vec(T)`, or null for every other type.
///
/// The test is identity with the vector type, not a field shape. A foreign
/// struct that carries an `items` slice is not a runtime vector, and only a
/// runtime vector has a release this helper is allowed to run.
fn vecElementType(comptime T: type) ?type {
    const structure = switch (@typeInfo(T)) {
        .@"struct" => |declared| declared,
        else => return null,
    };
    for (structure.fields) |field| {
        const pointer = switch (@typeInfo(field.type)) {
            .pointer => |declared| declared,
            else => continue,
        };
        if (pointer.size == .slice and T == Vec(pointer.child)) return pointer.child;
    }
    return null;
}

/// True when a `Vec(T)` has a slab of its own to free.
///
/// A vector of zero-sized elements never allocates, so it holds no storage at
/// all. Every known owning element takes space, so a vector that owns
/// anything keeps answering true here.
fn vecOwnsSlab(comptime T: type) bool {
    const Element = vecElementType(T) orelse return false;
    return @sizeOf(Element) != 0;
}

/// Whether the shape of `T` can hold storage `dropTemporary` releases.
///
/// The comptime result is true for `String`, `FromUtf8Error`, and a `Vec` with
/// nonzero-sized elements; tuples with a qualifying non-comptime field;
/// nonempty arrays with a qualifying element; and optionals, error unions, or
/// tagged unions with any qualifying payload. This includes the owned `Cow`
/// arms. Empty values of these types still answer true.
///
/// Borrows, scalars, foreign named structs, and untagged unions answer false;
/// no user destructor is discovered. False is not a Rust Copy proof, and true
/// does not imply `supportsOwnedMove`: a user tagged union may be droppable
/// without having a moved-from state. Allocates nothing and changes no value.
pub inline fn ownsTemporaryStorage(comptime T: type) bool {
    if (T == String or T == FromUtf8Error) return true;
    if (comptime vecOwnsSlab(T)) return true;
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |structure| tuple: {
            if (!structure.is_tuple) break :tuple false;
            for (structure.fields) |field| {
                if (!field.is_comptime and ownsTemporaryStorage(field.type)) break :tuple true;
            }
            break :tuple false;
        },
        .array => |array| array.len != 0 and ownsTemporaryStorage(array.child),
        .optional => |optional| ownsTemporaryStorage(optional.child),
        .error_union => |error_union| ownsTemporaryStorage(error_union.payload),
        .@"union" => |union_type| variants: {
            if (union_type.tag_type == null) break :variants false;
            for (union_type.fields) |field| {
                if (ownsTemporaryStorage(field.type)) break :variants true;
            }
            break :variants false;
        },
        else => false,
    };
}

/// Release the storage the elements of a list hold, one element at a time.
///
/// The element type alone decides, and it is a compile-time type, so a list of
/// scalars, or of elements that take no space, frees its slab and nothing
/// else: the loop below is never generated for it.
fn dropTemporaryElements(gpa: std.mem.Allocator, items: anytype) void {
    const Element = @typeInfo(@TypeOf(items)).pointer.child;
    if (comptime ownsTemporaryStorage(Element)) {
        for (items) |*element| dropTemporary(gpa, element);
    }
}

/// The failures a `String` construction can report besides allocation:
/// `InvalidUtf8` when the input is not valid UTF-8, and the two `char`
/// encoding tags for a scalar value that cannot be encoded at all.
pub const StringError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

/// A UTF-8 validation failure that retains the original owned bytes.
///
/// The value owns `bytes` and is released by exactly one `deinit`, which
/// leaves it at `empty`. A copy shares the same allocation and is therefore a
/// second owner, so a second `deinit` is a double free; `takeOwned` moves the
/// bytes out instead. `empty` is the released and moved-from state and holds
/// no storage, so a release that reaches one frees nothing.
///
/// `detail` describes the bytes the value still holds; a caller that took the
/// bytes with `into_bytes` reads that detail itself.
pub const FromUtf8Error = struct {
    bytes: Vec(u8),
    detail: character.Utf8Error,

    /// The state a released or moved-from error holds: no bytes to release and
    /// no failure of its own to report.
    pub const empty: @This() = .{
        .bytes = .empty,
        .detail = .{ .valid_up_to = 0, .error_len = null },
    };

    /// The position and length of the first invalid sequence, describing the
    /// bytes this error still owns. A released error reports
    /// `.{ .valid_up_to = 0, .error_len = null }`, the `empty` detail.
    pub fn utf8_error(self: *const @This()) character.Utf8Error {
        return self.detail;
    }

    /// Transfer the invalid bytes to the caller and leave this error empty.
    ///
    /// The returned `Vec(u8)` carries the allocation the error owned, so the
    /// caller releases it exactly once and must not `deinit` the error for it
    /// afterwards. This error is empty when the call returns, on both the
    /// success and the failure path.
    pub fn into_bytes(self: *@This()) Vec(u8) {
        const bytes = self.bytes;
        self.* = .empty;
        return bytes;
    }

    /// Release the retained bytes once and leave this error empty.
    ///
    /// `gpa` must be the allocator that made `bytes`; a receiver that is
    /// already `empty`, or was moved from, frees nothing, so a `defer` that
    /// runs after a move is safe. The value is unusable as a failure after this
    /// call, and a second `deinit` on a non-empty copy is a double free.
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .empty;
    }
};

/// An owned, valid UTF-8 string.
///
/// `String` owns its byte slab, allocates nothing on its own, and stores no
/// allocator: every fallible mutation and `deinit` takes the allocator that
/// made the storage. One value has one owner, who calls `deinit` exactly
/// once. Assignment copies the handle and not the bytes, so a copied
/// `String` is a second owner of one allocation and a second `deinit` is a
/// double free — `from_str` builds an independent owner instead. The stable
/// address of the handle is not part of the contract: any operation that
/// reallocates may move the slab.
///
/// Every slice this type returns aliases that slab. It is invalidated by
/// `deinit` and by any mutation that reallocates — `push`, `push_str`,
/// `extend`, `reserve` — while `clear`, `as_str` and `as_bytes` do not move it.
///
/// `empty` is the released and moved-from state: it owns nothing, and both
/// `as_str` and `len` answer for it without an allocation.
pub const String = struct {
    bytes: Vec(u8) = .empty,

    pub const empty: String = .{ .bytes = .empty };

    /// Return an empty string with no allocation.
    pub fn new() String {
        return .empty;
    }

    /// Allocate an empty string with room for `capacity` bytes.
    pub fn with_capacity(
        gpa: std.mem.Allocator,
        capacity_bytes: usize,
    ) std.mem.Allocator.Error!String {
        return .{ .bytes = try Vec(u8).initCapacity(gpa, capacity_bytes) };
    }

    /// Copy a validated string into newly allocated owned storage.
    pub fn from_str(gpa: std.mem.Allocator, input: []const u8) StringError!String {
        if (character.validate_utf8(input)) |_| return error.InvalidUtf8;
        return .{ .bytes = try vec_from_slice(u8, gpa, input) };
    }

    /// Consume a vector and validate its bytes without copying.
    ///
    /// Both result branches own the consumed allocation. The input vector is
    /// reset before validation returns so it cannot be deinitialized twice.
    pub fn from_utf8(bytes: *Vec(u8)) Result(String, FromUtf8Error) {
        const owned = bytes.*;
        bytes.* = .empty;
        if (character.validate_utf8(owned.items)) |detail| {
            return .{ .Err = .{ .bytes = owned, .detail = detail } };
        }
        return .{ .Ok = .{ .bytes = owned } };
    }

    /// Consume a vector whose bytes are already known to be valid UTF-8.
    pub fn from_utf8_unchecked(bytes: *Vec(u8)) String {
        const owned = bytes.*;
        bytes.* = .empty;
        return .{ .bytes = owned };
    }

    /// Return a borrowed view when valid, otherwise allocate Rust-compatible
    /// maximal-subpart replacement output.
    pub fn from_utf8_lossy(gpa: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!CowStr {
        const first_error = character.validate_utf8(input) orelse {
            return .{ .Borrowed = input };
        };
        return .{ .Owned = .{ .bytes = try lossy_copy(gpa, input, first_error) } };
    }

    /// The bytes this string owns, as valid UTF-8. The slice aliases `bytes`
    /// and is invalidated by `deinit` or by a reallocating mutation.
    pub fn as_str(self: *const @This()) []const u8 {
        return self.bytes.items;
    }

    /// The bytes this string owns, without a UTF-8 claim. The slice aliases
    /// `bytes` on the same terms as `as_str`.
    pub fn as_bytes(self: *const @This()) []const u8 {
        return self.bytes.items;
    }

    /// Rust `Display for String`: write the owned bytes.
    ///
    /// This is the native Zig `{f}` hook as well, so the same receiver serves
    /// `std.Io.Writer.print` and `r2z.format.write`. The bytes are written in
    /// place; `writer` is borrowed for the call, retains nothing, and its own
    /// failure — including a short buffer — is returned unchanged, with the
    /// bytes written before it left in place.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.bytes.items);
    }

    /// Writes Rust's quoted and escaped `Debug` representation of this string.
    ///
    /// Borrows the writer without allocating or consuming storage. A writer
    /// failure leaves the already-written prefix in place.
    pub fn formatDebug(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try @import("format.zig").writeDebugString(writer, self.bytes.items);
    }

    /// Return a mutable view. The caller must preserve UTF-8 validity.
    ///
    /// The slice aliases `bytes`, so writing through it changes the string and
    /// it is invalidated by `deinit` or by a reallocating mutation.
    pub fn as_mut_str(self: *@This()) []u8 {
        return self.bytes.items;
    }

    /// Number of bytes held, which is also the number of UTF-8 scalar values
    /// only because a `String` is valid UTF-8.
    pub fn len(self: *const @This()) usize {
        return self.bytes.items.len;
    }

    /// Whether the string holds no bytes, which a released string always does.
    pub fn is_empty(self: *const @This()) bool {
        return self.bytes.items.len == 0;
    }

    /// Bytes the current slab can hold before it reallocates. `reserve` can
    /// raise it and nothing else lowers it, so it is not a length.
    pub fn capacity(self: *const @This()) usize {
        return self.bytes.capacity;
    }

    /// Make room for `additional` more bytes without changing the length.
    ///
    /// Reallocates when the current slab is too small, which invalidates every
    /// slice previously handed out. On `error.OutOfMemory` the string is
    /// exactly as it was, and `gpa` must be the allocator that made the slab.
    pub fn reserve(self: *@This(), gpa: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        try self.bytes.ensureUnusedCapacity(gpa, additional);
    }

    /// Drop every byte, keeping the slab for reuse. Invalidates every slice
    /// previously handed out, and never reallocates.
    pub fn clear(self: *@This()) void {
        self.bytes.clearRetainingCapacity();
    }

    /// Append one Unicode scalar value as UTF-8.
    ///
    /// Reallocates when the slab is too small, which invalidates every slice
    /// previously handed out. `error.InvalidUtf8`, `Utf8CannotEncodeSurrogateHalf`
    /// and `CodepointTooLarge` leave the string exactly as it was;
    /// `error.OutOfMemory` does too, and may leave the slab reallocated to its
    /// old contents.
    pub fn push(self: *@This(), gpa: std.mem.Allocator, codepoint: u21) StringError!void {
        var encoded: [4]u8 = undefined;
        const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
        try self.bytes.appendSlice(gpa, encoded[0..encoded_len]);
    }

    /// Append a UTF-8 chunk.
    ///
    /// `error.InvalidUtf8` is decided before anything is written, so the string
    /// is unchanged on that path. `error.OutOfMemory` leaves every byte
    /// appended before the failure in place, since the caller still owns the
    /// string either way.
    pub fn push_str(self: *@This(), gpa: std.mem.Allocator, input: []const u8) StringError!void {
        if (character.validate_utf8(input)) |_| return error.InvalidUtf8;
        try self.bytes.appendSlice(gpa, input);
    }

    /// Append either UTF-8 chunks (`[]const u8`) or Unicode scalar values
    /// (`u21`) from an iterator exposing `next()`.
    ///
    /// Items are appended straight into this string, so a reallocating item
    /// invalidates slices previously handed out. `error.OutOfMemory` leaves
    /// every item appended before the failure in place; an encoding error
    /// leaves them in place too and stops at that item.
    pub fn extend(self: *@This(), gpa: std.mem.Allocator, iterator: anytype) StringError!void {
        var it = iterator;
        while (it.next()) |item| {
            try append_string_item(self, gpa, item);
        }
    }

    /// Drain an iterator of `u21` or `[]const u8` into a new owned string.
    ///
    /// On any failure the partially built string is released before the error
    /// returns, so the caller owns nothing on the error path. The result is
    /// the caller's to release exactly once with `deinit(gpa)`.
    pub fn from_chars(gpa: std.mem.Allocator, iterator: anytype) StringError!String {
        var result: String = .empty;
        errdefer result.deinit(gpa);
        try result.extend(gpa, iterator);
        return result;
    }

    /// Transfer the backing vector and leave this string empty.
    ///
    /// The returned `Vec(u8)` carries the allocation this string owned, so the
    /// caller releases it exactly once and must not `deinit` the string for it
    /// afterwards. This string is empty when the call returns, so a `defer`
    /// that releases it frees nothing.
    pub fn into_bytes(self: *@This()) Vec(u8) {
        const bytes = self.bytes;
        self.* = .empty;
        return bytes;
    }

    /// Release the byte slab once and leave this string empty.
    ///
    /// `gpa` must be the allocator that made the slab. A receiver that is
    /// already empty, or was moved from by `into_bytes` or `takeOwned`, frees
    /// nothing, so a `defer` that runs after a move is safe. Every slice
    /// previously handed out is invalid afterwards, and a second `deinit`
    /// reached through a copy of a non-empty string is a double free.
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .empty;
    }
};

fn append_string_item(
    string: *String,
    gpa: std.mem.Allocator,
    item: anytype,
) StringError!void {
    const Item = @TypeOf(item);
    if (comptime Item == u21) {
        return string.push(gpa, item);
    }
    if (comptime (Item == []const u8 or Item == []u8)) {
        return string.push_str(gpa, item);
    }
    @compileError("String.extend expects an iterator of u21 or []const u8");
}

/// A borrowed or owned byte slice with explicit ownership transfer.
///
/// `Borrowed` names storage the caller still owns; this type neither frees it
/// nor keeps it alive. `Owned` owns a `Vec(T)` and is released by exactly one
/// `deinit`, which leaves the value at `empty`. Assignment copies the handle:
/// two copies of an owned `CowSlice` are two owners of one allocation, and a
/// second `deinit` is a double free. `clone` deep-copies into fresh storage and
/// `takeOwned` transfers one, and those are the two ways to obtain a second
/// independent owner.
///
/// `as_ref` returns a slice aliasing whichever arm is active — the caller's
/// input for `Borrowed`, this value's own slab for `Owned`. A returned slice
/// from the owned arm is invalidated by `deinit`, `into_owned`, and any
/// mutation of the underlying `Vec`.
pub fn CowSlice(comptime T: type) type {
    return union(enum) {
        Borrowed: []const T,
        Owned: Vec(T),

        const Self = @This();

        /// A borrow of nothing, which is the state a released or moved-from
        /// `Cow` holds: it names no storage, so releasing it frees nothing.
        pub const empty: Self = .{ .Borrowed = &.{} };

        /// Borrow `input` without allocating. The slice must stay alive and
        /// unmodified for as long as this value names it, and `deinit` frees
        /// nothing.
        pub fn from_borrowed(input: []const T) Self {
            return .{ .Borrowed = input };
        }

        /// Take over the vector's allocation and leave it empty.
        ///
        /// The caller must not release `bytes` afterwards: this value is now
        /// its only owner. `bytes` is empty when the call returns, so a `defer`
        /// that releases it frees nothing.
        pub fn from_owned(bytes: *Vec(T)) Self {
            const owned = bytes.*;
            bytes.* = .empty;
            return .{ .Owned = owned };
        }

        /// The elements this `Cow` currently names.
        ///
        /// The slice aliases the caller's input in the borrowed arm and this
        /// value's own slab in the owned arm; an owned view is invalidated by
        /// `deinit` and by `into_owned`.
        pub fn as_ref(self: *const Self) []const T {
            return switch (self.*) {
                .Borrowed => |bytes| bytes,
                .Owned => |*bytes| bytes.items,
            };
        }

        /// Copy this `Cow`, deep-copying owned storage and keeping a borrow a
        /// borrow.
        ///
        /// The borrowed arm keeps naming the caller's input, so copying it
        /// costs nothing and frees nothing. The owned arm is copied element for
        /// element into fresh storage, so copy and original release
        /// independently. Each element is cloned through the same finite clone
        /// domain `vec_repeat_owned` uses, so an element this runtime cannot
        /// clone is a compile error rather than a second descriptor for one
        /// allocation. A clone that runs out of room part way releases the
        /// elements it had already copied. The source is never consumed:
        /// `into_owned` is still the operation that transfers its allocation.
        pub fn clone(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return switch (self.*) {
                .Borrowed => |bytes| .{ .Borrowed = bytes },
                .Owned => |elements| owned: {
                    // The elements are cloned one at a time rather than copied.
                    // An owning element owns its storage through its
                    // descriptor, so a copied descriptor is a second owner of
                    // one allocation, and two owners release it twice.
                    var copy: Vec(T) = .empty;
                    // The errdefer releases the elements already stored before
                    // the slab they live in.
                    errdefer dropTemporary(gpa, &copy);
                    for (elements.items) |element| {
                        // The clone lands in a mutable local that releases itself
                        // if the vector cannot take it: appending may have to grow
                        // the slab first, and a failure there would otherwise leave
                        // this element with no owner at all, because the clone is
                        // made before `append` runs and nothing holds it yet. The
                        // binding has to be mutable — the release path empties the
                        // value it just freed.
                        var cloned = try cloneOwnedVecValue(T, gpa, element);
                        errdefer dropTemporary(gpa, &cloned);
                        try copy.append(gpa, cloned);
                    }
                    break :owned .{ .Owned = copy };
                },
            };
        }

        /// Return owned storage for this `Cow` and leave it empty.
        ///
        /// A borrowed arm copies its elements into a fresh allocation, so `gpa`
        /// is used and `error.OutOfMemory` leaves this value still borrowed and
        /// unchanged. Each borrowed element is copied through the same finite
        /// clone domain `clone` uses, because a copied descriptor would make the
        /// returned vector's release free the caller's bytes. An owned arm hands
        /// its allocation over without copying. Either way the returned `Vec(T)`
        /// is the caller's to release exactly once, and this value owns nothing
        /// afterwards.
        pub fn into_owned(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Vec(T) {
            return switch (self.*) {
                .Borrowed => |elements| blk: {
                    // The elements are the caller's, so they are copied rather
                    // than claimed: an owned vector of copied descriptors would
                    // free the caller's bytes when it is released. A conversion
                    // that runs out of room part way releases what it had
                    // already copied and leaves this value still borrowing.
                    var copy: Vec(T) = .empty;
                    // The errdefer releases the elements already stored before
                    // the slab they live in.
                    errdefer dropTemporary(gpa, &copy);
                    for (elements) |element| {
                        // The same local the clone arm uses, for the same reason:
                        // the element is cloned before `append` can grow the
                        // slab, so a failure there would orphan it.
                        var cloned = try cloneOwnedVecValue(T, gpa, element);
                        errdefer dropTemporary(gpa, &cloned);
                        try copy.append(gpa, cloned);
                    }
                    self.* = .empty;
                    break :blk copy;
                },
                .Owned => |*bytes| blk: {
                    const owned = bytes.*;
                    self.* = .empty;
                    break :blk owned;
                },
            };
        }

        /// Release owned elements once and leave this `Cow` empty.
        ///
        /// `gpa` must be the allocator that made the owned arm; a borrowed arm,
        /// a released value, and one moved from by `takeOwned` all free
        /// nothing, so a `defer` that runs after a move is safe. A second
        /// `deinit` reached through a copy of a non-empty owned value is a
        /// double free.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .Borrowed => {},
                .Owned => |elements| {
                    // The payload is taken by value and released through a
                    // mutable local. `dropTemporary` empties what it releases,
                    // so the descriptor it is handed cannot be a const one, and
                    // a payload captured by pointer from this switch is. The
                    // receiver is reset to `empty` below either way, so the copy
                    // released here leaves no stale slab behind.
                    var owned = elements;
                    dropTemporary(gpa, &owned);
                },
            }
            self.* = .empty;
        }
    };
}

/// A borrowed or owned valid UTF-8 string.
///
/// `Borrowed` names storage the caller still owns; this type neither frees it
/// nor keeps it alive. `Owned` owns a `String` and is released by exactly one
/// `deinit`, which leaves the value at `empty`. Assignment copies the handle:
/// two copies of an owned `CowStr` are two owners of one allocation, and a
/// second `deinit` is a double free. `clone` deep-copies into fresh storage
/// and `takeOwned` transfers one, and those are the two ways to obtain a
/// second independent owner.
///
/// `as_ref` returns a slice aliasing whichever arm is active — the caller's
/// input for `Borrowed`, this value's own slab for `Owned`. A returned slice
/// from the owned arm is invalidated by `deinit` and by `into_owned`.
pub const CowStr = union(enum) {
    Borrowed: []const u8,
    Owned: String,

    /// A borrow of nothing, which is the state a released or moved-from `Cow`
    /// holds: it names no storage, so releasing it frees nothing.
    pub const empty: @This() = .{ .Borrowed = &.{} };

    /// Borrow `input` without allocating. The slice must stay alive and
    /// unmodified for as long as this value names it, and `deinit` frees
    /// nothing.
    pub fn from_borrowed(input: []const u8) CowStr {
        return .{ .Borrowed = input };
    }

    /// Take over the string's allocation and leave it empty.
    ///
    /// The caller must not release `string` afterwards: this value is now its
    /// only owner. `string` is empty when the call returns, so a `defer` that
    /// releases it frees nothing.
    pub fn from_owned(string: *String) CowStr {
        const owned = string.*;
        string.* = .empty;
        return .{ .Owned = owned };
    }

    /// The bytes this `Cow` currently names.
    ///
    /// The slice aliases the caller's input in the borrowed arm and this
    /// value's own slab in the owned arm; an owned view is invalidated by
    /// `deinit` and by `into_owned`.
    pub fn as_ref(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Borrowed => |input| input,
            .Owned => |*string| string.as_bytes(),
        };
    }

    /// Rust `Display for Cow<str>`: write the bytes of the active arm.
    ///
    /// This is the native Zig `{f}` hook as well, so the same receiver serves
    /// `std.Io.Writer.print` and `r2z.format.write`. The bytes are written in
    /// place; `writer` is borrowed for the call, retains nothing, and its own
    /// failure — including a short buffer — is returned unchanged, with the
    /// bytes written before it left in place.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(switch (self) {
            .Borrowed => |input| input,
            .Owned => |string| string.bytes.items,
        });
    }

    /// Writes Rust's quoted and escaped `Debug` representation of either arm.
    ///
    /// The active arm and its ownership stay unchanged. A writer failure leaves
    /// the already-written prefix in place; rendering allocates no storage.
    pub fn formatDebug(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const bytes = switch (self) {
            .Borrowed => |input| input,
            .Owned => |string| string.bytes.items,
        };
        try @import("format.zig").writeDebugString(writer, bytes);
    }

    /// Copy this `Cow`, deep-copying owned storage and keeping a borrow a
    /// borrow.
    ///
    /// The borrowed arm keeps naming the caller's input, so copying it costs
    /// nothing and frees nothing. The owned arm is copied into fresh storage,
    /// so copy and original release independently and a write through one is
    /// invisible to the other. The source is never consumed: `into_owned` is
    /// still the operation that hands its allocation over.
    pub fn clone(self: *const @This(), gpa: std.mem.Allocator) std.mem.Allocator.Error!CowStr {
        return switch (self.*) {
            .Borrowed => |input| .{ .Borrowed = input },
            // Owned `CowStr` bytes are valid UTF-8 already, so the copy
            // revalidates nothing and can fail only on allocation.
            .Owned => |string| .{ .Owned = .{ .bytes = try vec_from_slice(u8, gpa, string.bytes.items) } },
        };
    }

    /// Return owned storage for this `Cow` and leave it empty.
    ///
    /// A borrowed arm is validated and copied into a fresh allocation, so
    /// `error.InvalidUtf8` and `error.OutOfMemory` leave this value still
    /// borrowed and unchanged. An owned arm hands its allocation over without
    /// copying. Either way the returned `String` is the caller's to release
    /// exactly once, and this value owns nothing afterwards.
    pub fn into_owned(self: *@This(), gpa: std.mem.Allocator) StringError!String {
        return switch (self.*) {
            .Borrowed => |input| blk: {
                const owned = try String.from_str(gpa, input);
                self.* = .empty;
                break :blk owned;
            },
            .Owned => |*string| blk: {
                const owned = string.*;
                self.* = .empty;
                break :blk owned;
            },
        };
    }

    /// Release owned bytes once and leave this `Cow` empty.
    ///
    /// `gpa` must be the allocator that made the owned arm; a borrowed arm, a
    /// released value, and one moved from by `takeOwned` all free nothing, so a
    /// `defer` that runs after a move is safe. A second `deinit` reached through
    /// a copy of a non-empty owned value is a double free.
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        switch (self.*) {
            .Borrowed => {},
            .Owned => |*string| string.deinit(gpa),
        }
        self.* = .empty;
    }
};

/// Convert a byte `Cow` to a strict UTF-8 `Cow` without allocating.
///
/// Invalid input leaves the original `CowSlice` untouched and returns the
/// Rust-compatible first-error detail. Valid owned bytes transfer directly.
pub fn cow_bytes_to_utf8(cow: *CowSlice(u8)) Result(CowStr, character.Utf8Error) {
    switch (cow.*) {
        .Borrowed => |input| {
            if (character.validate_utf8(input)) |detail| {
                return .{ .Err = detail };
            }
            return .{ .Ok = .{ .Borrowed = input } };
        },
        .Owned => |bytes| {
            if (character.validate_utf8(bytes.items)) |detail| {
                return .{ .Err = detail };
            }
            var moved = bytes;
            cow.* = .empty;
            return .{ .Ok = .{ .Owned = String.from_utf8_unchecked(&moved) } };
        },
    }
}

/// Convert a byte `Cow` to UTF-8 with Rust's maximal-subpart replacement.
///
/// Valid borrowed input remains borrowed. Valid owned input reuses its
/// allocation. Invalid owned input keeps the original allocation until the
/// replacement copy succeeds, then releases it exactly once.
pub fn cow_bytes_to_utf8_lossy(
    gpa: std.mem.Allocator,
    cow: *CowSlice(u8),
) std.mem.Allocator.Error!CowStr {
    switch (cow.*) {
        .Borrowed => |input| return String.from_utf8_lossy(gpa, input),
        .Owned => |bytes| {
            const first_error = character.validate_utf8(bytes.items) orelse {
                var moved = bytes;
                cow.* = .empty;
                return .{ .Owned = String.from_utf8_unchecked(&moved) };
            };

            const replacement = try lossy_copy(gpa, bytes.items, first_error);
            var original = bytes;
            original.deinit(gpa);
            cow.* = .empty;
            return .{ .Owned = .{ .bytes = replacement } };
        },
    }
}

/// Copy `input` into a new `Vec(T)` allocated from `gpa`.
///
/// `input` is borrowed for the call and is not retained, so it may be released
/// as soon as this returns. On `error.OutOfMemory` nothing is returned and
/// nothing is left allocated. The result is the caller's to release exactly
/// once with `deinit(gpa)`.
pub fn vec_from_slice(
    comptime T: type,
    gpa: std.mem.Allocator,
    input: []const T,
) std.mem.Allocator.Error!Vec(T) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, input);
    return result;
}

/// Append one transferred value. This call owns `item` from entry, including
/// on allocation failure; an OOM releases it without changing the destination's
/// initialized contents. Stage other fallible arguments before `takeOwned`.
pub fn vec_push_owned(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    item: T,
) std.mem.Allocator.Error!void {
    var transferred = item;
    errdefer dropTemporary(gpa, &transferred);
    try destination.append(gpa, transferred);
}

/// Build a vector from one transferred template, evaluated by the caller once.
/// This call consumes `item` on every outcome. Zero releases it without an
/// allocation; one moves it without cloning. Larger counts clone independently
/// into the initialized prefix and move the original into the last element.
/// An OOM releases the original, completed clones, and the vector slab.
pub fn vec_repeat_owned(
    comptime T: type,
    gpa: std.mem.Allocator,
    item: T,
    count: usize,
) std.mem.Allocator.Error!Vec(T) {
    var original = item;
    errdefer dropTemporary(gpa, &original);
    if (count == 0) {
        dropTemporary(gpa, &original);
        return .empty;
    }
    var result = try Vec(T).initCapacity(gpa, count);
    errdefer dropTemporary(gpa, &result);
    while (result.items.len < count - 1) {
        result.appendAssumeCapacity(try cloneOwnedVecValue(T, gpa, original));
    }
    result.appendAssumeCapacity(original);
    return result;
}

/// Only the runtime's Result is a cloneable tagged wrapper. A foreign union
/// with equally named arms does not acquire a runtime Clone implementation.
fn isOwnedVecResult(comptime T: type) bool {
    const union_type = switch (@typeInfo(T)) {
        .@"union" => |declared| declared,
        else => return false,
    };
    if (union_type.tag_type == null or union_type.fields.len != 2) return false;
    if (!std.mem.eql(u8, union_type.fields[0].name, "Ok") or
        !std.mem.eql(u8, union_type.fields[1].name, "Err")) return false;
    return T == Result(union_type.fields[0].type, union_type.fields[1].type);
}

/// Whether `T` is in the finite bitwise-copy subset used by owned Vec clones.
///
/// The comptime result accepts builtin booleans, integers, floats, error sets,
/// void, vectors, and immutable pointer/slice borrows; arrays, optionals, error
/// unions, and tuples whose payloads qualify; and this runtime's `Result` when
/// both arms qualify. Foreign named structs, user unions, untagged unions,
/// mutable borrows, and other shapes answer false.
///
/// This is not a general Rust Copy-trait query. False is not proof of ownership
/// or permission to drop a value. Allocates nothing and changes no value.
pub inline fn isOwnedVecCopy(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .bool, .int, .float, .error_set, .void, .vector => true,
        .pointer => |pointer| pointer.is_const,
        .array => |array| isOwnedVecCopy(array.child),
        .optional => |optional| isOwnedVecCopy(optional.child),
        .error_union => |error_union| isOwnedVecCopy(error_union.payload),
        .@"struct" => |structure| tuple: {
            if (!structure.is_tuple) break :tuple false;
            for (structure.fields) |field| {
                if (!field.is_comptime and !isOwnedVecCopy(field.type)) break :tuple false;
            }
            break :tuple true;
        },
        .@"union" => |union_type| wrapper: {
            if (!isOwnedVecResult(T)) break :wrapper false;
            for (union_type.fields) |field| {
                if (!isOwnedVecCopy(field.type)) break :wrapper false;
            }
            break :wrapper true;
        },
        else => false,
    };
}

/// Clone only finite runtime containers, structural wrappers, builtin Copy
/// values, and immutable borrows. No user Clone/deinit method is discovered,
/// and an unknown owner cannot silently become two descriptors for one slab.
fn cloneOwnedVecValue(comptime T: type, gpa: std.mem.Allocator, item: T) std.mem.Allocator.Error!T {
    if (comptime isOwnedVecCopy(T)) return item;
    if (comptime ownedContainerKind(T)) |kind| {
        return switch (kind) {
            .string => .{ .bytes = try vec_from_slice(u8, gpa, item.bytes.items) },
            .utf8_error => .{
                .bytes = try vec_from_slice(u8, gpa, item.bytes.items),
                .detail = item.detail,
            },
            .cow_str => switch (item) {
                .Borrowed => |borrowed| .{ .Borrowed = borrowed },
                .Owned => |owned| .{ .Owned = try cloneOwnedVecValue(String, gpa, owned) },
            },
            .cow_slice => switch (item) {
                .Borrowed => |borrowed| .{ .Borrowed = borrowed },
                .Owned => |owned| .{ .Owned = try cloneOwnedVecValue(Vec(cowSliceElementType(T).?), gpa, owned) },
            },
            .vec => vector: {
                const Element = vecElementType(T).?;
                var result = try T.initCapacity(gpa, item.items.len);
                errdefer dropTemporary(gpa, &result);
                if (comptime isOwnedVecCopy(Element)) {
                    result.appendSliceAssumeCapacity(item.items);
                } else {
                    for (item.items) |element| {
                        result.appendAssumeCapacity(try cloneOwnedVecValue(Element, gpa, element));
                    }
                }
                break :vector result;
            },
        };
    }
    switch (@typeInfo(T)) {
        .bool, .int, .float, .error_set, .void, .vector => return item,
        .pointer => |pointer| {
            if (pointer.is_const) return item;
        },
        .optional => |optional| {
            return if (item) |payload| try cloneOwnedVecValue(optional.child, gpa, payload) else null;
        },
        .error_union => |error_union| {
            if (item) |payload| {
                return @as(T, try cloneOwnedVecValue(error_union.payload, gpa, payload));
            } else |err| return @as(T, err);
        },
        .array => |array| {
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer {
                for (result[0..initialized]) |*element| dropTemporary(gpa, element);
            }
            for (item, 0..) |element, index| {
                result[index] = try cloneOwnedVecValue(array.child, gpa, element);
                initialized += 1;
            }
            return result;
        },
        .@"struct" => |structure| {
            if (comptime structure.is_tuple) {
                var result: T = undefined;
                var initialized: usize = 0;
                errdefer {
                    inline for (structure.fields, 0..) |field, index| {
                        if (!field.is_comptime and index < initialized) {
                            dropTemporary(gpa, &@field(result, field.name));
                        }
                    }
                }
                inline for (structure.fields, 0..) |field, index| {
                    if (!field.is_comptime) {
                        @field(result, field.name) = try cloneOwnedVecValue(field.type, gpa, @field(item, field.name));
                    }
                    initialized = index + 1;
                }
                return result;
            }
        },
        .@"union" => {
            if (comptime isOwnedVecResult(T)) {
                return switch (item) {
                    inline else => |payload, tag| @unionInit(T, @tagName(tag), try cloneOwnedVecValue(@TypeOf(payload), gpa, payload)),
                };
            }
        },
        else => {},
    }
    @compileError("vec_repeat_owned has no runtime Clone implementation for " ++ @typeName(T));
}

/// The element type of a slice, of a fixed-length array, or of a pointer to
/// one, or null for every other type.
///
/// Each of those names a run of elements a vector absorbs in one call, which is
/// what a by-value source of Rust's `extend` is. A pointer to an array counts
/// because that is the shape a byte string literal arrives in.
fn sequenceElementType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |array| array.child,
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

/// Drain an iterator of `T` into a new `Vec(T)` allocated from `gpa`.
///
/// Items are appended straight into the result, so a reallocating item leaves
/// earlier items in place. On `error.OutOfMemory` the partially built vector is
/// released before the error returns, so the caller owns nothing on the error
/// path. The result is the caller's to release exactly once with `deinit(gpa)`.
pub fn vec_collect(
    comptime T: type,
    gpa: std.mem.Allocator,
    iterator: anytype,
) std.mem.Allocator.Error!Vec(T) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    try vec_extend(T, gpa, &result, iterator);
    return result;
}

/// Append everything a source holds to a vector that may already hold items.
///
/// A slice, a fixed-length array, or a pointer to one (the shape a byte string
/// literal has) appends in one call. Anything exposing `next()` appends item by
/// item straight into the destination, so nothing is collected into a second
/// vector first and the elements already held are never copied. An allocation
/// failure returns `error.OutOfMemory` with every item appended so far still in
/// the destination: the caller owns that vector either way, so the runtime does
/// not release what it appended.
pub fn vec_extend(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    input: anytype,
) std.mem.Allocator.Error!void {
    const InputElement = comptime sequenceElementType(@TypeOf(input));
    if (comptime InputElement != null) {
        if (comptime InputElement.? != T) {
            @compileError("Vec extension input element type does not match the vector element type");
        }
        return destination.appendSlice(gpa, input[0..]);
    }
    var it = input;
    while (it.next()) |item| {
        try append_vec_element(T, gpa, destination, item);
    }
}

fn append_vec_element(
    comptime T: type,
    gpa: std.mem.Allocator,
    destination: *Vec(T),
    item: anytype,
) std.mem.Allocator.Error!void {
    if (comptime @TypeOf(item) != T) {
        @compileError("Vec extension item type does not match the vector element type");
    }
    try destination.append(gpa, item);
}

/// Drain an iterator of `Result(T, E)` into a new `Vec(T)`, stopping at the
/// first `Err`.
///
/// An `Err` item is returned as `.Err` and the values collected before it are
/// released first, so the caller owns nothing on that path and must not
/// release the vector. `error.OutOfMemory` releases the partial vector the same
/// way. The `.Ok` result is the caller's to release exactly once with
/// `deinit(gpa)`.
pub fn collect_result(
    comptime T: type,
    comptime E: type,
    gpa: std.mem.Allocator,
    iterator: anytype,
) std.mem.Allocator.Error!Result(Vec(T), E) {
    var result: Vec(T) = .empty;
    errdefer result.deinit(gpa);
    var it = iterator;
    while (it.next()) |item| {
        switch (item) {
            .Ok => |value| try result.append(gpa, value),
            .Err => |err| {
                result.deinit(gpa);
                return .{ .Err = err };
            },
        }
    }
    return .{ .Ok = result };
}

fn lossy_copy(
    gpa: std.mem.Allocator,
    input: []const u8,
    first_error: character.Utf8Error,
) std.mem.Allocator.Error!Vec(u8) {
    var result: Vec(u8) = .empty;
    errdefer result.deinit(gpa);
    var index: usize = 0;
    var invalid: ?character.Utf8Error = first_error;
    while (invalid) |detail| {
        std.debug.assert(detail.valid_up_to < input.len - index);
        try result.appendSlice(gpa, input[index..][0..detail.valid_up_to]);
        try result.appendSlice(gpa, std.unicode.replacement_character_utf8[0..]);
        index += detail.valid_up_to;
        const error_len = detail.error_len orelse {
            index = input.len;
            break;
        };
        std.debug.assert(error_len > 0);
        index += error_len;
        invalid = character.validate_utf8(input[index..]);
    }
    try result.appendSlice(gpa, input[index..]);
    return result;
}

const CollectError = enum { invalid };

const ResultByteIterator = struct {
    index: usize = 0,

    fn next(self: *@This()) ?Result(u8, CollectError) {
        const result: ?Result(u8, CollectError) = switch (self.index) {
            0 => .{ .Ok = 0x12 },
            1 => .{ .Err = .invalid },
            else => null,
        };
        self.index += 1;
        return result;
    }
};

/// A byte iterator over a literal, for the source `vec_extend` drains.
const ByteIterator = struct {
    items: []const u8,
    index: usize = 0,

    fn next(self: *@This()) ?u8 {
        if (self.index >= self.items.len) return null;
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }
};

test "temporary drop releases owned elements and active payloads but never follows borrows" {
    const gpa = std.testing.allocator;
    var nested: ?Result(String, String) = .{ .Err = try String.from_str(gpa, "owned error") };
    dropTemporary(gpa, &nested);
    var absent: ?Result(String, String) = null;
    dropTemporary(gpa, &absent);

    var success: error{Failed}!String = try String.from_str(gpa, "owned success");
    dropTemporary(gpa, &success);
    var failure: error{Failed}!String = error.Failed;
    dropTemporary(gpa, &failure);

    const UserValue = struct {
        number: u8,

        pub fn deinit(self: *@This()) void {
            self.number = 0;
        }
    };
    var unrelated: Result(String, UserValue) = .{ .Err = .{ .number = 7 } };
    dropTemporary(gpa, &unrelated);
    try std.testing.expectEqual(@as(u8, 7), unrelated.Err.number);

    var named = try String.from_str(gpa, "still owned");
    defer named.deinit(gpa);
    var reference = &named;
    dropTemporary(gpa, &reference);
    var slice = named.as_str();
    dropTemporary(gpa, &slice);
    try std.testing.expectEqualStrings("still owned", named.as_str());

    // A list releases what its own elements hold before it releases its slab.
    var strings: Vec(String) = .empty;
    try strings.append(gpa, try String.from_str(gpa, "first element"));
    try strings.append(gpa, try String.from_str(gpa, "second element"));
    dropTemporary(gpa, &strings);

    // An element that holds a wrapper releases only the payload that is active,
    // and an empty `Option` element releases nothing at all.
    var optional_elements: Vec(?String) = .empty;
    try optional_elements.append(gpa, try String.from_str(gpa, "present element"));
    try optional_elements.append(gpa, null);
    dropTemporary(gpa, &optional_elements);

    var result_elements: Vec(Result(String, String)) = .empty;
    try result_elements.append(gpa, .{ .Ok = try String.from_str(gpa, "ok element") });
    try result_elements.append(gpa, .{ .Err = try String.from_str(gpa, "err element") });
    dropTemporary(gpa, &result_elements);

    // A borrowed element names storage the caller still owns, so the owned
    // element beside it is the only one this helper releases.
    var moved = try String.from_str(gpa, "owned element");
    var cow_elements: Vec(CowStr) = .empty;
    try cow_elements.append(gpa, CowStr.from_borrowed("borrowed element"));
    try cow_elements.append(gpa, CowStr.from_owned(&moved));
    try std.testing.expectEqual(@as(usize, 0), moved.as_bytes().len);
    dropTemporary(gpa, &cow_elements);

    // A fixed-length list and a nested list are storage an element owns, so
    // they are released the way a top-level container is.
    var pairs: Vec([2]String) = .empty;
    try pairs.append(gpa, .{
        try String.from_str(gpa, "left element"),
        try String.from_str(gpa, "right element"),
    });
    dropTemporary(gpa, &pairs);

    var nested_lists: Vec(Vec(u8)) = .empty;
    try nested_lists.append(gpa, try vec_from_slice(u8, gpa, "inner element"));
    dropTemporary(gpa, &nested_lists);

    // A list of scalars frees its slab, and no element is walked.
    var bytes: Vec(u8) = .empty;
    try bytes.appendSlice(gpa, "no element to release");
    dropTemporary(gpa, &bytes);

    // An untagged union names no active payload, so nothing inside one is
    // released: the value it was built from stays the caller's to free.
    const Untagged = union { text: String, count: usize };
    var kept = try String.from_str(gpa, "untagged element");
    var untagged: Untagged = .{ .text = kept };
    dropTemporary(gpa, &untagged);
    var untagged_list: Vec(Untagged) = .empty;
    try untagged_list.append(gpa, .{ .text = kept });
    dropTemporary(gpa, &untagged_list);
    dropTemporary(gpa, &kept);
}

test "takeOwned hands a string to its owner and leaves the source nothing to free" {
    const gpa = std.testing.allocator;
    var owner = blk: {
        var source = try String.from_str(gpa, "take me");
        const allocation_address = @intFromPtr(source.as_bytes().ptr);

        const moved = takeOwned(String, &source);
        try std.testing.expectEqual(@as(usize, 0), source.as_bytes().len);
        try std.testing.expectEqual(@as(usize, 0), source.capacity());

        // The scope the source lived in still releases what it holds. Emptying
        // the descriptor is what keeps that release from freeing the storage
        // the owner is about to use.
        source.deinit(gpa);
        try std.testing.expectEqual(allocation_address, @intFromPtr(moved.as_bytes().ptr));
        break :blk moved;
    };
    defer owner.deinit(gpa);

    // The owner reads the bytes the source built, and writing through it reaches
    // the allocation that was moved instead of a copy of it.
    try std.testing.expectEqualStrings("take me", owner.as_str());
    owner.as_mut_str()[0] = 'T';
    try std.testing.expectEqualStrings("Take me", owner.as_str());
}

test "takeOwned hands a vector to its owner and keeps its elements writable" {
    const gpa = std.testing.allocator;
    var owner = blk: {
        var source = try vec_from_slice(u32, gpa, &.{ 1, 2, 3 });
        const allocation_address = @intFromPtr(source.items.ptr);

        const moved = takeOwned(Vec(u32), &source);
        try std.testing.expectEqual(@as(usize, 0), source.items.len);
        try std.testing.expectEqual(@as(usize, 0), source.capacity);
        source.deinit(gpa);
        try std.testing.expectEqual(allocation_address, @intFromPtr(moved.items.ptr));
        break :blk moved;
    };
    defer owner.deinit(gpa);

    owner.items[2] = 9;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 9 }, owner.items);
}

test "takeOwned transfers on the consuming branch and the other branch keeps its owner" {
    const gpa = std.testing.allocator;

    // The two arms of a translated conditional Rust move. Each arm builds a
    // payload and releases it where it stands, and only the consuming arm also
    // hands it to the destination. The empty source that arm leaves behind is
    // what stops its release from freeing the owner.
    const arms = [_]struct {
        payload: []const u8,
        consume: bool,
    }{
        .{ .payload = "consumed payload", .consume = true },
        .{ .payload = "retained payload", .consume = false },
    };
    for (arms) |arm| {
        var owner: ?String = null;
        {
            var source = try String.from_str(gpa, arm.payload);
            defer source.deinit(gpa);
            if (arm.consume) owner = takeOwned(String, &source);

            const expected_source_len = if (arm.consume) 0 else arm.payload.len;
            try std.testing.expectEqual(expected_source_len, source.as_str().len);
        }

        if (owner) |*moved| {
            defer moved.deinit(gpa);
            try std.testing.expect(arm.consume);
            try std.testing.expectEqualStrings(arm.payload, moved.as_str());
        } else {
            // The arm that did not consume still owned its payload and released
            // it at the end of its scope, so nothing survives to be moved.
            try std.testing.expect(!arm.consume);
        }
    }
}

test "takeOwned moves owned Cow storage and leaves a borrow a borrow" {
    const gpa = std.testing.allocator;

    // A borrowed `Cow` names storage this runtime does not own. The move hands
    // the pointer over and both values release nothing.
    const literal = "borrowed text";
    var borrow_source = CowStr.from_borrowed(literal);
    var borrow_owner = takeOwned(CowStr, &borrow_source);
    try std.testing.expectEqual(@as(usize, 0), borrow_source.as_ref().len);
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(borrow_owner.as_ref().ptr));
    borrow_owner.deinit(gpa);
    try std.testing.expectEqualStrings("borrowed text", literal);

    // An owned `Cow` hands its allocation over the way a `String` does, and the
    // emptied source it leaves behind releases nothing.
    var string = try String.from_str(gpa, "owned text");
    const owned_address = @intFromPtr(string.as_bytes().ptr);
    var owned_source = CowStr.from_owned(&string);
    var owned_owner = takeOwned(CowStr, &owned_source);
    try std.testing.expectEqual(@as(usize, 0), owned_source.as_ref().len);
    owned_source.deinit(gpa);
    try std.testing.expectEqual(owned_address, @intFromPtr(owned_owner.as_ref().ptr));
    try std.testing.expectEqualStrings("owned text", owned_owner.as_ref());
    owned_owner.deinit(gpa);

    // A byte `Cow` carries the same promise for the elements it owns.
    var numbers = try vec_from_slice(u32, gpa, &.{ 7, 8 });
    const numbers_address = @intFromPtr(numbers.items.ptr);
    var numbers_source = CowSlice(u32).from_owned(&numbers);
    var numbers_owner = takeOwned(CowSlice(u32), &numbers_source);
    try std.testing.expectEqualSlices(u32, &.{}, numbers_source.as_ref());
    numbers_source.deinit(gpa);
    try std.testing.expectEqual(numbers_address, @intFromPtr(numbers_owner.as_ref().ptr));
    switch (numbers_owner) {
        .Borrowed => return error.ExpectedOwnedCow,
        .Owned => |*owned| owned.items[0] = 11,
    }
    try std.testing.expectEqualSlices(u32, &.{ 11, 8 }, numbers_owner.as_ref());
    numbers_owner.deinit(gpa);
}

test "takeOwned moves the invalid bytes and keeps the UTF-8 detail" {
    const gpa = std.testing.allocator;

    var bytes = try vec_from_slice(u8, gpa, "ok\xf0\x90");
    var source = switch (String.from_utf8(&bytes)) {
        .Ok => return error.ExpectedInvalidUtf8,
        .Err => |invalid| invalid,
    };
    const allocation_address = @intFromPtr(source.bytes.items.ptr);

    var moved = takeOwned(FromUtf8Error, &source);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.capacity);
    // The emptied source is no longer a failure of its own, so a release
    // reaching it cannot free the bytes the owner holds.
    try std.testing.expectEqual(
        character.Utf8Error{ .valid_up_to = 0, .error_len = null },
        source.utf8_error(),
    );
    source.deinit(gpa);

    // The detail describes the bytes the owner now holds, so the move carries it
    // over instead of restating a failure of its own.
    try std.testing.expectEqual(allocation_address, @intFromPtr(moved.bytes.items.ptr));
    try std.testing.expectEqual(
        character.Utf8Error{ .valid_up_to = 2, .error_len = null },
        moved.utf8_error(),
    );
    moved.bytes.items[0] = 'O';
    try std.testing.expectEqualSlices(u8, "Ok\xf0\x90", moved.bytes.items);
    moved.deinit(gpa);
}

test "takeOwned accepts only the containers this runtime owns" {
    try std.testing.expectEqual(OwnedContainer.string, ownedContainerKind(String).?);
    try std.testing.expectEqual(OwnedContainer.vec, ownedContainerKind(Vec(u8)).?);
    try std.testing.expectEqual(OwnedContainer.cow_str, ownedContainerKind(CowStr).?);
    try std.testing.expectEqual(OwnedContainer.cow_slice, ownedContainerKind(CowSlice(u32)).?);
    try std.testing.expectEqual(OwnedContainer.utf8_error, ownedContainerKind(FromUtf8Error).?);

    // A user type that carries the same shape is not a runtime container, so a
    // move of one is refused at compile time instead of copying a payload the
    // source then frees a second time.
    const UserVector = struct { items: Vec(u8) };
    const UserList = struct {
        items: []const u8,
        capacity: usize,
    };
    const UserCow = union(enum) {
        Borrowed: []const u8,
        Owned: Vec(u8),
    };

    try std.testing.expect(ownedContainerKind(UserVector) == null);
    try std.testing.expect(ownedContainerKind(UserList) == null);
    try std.testing.expect(ownedContainerKind(UserCow) == null);
    try std.testing.expect(ownedContainerKind(u8) == null);
}

/// A borrow of storage the runtime does not own: what a translated `&str` and
/// `&[T]` arrive as. A move hands the address over and the borrow stays a
/// borrow. The type is named so the wrapper and the refused-root table below
/// name the same one.
const Borrow = []const u8;

/// A raw pointer is a descriptor the same way, and a move never writes through
/// it. Named for the same reason as `Borrow`.
const RawBorrow = *const u8;

/// A mutable pointer is a bare `*T` in this Zig; there is no `*mut` spelling.
const MutablePointer = *u32;

/// A shared pointer is a borrow of one cell: it is copied into every clone and
/// owns nothing. It is what a translated `&u32` is, and it is the pointer a
/// repetition fixture can use — `vec_repeat_owned` clones its template, and a
/// mutable pointer is an exclusive `&mut T` that Rust does not let `Clone`
/// touch, which this runtime refuses for the same reason.
const SharedPointer = *const u32;

/// A composed wrapper: a fixed-length array of optionals, the runtime
/// `Result`, an error union, a borrow, a mutable pointer, and a scalar. Only
/// the first three fields hold storage, so a move has to rewrite exactly those
/// and leave the rest standing.
const OwnerMoveTestTuple = @Tuple(&.{
    [2]?String,
    Result(String, String),
    error{Rejected}!String,
    Borrow,
    MutablePointer,
    u8,
});

/// The same composed wrapper with a shared pointer in the descriptor slot the
/// mutable pointer occupies above. Only the first three fields own storage in
/// either one; the difference is whether the pointer beside them can be cloned.
const OwnerCloneTestTuple = @Tuple(&.{
    [2]?String,
    Result(String, String),
    error{Rejected}!String,
    Borrow,
    SharedPointer,
    u8,
});

/// Three independent owners in one wrapper: the array's present element, the
/// `Result` error arm, and the error union's payload. `label` is the borrow the
/// wrapper carries beside them, and `cell` and the scalar beside that are
/// descriptors no release follows. `cell` is a real pointee rather than a null
/// pointer, so the pointer slot always names storage a caller can still read
/// after the transfer. `Wrapper` names the tuple to build, and `cell` must have
/// the type its fifth field declares.
fn makeOwnerTestWrapper(
    comptime Wrapper: type,
    gpa: std.mem.Allocator,
    label: Borrow,
    cell: anytype,
) !Wrapper {
    var array: [2]?String = .{ null, null };
    errdefer dropTemporary(gpa, &array);
    array[0] = try String.from_str(gpa, "array first");
    var result: Result(String, String) = .{ .Err = try String.from_str(gpa, "result error") };
    errdefer dropTemporary(gpa, &result);
    return .{
        array,
        result,
        @as(error{Rejected}!String, try String.from_str(gpa, "union success")),
        label,
        cell,
        7,
    };
}

/// The address every owner in a wrapper holds, read through it the way a scan
/// borrows it, so one wrapper and its clone are told apart without moving
/// anything out of it.
fn ownerTestAddresses(tuple: anytype) [3]usize {
    return .{
        @intFromPtr(tuple[0][0].?.as_bytes().ptr),
        @intFromPtr(tuple[1].Err.as_bytes().ptr),
        @intFromPtr((tuple[2] catch unreachable).as_bytes().ptr),
    };
}

/// How many bytes the wrapper's owners still carry, summed by borrowed
/// iteration. Reading it reaches through the array's present slot, the `Result`
/// arm, and the error union's payload, so a source whose owners were handed over
/// answers zero only because the active tags survived the move.
fn ownerTestTotal(tuple: anytype) usize {
    var total: usize = 0;
    for (tuple[0][0..]) |element| {
        if (element) |present| total += present.len();
    }
    total += tuple[1].Err.len();
    total += (tuple[2] catch unreachable).len();
    return total;
}

test "takeOwned accepts the containers and the finite wrappers built over them" {
    // These finite tables exercise the private walk and the inlined public
    // gate together, so their reflection work shares this test's comptime quota.
    @setEvalBranchQuota(10_000);

    const Accepted = .{
        String,
        Vec(String),
        CowStr,
        CowSlice(u32),
        FromUtf8Error,
        OwnerMoveTestTuple,
        [2]?String,
        ?String,
        error{Rejected}!String,
        Result(String, u8),
        Result(?String, String),
        @TypeOf(@as(@Tuple(&.{ Vec(u8), u8 }), undefined)),
    };
    inline for (Accepted) |T| try std.testing.expect(isFiniteOwnedMove(T));

    // The refused roots are the ones a move cannot describe: a value holding no
    // storage to hand over, a borrow that owns nothing, a foreign struct and a
    // user union this file owns no release or empty state for, and a wrapper
    // whose every field is such a value.
    const ForeignStruct = struct { text: String };
    const ForeignUnion = union(enum) {
        Owned: String,
        Empty: void,
    };
    const ScalarUnion = union(enum) {
        Left: u8,
        Right: Borrow,
    };
    const Refused = .{
        u8,
        bool,
        RawBorrow,
        MutablePointer,
        Borrow,
        ForeignStruct,
        ForeignUnion,
        ScalarUnion,
        @TypeOf(@as(@Tuple(&.{ u8, u8 }), undefined)),
        @TypeOf(@as(@Tuple(&.{ u8, Borrow }), undefined)),
        [0]String,
        Result(u8, u8),
        @TypeOf(@as(error{Rejected}!u8, error.Rejected)),
    };
    inline for (Refused) |T| try std.testing.expect(!isFiniteOwnedMove(T));

    // A wrapper holding one tagged union a release follows is refused whole,
    // because the move rewrites every field it reaches rather than the first
    // one that answers. These are the shapes a translated enum arrives in, and
    // the refusal is the answer that matters: the opposite one would leave
    // `takeOwned` raising a compile error on the very type its own gate had
    // accepted, which a caller cannot fall back from.
    const WrapperRefused = .{
        @TypeOf(@as(@Tuple(&.{ String, ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ Vec(u8), ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, u8, ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, CowStr, ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, ?ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, [2]ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, error{Rejected}!ForeignUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, Result(String, ForeignUnion) }), undefined)),
    };
    inline for (WrapperRefused) |T| try std.testing.expect(!isFiniteOwnedMove(T));

    // The same wrappers beside a union no release follows stay accepted, so the
    // refusal above is about the owned arm rather than about a union in a tuple.
    const WrapperAccepted = .{
        @TypeOf(@as(@Tuple(&.{ String, ScalarUnion }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, Result(String, ScalarUnion) }), undefined)),
        @TypeOf(@as(@Tuple(&.{ String, CowSlice(u32), ScalarUnion }), undefined)),
    };
    inline for (WrapperAccepted) |T| try std.testing.expect(isFiniteOwnedMove(T));

    // The public capability answers the same question from the same policy, and
    // it answers it while the branch is still a branch. The two loops above call
    // the private recursion as an ordinary function on purpose: a caller-side
    // `comptime` guard would hide a predicate that only works under one.
    inline for (Accepted) |T| try std.testing.expect(supportsOwnedMove(T));
    inline for (Refused) |T| try std.testing.expect(!supportsOwnedMove(T));

    // The same two tables answer the same way through the public gate, which is
    // the one a translated caller reads.
    inline for (WrapperAccepted) |T| try std.testing.expect(supportsOwnedMove(T));
    inline for (WrapperRefused) |T| try std.testing.expect(!supportsOwnedMove(T));
}

test "takeOwned empties a moved wrapper in place and the source then releases nothing" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const label: Borrow = "borrowed label";

    // A real pointee, so the wrapper's mutable slot names storage the transfer
    // must carry across and must never write through.
    var counter: u32 = 41;
    var source = try makeOwnerTestWrapper(OwnerMoveTestTuple, gpa, label, &counter);
    const source_addresses = ownerTestAddresses(source);
    try std.testing.expectEqual(@as(usize, 36), ownerTestTotal(source));

    var owner = takeOwned(OwnerMoveTestTuple, &source);

    // The wrapper kept its shape on both sides. Which arm was active is still
    // recorded, the borrow and the scalar are what they were, and the array
    // still has one present slot beside the one that was already empty.
    try std.testing.expectEqual(@as(u8, 7), source[5]);
    try std.testing.expectEqual(@intFromPtr(label.ptr), @intFromPtr(source[3].ptr));
    try std.testing.expectEqual(label.len, source[3].len);
    try std.testing.expectEqualStrings("borrowed label", source[3]);
    try std.testing.expectEqual(@intFromPtr(&counter), @intFromPtr(source[4]));
    try std.testing.expectEqual(@as(u32, 41), counter);
    try std.testing.expect(source[0][1] == null);
    try std.testing.expectEqual(@as(usize, 0), ownerTestTotal(source));

    // A release reaching the emptied source frees nothing at all, which is what
    // leaves the returned descriptor the single owner of the three allocations.
    const before_source_release = tracking.deallocations;
    dropTemporary(gpa, &source);
    try std.testing.expectEqual(before_source_release, tracking.deallocations);

    // The owner reads the bytes the source built at the addresses they already
    // had, so the transfer handed the descriptor over instead of copying a
    // payload into a second owner.
    try std.testing.expectEqual(source_addresses, ownerTestAddresses(owner));
    try std.testing.expectEqual(@intFromPtr(label.ptr), @intFromPtr(owner[3].ptr));
    try std.testing.expectEqual(label.len, owner[3].len);
    try std.testing.expectEqualStrings("borrowed label", owner[3]);
    try std.testing.expectEqual(@intFromPtr(&counter), @intFromPtr(owner[4]));
    try std.testing.expectEqual(@as(u32, 41), counter);
    try std.testing.expectEqual(@as(u8, 7), owner[5]);
    try std.testing.expectEqualStrings("array first", owner[0][0].?.as_str());
    try std.testing.expect(owner[0][1] == null);
    try std.testing.expectEqualStrings("result error", owner[1].Err.as_str());
    try std.testing.expectEqualStrings("union success", (owner[2] catch unreachable).as_str());
    owner[0][0].?.bytes.items[0] = 'A';
    try std.testing.expectEqualStrings("Array first", owner[0][0].?.as_str());

    const before_owner_release = tracking.deallocations;
    dropTemporary(gpa, &owner);
    try std.testing.expectEqual(before_owner_release + 3, tracking.deallocations);
}

test "takeOwned on a consuming branch frees nothing twice and the other branch keeps its owner" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const label: Borrow = "conditional label";

    for ([_]bool{ true, false }) |consume| {
        var counter: u32 = 7;
        var owner: ?OwnerMoveTestTuple = null;
        {
            var source = try makeOwnerTestWrapper(OwnerMoveTestTuple, gpa, label, &counter);
            // The two arms of a translated Rust move. The frame still releases
            // what it holds when the scope ends; on the consuming arm that is
            // the emptied wrapper, which frees nothing then.
            if (consume) owner = takeOwned(OwnerMoveTestTuple, &source);
            const before_release = tracking.deallocations;
            dropTemporary(gpa, &source);
            const expected_frees = if (consume) before_release else before_release + 3;
            try std.testing.expectEqual(expected_frees, tracking.deallocations);
        }

        if (owner) |*moved| {
            try std.testing.expect(consume);
            try std.testing.expectEqualStrings("array first", moved[0][0].?.as_str());
            try std.testing.expectEqualStrings("result error", moved[1].Err.as_str());
            const before_owner_release = tracking.deallocations;
            dropTemporary(gpa, moved);
            try std.testing.expectEqual(before_owner_release + 3, tracking.deallocations);
        } else {
            // The arm that did not consume still owned its payload, and the
            // release at the end of its scope was the only one that ran.
            try std.testing.expect(!consume);
        }
    }
}

test "vec_repeat_owned and vec_push_owned consume a moved wrapper and release it once" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const label: Borrow = "repeat label";

    // A repetition clones its template, so the wrapper it repeats is the one
    // whose pointer is a shared borrow. A mutable pointer is an exclusive
    // `&mut u32`, which Rust does not let `Clone` touch and which this runtime
    // refuses for the same reason; the move fixtures keep that pointer.
    var counter: u32 = 11;
    const cell: SharedPointer = &counter;

    // The template moves out of its own frame, so the emptied wrapper that frame
    // releases holds nothing while the clones stay independent owners.
    var template = try makeOwnerTestWrapper(OwnerCloneTestTuple, gpa, label, cell);
    const template_addresses = ownerTestAddresses(template);
    const template_item = takeOwned(OwnerCloneTestTuple, &template);
    var repeated = try vec_repeat_owned(OwnerCloneTestTuple, gpa, template_item, 3);
    const before_template_release = tracking.deallocations;
    dropTemporary(gpa, &template);
    try std.testing.expectEqual(before_template_release, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 3), repeated.items.len);

    // The original landed in the last element, so all three of its addresses are
    // the template's. Every cloned element shares none of them: each of the three
    // owners in each clone is an owner of its own.
    const last_addresses = ownerTestAddresses(repeated.items[2]);
    try std.testing.expect(std.meta.eql(template_addresses, last_addresses));
    for (repeated.items[0..2]) |element| {
        const cloned_addresses = ownerTestAddresses(element);
        for (template_addresses, 0..) |owned, index| {
            try std.testing.expect(cloned_addresses[index] != owned);
        }
    }

    // The borrow and the scalar are copied into every element, so all three name
    // one cell and carry the tag, and none of them writes through it.
    for (repeated.items) |element| {
        try std.testing.expectEqual(@intFromPtr(cell), @intFromPtr(element[4]));
        try std.testing.expectEqual(@intFromPtr(label.ptr), @intFromPtr(element[3].ptr));
        try std.testing.expectEqual(label.len, element[3].len);
        try std.testing.expectEqual(@as(u8, 7), element[5]);
    }
    try std.testing.expectEqual(@as(u32, 11), counter);

    repeated.items[2][0][0].?.bytes.items[0] = 'R';
    try std.testing.expectEqualStrings("Rrray first", repeated.items[2][0][0].?.as_str());
    try std.testing.expectEqualStrings("array first", repeated.items[0][0][0].?.as_str());
    try std.testing.expectEqualStrings("result error", repeated.items[1][1].Err.as_str());
    const first_union = repeated.items[0][2] catch unreachable;
    try std.testing.expectEqualStrings("union success", first_union.as_str());

    // Nine owners and the slab that holds them, released exactly once each.
    const before_repeat_release = tracking.deallocations;
    dropTemporary(gpa, &repeated);
    try std.testing.expectEqual(before_repeat_release + 10, tracking.deallocations);

    // A push the destination can hold keeps the transferred wrapper whole and
    // leaves the frame it came from nothing to release.
    var accepted: Vec(OwnerCloneTestTuple) = .empty;
    defer dropTemporary(gpa, &accepted);
    var item = try makeOwnerTestWrapper(OwnerCloneTestTuple, gpa, label, cell);
    const pushed_item = takeOwned(OwnerCloneTestTuple, &item);
    try vec_push_owned(OwnerCloneTestTuple, gpa, &accepted, pushed_item);
    try std.testing.expectEqual(@as(usize, 1), accepted.items.len);
    const before_item_release = tracking.deallocations;
    dropTemporary(gpa, &item);
    try std.testing.expectEqual(before_item_release, tracking.deallocations);
    try std.testing.expectEqualStrings("array first", accepted.items[0][0][0].?.as_str());
    try std.testing.expectEqualStrings("result error", accepted.items[0][1].Err.as_str());

    // A push the destination cannot hold releases the transferred wrapper once
    // and leaves the element the destination already held untouched. The room is
    // exactly one element and one element is held, so this push has to resize.
    // Spare capacity would let it succeed without asking the allocator for
    // anything, and a failing allocator that is never asked fails nothing; both
    // counters are armed, so the resize fails whether it allocates afresh or
    // grows the slab where it stands.
    var full = try Vec(OwnerCloneTestTuple).initCapacity(gpa, 1);
    defer dropTemporary(gpa, &full);
    const kept = try makeOwnerTestWrapper(OwnerCloneTestTuple, gpa, label, cell);
    full.appendAssumeCapacity(kept);
    try std.testing.expectEqual(@as(usize, 1), full.items.len);
    try std.testing.expectEqual(@as(usize, 1), full.capacity);
    const kept_addresses = ownerTestAddresses(kept);

    var rejected = try makeOwnerTestWrapper(OwnerCloneTestTuple, gpa, label, cell);
    const rejected_item = takeOwned(OwnerCloneTestTuple, &rejected);
    const before_failed_push = tracking.deallocations;
    tracking.fail_index = tracking.alloc_index;
    tracking.resize_fail_index = tracking.resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        vec_push_owned(OwnerCloneTestTuple, gpa, &full, rejected_item),
    );
    try std.testing.expectEqual(before_failed_push + 3, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 1), full.items.len);
    try std.testing.expectEqual(@as(usize, 1), full.capacity);
    const still_addresses = ownerTestAddresses(full.items[0]);
    try std.testing.expect(std.meta.eql(kept_addresses, still_addresses));
    try std.testing.expectEqualStrings("array first", full.items[0][0][0].?.as_str());
    try std.testing.expectEqualStrings("result error", full.items[0][1].Err.as_str());
    const before_rejected_release = tracking.deallocations;
    dropTemporary(gpa, &rejected);
    try std.testing.expectEqual(before_rejected_release, tracking.deallocations);
}

test "String takes valid UTF-8 byte ownership without copying" {
    const gpa = std.testing.allocator;
    var bytes = try vec_from_slice(u8, gpa, "h\xc3\xa9");
    const allocation_address = @intFromPtr(bytes.items.ptr);

    var conversion = String.from_utf8(&bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bytes.capacity);

    switch (conversion) {
        .Ok => |*string| {
            try std.testing.expectEqualStrings("h\xc3\xa9", string.as_str());
            try std.testing.expectEqual(allocation_address, @intFromPtr(string.as_bytes().ptr));

            var round_trip = string.into_bytes();
            defer round_trip.deinit(gpa);
            try std.testing.expectEqual(allocation_address, @intFromPtr(round_trip.items.ptr));
            try std.testing.expectEqual(@as(usize, 0), string.as_bytes().len);
            string.deinit(gpa);
        },
        .Err => |*invalid| {
            invalid.deinit(gpa);
            return error.ExpectedValidUtf8;
        },
    }
}

test "String UTF-8 failure retains byte ownership and error detail" {
    const gpa = std.testing.allocator;
    var bytes = try vec_from_slice(u8, gpa, "ok\xf0\x90");
    const allocation_address = @intFromPtr(bytes.items.ptr);

    var conversion = String.from_utf8(&bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), bytes.capacity);

    switch (conversion) {
        .Ok => |*string| {
            string.deinit(gpa);
            return error.ExpectedInvalidUtf8;
        },
        .Err => |*invalid| {
            try std.testing.expectEqual(allocation_address, @intFromPtr(invalid.bytes.items.ptr));
            try std.testing.expectEqual(
                character.Utf8Error{ .valid_up_to = 2, .error_len = null },
                invalid.utf8_error(),
            );
            invalid.deinit(gpa);
        },
    }
}

test "Cow leaves borrowed storage alone and transfers owned storage once" {
    const gpa = std.testing.allocator;
    const literal = "borrowed";
    var borrowed = CowStr.from_borrowed(literal);
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(borrowed.as_ref().ptr));
    borrowed.deinit(gpa);

    var string = try String.from_str(gpa, "owned");
    const allocation_address = @intFromPtr(string.as_bytes().ptr);
    var owned = CowStr.from_owned(&string);
    defer owned.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), string.as_bytes().len);

    var moved = try owned.into_owned(gpa);
    defer moved.deinit(gpa);
    try std.testing.expectEqual(allocation_address, @intFromPtr(moved.as_bytes().ptr));
    try std.testing.expectEqual(@as(usize, 0), owned.as_ref().len);
}

test "Cow borrowed conversion keeps ownership when allocation fails" {
    const gpa = std.testing.allocator;
    const literal = "copy me";
    var cow = CowStr.from_borrowed(literal);
    defer cow.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, cow.into_owned(failing.allocator()));
    try std.testing.expectEqual(@intFromPtr(literal.ptr), @intFromPtr(cow.as_ref().ptr));
}

test "Cow clone borrows its input and copies owned storage independently" {
    const gpa = std.testing.allocator;

    const literal = "borrowed";
    var borrowed = CowStr.from_borrowed(literal);
    defer borrowed.deinit(gpa);
    var borrowed_copy = try borrowed.clone(gpa);
    defer borrowed_copy.deinit(gpa);
    try std.testing.expectEqual(
        @intFromPtr(literal.ptr),
        @intFromPtr(borrowed_copy.as_ref().ptr),
    );

    var string = try String.from_str(gpa, "owned");
    var owned = CowStr.from_owned(&string);
    defer owned.deinit(gpa);
    var owned_copy = try owned.clone(gpa);
    defer owned_copy.deinit(gpa);
    try std.testing.expectEqualStrings("owned", owned_copy.as_ref());

    // Writing through the copy leaves the original bytes alone, so the two are
    // independent storage and either is released on its own.
    switch (owned_copy) {
        .Borrowed => return error.ExpectedOwnedCopy,
        .Owned => |*copy| copy.as_mut_str()[0] = 'O',
    }
    try std.testing.expectEqualStrings("Owned", owned_copy.as_ref());
    try std.testing.expectEqualStrings("owned", owned.as_ref());

    // A refused copy leaves the source holding exactly what it always held.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owned.clone(failing.allocator()));
    try std.testing.expectEqualStrings("owned", owned.as_ref());
}

test "byte Cow clone copies owned elements and keeps a borrow borrowed" {
    const gpa = std.testing.allocator;

    var numbers = try vec_from_slice(u32, gpa, &.{ 1, 2, 3 });
    var owned = CowSlice(u32).from_owned(&numbers);
    defer owned.deinit(gpa);
    var owned_copy = try owned.clone(gpa);
    defer owned_copy.deinit(gpa);

    switch (owned_copy) {
        .Borrowed => return error.ExpectedOwnedCopy,
        .Owned => |*bytes| bytes.items[0] = 9,
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, owned.as_ref());

    const literal = "borrowed";
    var borrowed = CowSlice(u8).from_borrowed(literal);
    defer borrowed.deinit(gpa);
    var borrowed_copy = try borrowed.clone(gpa);
    defer borrowed_copy.deinit(gpa);
    try std.testing.expectEqual(
        @intFromPtr(literal.ptr),
        @intFromPtr(borrowed_copy.as_ref().ptr),
    );
}

/// `Cow<[T]>` owns its `T` elements, and Rust's `Clone` for it is
/// `<[T] as ToOwned>::to_owned`, which is `to_vec`: every element is cloned, so
/// an owning element is copied into fresh bytes. This fixture owns its
/// elements, so a clone that copied only their descriptors would hand one
/// allocation two owners, and the two would release the same bytes.
const OwningCowSlice = CowSlice(String);

fn makeOwningCowSlice(gpa: std.mem.Allocator) !OwningCowSlice {
    var owned: Vec(String) = .empty;
    errdefer dropTemporary(gpa, &owned);
    try owned.append(gpa, try String.from_str(gpa, "first element"));
    try owned.append(gpa, try String.from_str(gpa, "second element"));
    return OwningCowSlice.from_owned(&owned);
}

fn checkOwningCowSliceCloneAllocationFailures(
    gpa: std.mem.Allocator,
    fixture: *const OwningCowSlice,
) anyerror!void {
    // The return type is declared rather than inferred: the sweep's generated
    // switch names `error.OutOfMemory`, so the helper's set has to carry it
    // whatever the body decides to do with it.
    // The fixture was built with the backend allocator and is released outside
    // the sweep, so only the clone runs under the failing one and each run's own
    // allocation and release counts describe the clone alone.
    var copy = try fixture.clone(gpa);
    // Released on every exit path, including a failed assertion, so each run of
    // this closure frees exactly what it allocated and its byte counters balance.
    defer copy.deinit(gpa);

    // A clone that runs out of room part way releases what it had already
    // copied, and the original keeps its own bytes on every outcome. The
    // independence check comes first so that a clone sharing the descriptors
    // fails on it rather than freeing the same bytes a second time below.
    try std.testing.expect(copy.as_ref()[0].as_bytes().ptr != fixture.as_ref()[0].as_bytes().ptr);
    try std.testing.expectEqualStrings("first element", copy.as_ref()[0].as_str());
    try std.testing.expectEqualStrings("second element", copy.as_ref()[1].as_str());
    try std.testing.expectEqualStrings("first element", fixture.as_ref()[0].as_str());
    try std.testing.expectEqualStrings("second element", fixture.as_ref()[1].as_str());
}

test "CowSlice clone of an owning element is an independent owner, not a second descriptor" {
    const gpa = std.testing.allocator;
    // Both owners are released on every exit path, including a failed
    // assertion, so the suite's leak-checking allocator finds nothing left
    // behind. `deinit` leaves an empty `Cow`, so the release below leaves the
    // clone's `defer` a no-op.
    var cow = try makeOwningCowSlice(gpa);
    defer cow.deinit(gpa);
    const original_address = @intFromPtr(cow.as_ref()[0].as_bytes().ptr);
    var copy = try cow.clone(gpa);
    defer copy.deinit(gpa);

    // The clone owns its bytes instead of naming the original's, which is what
    // `clone` documents when it says the owned arm is copied element for element
    // into fresh storage.
    try std.testing.expect(copy.as_ref()[0].as_bytes().ptr != cow.as_ref()[0].as_bytes().ptr);
    try std.testing.expect(copy.as_ref()[1].as_bytes().ptr != cow.as_ref()[1].as_bytes().ptr);
    try std.testing.expectEqualStrings("first element", copy.as_ref()[0].as_str());
    try std.testing.expectEqualStrings("second element", copy.as_ref()[1].as_str());
    try std.testing.expectEqual(original_address, @intFromPtr(cow.as_ref()[0].as_bytes().ptr));

    // Writing through the clone reaches the clone's bytes and no others.
    switch (copy) {
        .Borrowed => return error.ExpectedOwnedCopy,
        .Owned => |*elements| elements.items[0].bytes.items[0] = 'F',
    }
    try std.testing.expectEqualStrings("First element", copy.as_ref()[0].as_str());
    try std.testing.expectEqualStrings("first element", cow.as_ref()[0].as_str());

    // Releasing the clone first is what the read below needs: an independent
    // copy means the original still reads its own bytes once the clone is gone.
    copy.deinit(gpa);
    try std.testing.expectEqualStrings("first element", cow.as_ref()[0].as_str());
}

test "CowSlice clone of owning elements releases its partial copy at every allocation failure" {
    // The fixture is built and released with the backend allocator, outside the
    // sweep, so a failing allocation has to land in the clone rather than in the
    // fixture that is supposed to stay intact.
    const gpa = std.testing.allocator;
    var cow = try makeOwningCowSlice(gpa);
    defer cow.deinit(gpa);
    try std.testing.checkAllAllocationFailures(
        gpa,
        checkOwningCowSliceCloneAllocationFailures,
        .{&cow},
    );
}

/// The caller of `CowSlice(String).from_borrowed` still owns its strings: it
/// built them, it reads them, and it releases them. A borrowed `Cow<[String]>`
/// converted with `into_owned` has to copy those elements into storage of its
/// own, because the converted value's release must not free the caller's bytes.
fn appendCallerStrings(gpa: std.mem.Allocator, caller: *Vec(String)) !void {
    errdefer dropTemporary(gpa, caller);
    try caller.append(gpa, try String.from_str(gpa, "first element"));
    try caller.append(gpa, try String.from_str(gpa, "second element"));
}

fn callerStringAddresses(caller: *const Vec(String)) [2]usize {
    return .{
        @intFromPtr(caller.items[0].as_bytes().ptr),
        @intFromPtr(caller.items[1].as_bytes().ptr),
    };
}

fn checkBorrowedOwningCowSliceIntoOwnedFailures(
    gpa: std.mem.Allocator,
    caller: *const Vec(String),
) anyerror!void {
    // The return type is declared rather than inferred: the closure hands the
    // induced failure back to the sweep at the end, and the sweep's generated
    // switch names `error.OutOfMemory`, so the set has to carry it whatever the
    // body decides to do with it.
    // The caller built these strings with the backend allocator and releases
    // them outside the sweep, so only the conversion runs under the failing one
    // and each run's own allocation and release counts describe it alone.
    var borrowed = OwningCowSlice.from_borrowed(caller.items);
    defer borrowed.deinit(gpa);

    if (borrowed.into_owned(gpa)) |value| {
        // A conversion that did run copies rather than claims, and the caller's
        // strings are untouched by it. The release is a `defer` so that a failed
        // assertion still frees the conversion.
        var owned = value;
        defer dropTemporary(gpa, &owned);
        try std.testing.expect(owned.items[0].as_bytes().ptr != caller.items[0].as_bytes().ptr);
        try std.testing.expectEqualStrings("first element", owned.items[0].as_str());
        try std.testing.expectEqualStrings("second element", owned.items[1].as_str());
        try std.testing.expectEqualStrings("first element", caller.items[0].as_str());
    } else |err| {
        // A conversion that ran out of room claims nothing: the caller's strings
        // still read, and the borrowed Cow still borrows all of them. The induced
        // failure is handed back afterwards, because the sweep reports a run that
        // succeeds after an induced failure as a swallowed OutOfMemory rather
        // than as a clean failure.
        try std.testing.expectEqualStrings("first element", caller.items[0].as_str());
        try std.testing.expectEqualStrings("second element", caller.items[1].as_str());
        try std.testing.expectEqual(@as(usize, 2), borrowed.as_ref().len);
        return err;
    }
}

test "CowSlice into_owned of a borrowed owning slice copies the caller's elements" {
    const gpa = std.testing.allocator;

    // These strings belong to the caller, which still reads them and still
    // releases them. The borrowed Cow names them and owns none of them.
    var caller: Vec(String) = .empty;
    defer dropTemporary(gpa, &caller);
    try appendCallerStrings(gpa, &caller);
    const caller_addresses = callerStringAddresses(&caller);
    var borrowed = OwningCowSlice.from_borrowed(caller.items);

    // The converted vector is released exactly once, at the bottom of this
    // test, because that is where the caller's strings can still be read
    // afterwards. It could equally sit in a `defer`: `dropTemporary` leaves a
    // released `Vec(T)` at its own `empty`, so a second release of the same
    // block frees nothing. The ordering below is about what the test wants to
    // read, not about how many releases the vector survives.
    var owned = try borrowed.into_owned(gpa);

    // The converted vector owns bytes of its own instead of claiming the
    // caller's, and the Cow owns nothing once it has handed its borrow over.
    try std.testing.expect(owned.items[0].as_bytes().ptr != caller.items[0].as_bytes().ptr);
    try std.testing.expect(owned.items[1].as_bytes().ptr != caller.items[1].as_bytes().ptr);
    try std.testing.expectEqual(@as(usize, 0), borrowed.as_ref().len);

    // Writing through the converted vector leaves the caller's bytes alone.
    owned.items[0].bytes.items[0] = 'F';
    try std.testing.expectEqualStrings("First element", owned.items[0].as_str());
    try std.testing.expectEqualStrings("first element", caller.items[0].as_str());
    try std.testing.expectEqualStrings("second element", caller.items[1].as_str());

    // Releasing the converted vector frees its own copies only: the caller's
    // strings still read and still carry the addresses they had, and the
    // caller's own release frees them exactly once. The assertions below are why
    // this release is the last thing the test does rather than a `defer`.
    dropTemporary(gpa, &owned);
    try std.testing.expectEqualStrings("first element", caller.items[0].as_str());
    try std.testing.expectEqualStrings("second element", caller.items[1].as_str());
    try std.testing.expectEqual(caller_addresses[0], @intFromPtr(caller.items[0].as_bytes().ptr));
    try std.testing.expectEqual(caller_addresses[1], @intFromPtr(caller.items[1].as_bytes().ptr));
}

test "CowSlice into_owned of a borrowed owning slice claims nothing at any allocation failure" {
    // The caller's strings are built and released with the backend allocator,
    // outside the sweep, so a failing allocation has to land in the conversion
    // rather than in the storage that has to survive it.
    const gpa = std.testing.allocator;
    var caller: Vec(String) = .empty;
    defer dropTemporary(gpa, &caller);
    try appendCallerStrings(gpa, &caller);
    try std.testing.checkAllAllocationFailures(
        gpa,
        checkBorrowedOwningCowSliceIntoOwnedFailures,
        .{&caller},
    );
}

test "lossy UTF-8 borrows valid input and owns standard replacement output" {
    const gpa = std.testing.allocator;
    const valid_input = "valid \xe2\x98\x83";
    var valid = try String.from_utf8_lossy(gpa, valid_input);
    defer valid.deinit(gpa);
    switch (valid) {
        .Borrowed => |utf8| {
            try std.testing.expectEqual(@intFromPtr(valid_input.ptr), @intFromPtr(utf8.ptr));
        },
        .Owned => return error.ExpectedBorrowedUtf8,
    }

    var lossy = try String.from_utf8_lossy(gpa, "a\xf0\x90b");
    defer lossy.deinit(gpa);
    switch (lossy) {
        .Borrowed => return error.ExpectedOwnedUtf8,
        .Owned => |*utf8| try std.testing.expectEqualStrings("a\xef\xbf\xbdb", utf8.as_str()),
    }
}

test "lossy UTF-8 follows Rust maximal-subpart grouping" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "x\xc2", .expected = "x\xef\xbf\xbd" },
        .{ .input = "x\xe1\x80A", .expected = "x\xef\xbf\xbdA" },
        .{ .input = "x\xf0\x90", .expected = "x\xef\xbf\xbd" },
        .{ .input = "x\xe1\x80\xff", .expected = "x\xef\xbf\xbd\xef\xbf\xbd" },
        .{ .input = "x\xe0\x80A", .expected = "x\xef\xbf\xbd\xef\xbf\xbdA" },
    };

    for (cases) |case| {
        var lossy = try String.from_utf8_lossy(gpa, case.input);
        defer lossy.deinit(gpa);
        switch (lossy) {
            .Borrowed => return error.ExpectedOwnedUtf8,
            .Owned => |*utf8| try std.testing.expectEqualStrings(case.expected, utf8.as_str()),
        }
    }
}

test "owned byte Cow strict conversion reuses storage and lossy OOM preserves it" {
    const gpa = std.testing.allocator;

    var valid_bytes = try vec_from_slice(u8, gpa, "owned \xe2\x98\x83");
    const valid_address = @intFromPtr(valid_bytes.items.ptr);
    var valid_cow = CowSlice(u8).from_owned(&valid_bytes);
    var strict = cow_bytes_to_utf8(&valid_cow);
    switch (strict) {
        .Err => return error.ExpectedValidUtf8,
        .Ok => |*utf8| {
            switch (utf8.*) {
                .Borrowed => return error.ExpectedOwnedUtf8,
                .Owned => |*string| {
                    try std.testing.expectEqual(valid_address, @intFromPtr(string.as_bytes().ptr));
                    string.deinit(gpa);
                },
            }
        },
    }

    var invalid_bytes = try vec_from_slice(u8, gpa, "bad\xf0\x90");
    const invalid_address = @intFromPtr(invalid_bytes.items.ptr);
    var invalid_cow = CowSlice(u8).from_owned(&invalid_bytes);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        cow_bytes_to_utf8_lossy(failing.allocator(), &invalid_cow),
    );
    switch (invalid_cow) {
        .Borrowed => return error.ExpectedOwnedUtf8,
        .Owned => |bytes| try std.testing.expectEqual(invalid_address, @intFromPtr(bytes.items.ptr)),
    }
    invalid_cow.deinit(gpa);
}

test "result collection releases partial Vec on item error" {
    const gpa = std.testing.allocator;
    const iterator: ResultByteIterator = .{};
    var collected = try collect_result(u8, CollectError, gpa, iterator);

    switch (collected) {
        .Ok => |*bytes| {
            bytes.deinit(gpa);
            return error.ExpectedCollectionError;
        },
        .Err => |collection_error| {
            try std.testing.expectEqual(CollectError.invalid, collection_error);
        },
    }
}

test "vector extension appends an iterator and a slice after the elements held" {
    const gpa = std.testing.allocator;
    var destination: Vec(u8) = .empty;
    defer destination.deinit(gpa);
    try destination.appendSlice(gpa, "ab");

    try vec_extend(u8, gpa, &destination, ByteIterator{ .items = "cde" });
    try vec_extend(u8, gpa, &destination, "fg");
    try vec_extend(u8, gpa, &destination, [_]u8{'h'});

    try std.testing.expectEqualStrings("abcdefgh", destination.items);

    var collected = try vec_collect(u8, gpa, ByteIterator{ .items = "ijk" });
    defer collected.deinit(gpa);
    try std.testing.expectEqualStrings("ijk", collected.items);
}

test "vector extension allocation failure leaves the prefix in the destination" {
    const gpa = std.testing.allocator;
    // The capacity is exactly the prefix length, so the first appended item has
    // to grow the slab and the failing allocator refuses that growth.
    var destination = try Vec(u8).initCapacity(gpa, 3);
    defer destination.deinit(gpa);
    destination.appendSliceAssumeCapacity("pre");

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        vec_extend(u8, failing.allocator(), &destination, ByteIterator{ .items = "fix" }),
    );
    try std.testing.expectEqualStrings("pre", destination.items);

    // The vector that failed is still the caller's to use and to release.
    try destination.appendSlice(gpa, "fix");
    try std.testing.expectEqualStrings("prefix", destination.items);
}

test "String and CowStr render through Zig's own {f} specifier" {
    const gpa = std.testing.allocator;
    var owned = try String.from_str(gpa, "owned bytes");
    defer owned.deinit(gpa);
    var cow = CowStr.from_owned(&owned);
    defer cow.deinit(gpa);

    var third = try String.from_str(gpa, "third value");
    defer third.deinit(gpa);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}|{f}|{f}", .{ third, cow, CowStr.from_borrowed("borrowed bytes") });
    try std.testing.expectEqualStrings(
        "third value|owned bytes|borrowed bytes",
        writer.buffered(),
    );
}

test "a short buffer fails through the String and CowStr hooks" {
    const gpa = std.testing.allocator;
    var owned = try String.from_str(gpa, "0123456789");
    defer owned.deinit(gpa);
    var cow = CowStr.from_owned(&owned);
    defer cow.deinit(gpa);

    var buffer: [4]u8 = undefined;
    var string_writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, string_writer.print("{f}", .{cow}));
    try std.testing.expectEqualStrings("0123", string_writer.buffered());

    var cow_buffer: [4]u8 = undefined;
    var cow_writer: std.Io.Writer = .fixed(&cow_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        cow_writer.print("{f}", .{CowStr.from_borrowed("borrow")}),
    );
    try std.testing.expectEqualStrings("borr", cow_writer.buffered());
}

test "vec_push_owned transfers a string without changing its storage" {
    const gpa = std.testing.allocator;
    var destination: Vec(String) = .empty;
    defer dropTemporary(gpa, &destination);
    var item = try String.from_str(gpa, "transferred");
    defer item.deinit(gpa);
    const address = @intFromPtr(item.as_bytes().ptr);
    try vec_push_owned(String, gpa, &destination, takeOwned(String, &item));
    try std.testing.expectEqual(@as(usize, 0), item.len());
    try std.testing.expectEqual(@as(usize, 1), destination.items.len);
    try std.testing.expectEqualStrings("transferred", destination.items[0].as_str());
    try std.testing.expectEqual(address, @intFromPtr(destination.items[0].as_bytes().ptr));
}

test "vec_push_owned OOM consumes its item and preserves the existing destination" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    var destination = try Vec(String).initCapacity(gpa, 1);
    defer dropTemporary(gpa, &destination);
    destination.appendAssumeCapacity(try String.from_str(gpa, "kept"));
    var item = try String.from_str(gpa, "released");
    const kept_address = @intFromPtr(destination.items[0].as_bytes().ptr);
    const frees = tracking.deallocations;
    tracking.fail_index = tracking.alloc_index;
    tracking.resize_fail_index = tracking.resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        vec_push_owned(String, gpa, &destination, takeOwned(String, &item)),
    );
    try std.testing.expectEqual(@as(usize, 0), item.len());
    try std.testing.expectEqual(frees + 1, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 1), destination.items.len);
    try std.testing.expectEqualStrings("kept", destination.items[0].as_str());
    try std.testing.expectEqual(kept_address, @intFromPtr(destination.items[0].as_bytes().ptr));
}

test "vec_repeat_owned zero releases once without allocation and one moves the original" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    var zero_item = try String.from_str(gpa, "zero");
    const allocations = tracking.allocations;
    const frees = tracking.deallocations;
    var zero = try vec_repeat_owned(String, gpa, takeOwned(String, &zero_item), 0);
    defer dropTemporary(gpa, &zero);
    try std.testing.expectEqual(@as(usize, 0), zero.items.len);
    try std.testing.expectEqual(allocations, tracking.allocations);
    try std.testing.expectEqual(frees + 1, tracking.deallocations);

    var one_item = try String.from_str(gpa, "one");
    const address = @intFromPtr(one_item.as_bytes().ptr);
    const before_one = tracking.allocations;
    var one = try vec_repeat_owned(String, gpa, takeOwned(String, &one_item), 1);
    defer dropTemporary(gpa, &one);
    try std.testing.expectEqual(before_one + 1, tracking.allocations);
    try std.testing.expectEqual(address, @intFromPtr(one.items[0].as_bytes().ptr));
    try std.testing.expectEqualStrings("one", one.items[0].as_str());
}

test "vec_repeat_owned independently clones and moves the original last" {
    const gpa = std.testing.allocator;
    var item = try String.from_str(gpa, "original");
    const address = @intFromPtr(item.as_bytes().ptr);
    var repeated = try vec_repeat_owned(String, gpa, takeOwned(String, &item), 3);
    defer dropTemporary(gpa, &repeated);
    try std.testing.expectEqual(address, @intFromPtr(repeated.items[2].as_bytes().ptr));
    try std.testing.expect(@intFromPtr(repeated.items[0].as_bytes().ptr) != address);
    try std.testing.expect(@intFromPtr(repeated.items[1].as_bytes().ptr) != address);
    repeated.items[0].bytes.items[0] = 'X';
    try std.testing.expectEqualStrings("Xriginal", repeated.items[0].as_str());
    try std.testing.expectEqualStrings("original", repeated.items[1].as_str());
    try std.testing.expectEqualStrings("original", repeated.items[2].as_str());
}

test "vec_repeat_owned caller stages template and evaluates count exactly once" {
    const Evaluation = struct {
        template_calls: usize = 0,
        count_calls: usize = 0,

        fn template(self: *@This(), gpa: std.mem.Allocator) !String {
            self.template_calls += 1;
            return String.from_str(gpa, "evaluated");
        }

        fn count(self: *@This()) usize {
            self.count_calls += 1;
            return 3;
        }
    };
    const gpa = std.testing.allocator;
    var evaluation: Evaluation = .{};
    var item = try evaluation.template(gpa);
    defer item.deinit(gpa);
    const count = evaluation.count();
    var repeated = try vec_repeat_owned(String, gpa, takeOwned(String, &item), count);
    defer dropTemporary(gpa, &repeated);
    try std.testing.expectEqual(@as(usize, 1), evaluation.template_calls);
    try std.testing.expectEqual(@as(usize, 1), evaluation.count_calls);
    try std.testing.expectEqual(count, repeated.items.len);
}

fn makeOwnedVecTestNested(gpa: std.mem.Allocator) !Vec(CowSlice(?String)) {
    var outer = try Vec(CowSlice(?String)).initCapacity(gpa, 2);
    errdefer dropTemporary(gpa, &outer);
    var inner = try Vec(?String).initCapacity(gpa, 3);
    errdefer dropTemporary(gpa, &inner);
    inner.appendAssumeCapacity(try String.from_str(gpa, "first"));
    inner.appendAssumeCapacity(null);
    inner.appendAssumeCapacity(try String.from_str(gpa, "second"));
    outer.appendAssumeCapacity(CowSlice(?String).from_owned(&inner));
    outer.appendAssumeCapacity(CowSlice(?String).from_borrowed(&.{null}));
    return outer;
}

test "vec_repeat_owned recursively clones nested Vec Cow and Option strings" {
    const gpa = std.testing.allocator;
    var item = try makeOwnedVecTestNested(gpa);
    const address = @intFromPtr(item.items.ptr);
    var repeated = try vec_repeat_owned(Vec(CowSlice(?String)), gpa, takeOwned(Vec(CowSlice(?String)), &item), 3);
    defer dropTemporary(gpa, &repeated);
    try std.testing.expectEqual(address, @intFromPtr(repeated.items[2].items.ptr));
    repeated.items[0].items[0].Owned.items[0].?.bytes.items[0] = 'X';
    try std.testing.expectEqualStrings("Xirst", repeated.items[0].items[0].Owned.items[0].?.as_str());
    try std.testing.expectEqualStrings("first", repeated.items[1].items[0].Owned.items[0].?.as_str());
    try std.testing.expectEqualStrings("first", repeated.items[2].items[0].Owned.items[0].?.as_str());
    try std.testing.expect(repeated.items[0].items[0].Owned.items[1] == null);
    try std.testing.expectEqual(
        @intFromPtr(repeated.items[2].items[1].Borrowed.ptr),
        @intFromPtr(repeated.items[0].items[1].Borrowed.ptr),
    );
}

test "vec_repeat_owned preserves borrowed Cow and retained UTF8 error detail" {
    const gpa = std.testing.allocator;
    var borrowed = try vec_repeat_owned(CowStr, gpa, CowStr.from_borrowed("borrowed"), 3);
    defer dropTemporary(gpa, &borrowed);
    for (borrowed.items) |cow| {
        try std.testing.expectEqualStrings("borrowed", cow.Borrowed);
        try std.testing.expectEqual(@intFromPtr(borrowed.items[0].Borrowed.ptr), @intFromPtr(cow.Borrowed.ptr));
    }
    var invalid = try vec_from_slice(u8, gpa, "a\xff");
    var item = String.from_utf8(&invalid).Err;
    const address = @intFromPtr(item.bytes.items.ptr);
    var errors = try vec_repeat_owned(FromUtf8Error, gpa, takeOwned(FromUtf8Error, &item), 3);
    defer dropTemporary(gpa, &errors);
    try std.testing.expectEqual(address, @intFromPtr(errors.items[2].bytes.items.ptr));
    errors.items[0].bytes.items[0] = 'b';
    try std.testing.expectEqualSlices(u8, "a\xff", errors.items[1].bytes.items);
    for (errors.items) |failure| {
        try std.testing.expectEqual(@as(usize, 1), failure.detail.valid_up_to);
        try std.testing.expectEqual(@as(?u8, 1), failure.detail.error_len);
    }
}

fn checkOwnedVecPushAllocationFailures(gpa: std.mem.Allocator) !void {
    var destination = try Vec(Vec(CowSlice(?String))).initCapacity(gpa, 1);
    defer dropTemporary(gpa, &destination);
    destination.appendAssumeCapacity(try makeOwnedVecTestNested(gpa));
    var item = try makeOwnedVecTestNested(gpa);
    const old_address = @intFromPtr(destination.items[0].items.ptr);
    vec_push_owned(Vec(CowSlice(?String)), gpa, &destination, takeOwned(Vec(CowSlice(?String)), &item)) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), destination.items.len);
        try std.testing.expectEqual(old_address, @intFromPtr(destination.items[0].items.ptr));
        try std.testing.expectEqualStrings("first", destination.items[0].items[0].Owned.items[0].?.as_str());
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), destination.items.len);
}

fn checkOwnedVecRepeatAllocationFailures(gpa: std.mem.Allocator) !void {
    var item = try makeOwnedVecTestNested(gpa);
    var repeated = try vec_repeat_owned(Vec(CowSlice(?String)), gpa, takeOwned(Vec(CowSlice(?String)), &item), 4);
    defer dropTemporary(gpa, &repeated);
    try std.testing.expectEqual(@as(usize, 4), repeated.items.len);
    for (repeated.items) |nested| {
        try std.testing.expectEqualStrings("first", nested.items[0].Owned.items[0].?.as_str());
        try std.testing.expectEqualStrings("second", nested.items[0].Owned.items[2].?.as_str());
    }
}

test "vec_push_owned releases nested transferred items at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOwnedVecPushAllocationFailures, .{});
}

test "vec_repeat_owned releases original initialized clone prefix and slabs at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOwnedVecRepeatAllocationFailures, .{});
}

test "vec_repeat_owned deep clones owned CowStr and builtin Copy vectors" {
    const gpa = std.testing.allocator;
    var text = try String.from_str(gpa, "owned cow");
    var cow = CowStr.from_owned(&text);
    var cows = try vec_repeat_owned(CowStr, gpa, takeOwned(CowStr, &cow), 3);
    defer dropTemporary(gpa, &cows);
    cows.items[0].Owned.bytes.items[0] = 'X';
    try std.testing.expectEqualStrings("owned cow", cows.items[1].as_ref());
    try std.testing.expectEqualStrings("owned cow", cows.items[2].as_ref());

    var bytes = try vec_from_slice(u8, gpa, "bytes");
    var vectors = try vec_repeat_owned(Vec(u8), gpa, takeOwned(Vec(u8), &bytes), 3);
    defer dropTemporary(gpa, &vectors);
    vectors.items[0].items[0] = 'X';
    try std.testing.expectEqualStrings("bytes", vectors.items[1].items);
    try std.testing.expectEqualStrings("bytes", vectors.items[2].items);
}

const OwnedVecTestTuple = @Tuple(&.{ [2]?String, Result(String, String), error{Rejected}!String });

fn makeOwnedVecTestTuple(gpa: std.mem.Allocator) !OwnedVecTestTuple {
    var array: [2]?String = .{ null, null };
    errdefer dropTemporary(gpa, &array);
    array[0] = try String.from_str(gpa, "array first");
    array[1] = try String.from_str(gpa, "array second");
    var result: Result(String, String) = .{ .Err = try String.from_str(gpa, "result error") };
    errdefer dropTemporary(gpa, &result);
    const success: error{Rejected}!String = try String.from_str(gpa, "error union success");
    return .{ array, result, success };
}

fn checkOwnedVecTupleRepeatAllocationFailures(gpa: std.mem.Allocator) !void {
    const item = try makeOwnedVecTestTuple(gpa);
    var repeated = try vec_repeat_owned(OwnedVecTestTuple, gpa, item, 3);
    defer dropTemporary(gpa, &repeated);
    repeated.items[0][0][0].?.bytes.items[0] = 'X';
    repeated.items[0][1].Err.bytes.items[0] = 'X';
    const first_success = try repeated.items[0][2];
    first_success.bytes.items[0] = 'X';
    try std.testing.expectEqualStrings("array first", repeated.items[1][0][0].?.as_str());
    try std.testing.expectEqualStrings("array first", repeated.items[2][0][0].?.as_str());
    try std.testing.expectEqualStrings("result error", repeated.items[1][1].Err.as_str());
    try std.testing.expectEqualStrings("result error", repeated.items[2][1].Err.as_str());
    const second_success = try repeated.items[1][2];
    try std.testing.expectEqualStrings("error union success", second_success.as_str());
    const last_success = try repeated.items[2][2];
    try std.testing.expectEqualStrings("error union success", last_success.as_str());
}

test "vec_repeat_owned rolls back partial array and tuple clones at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOwnedVecTupleRepeatAllocationFailures, .{});
}

test "vec_repeat_owned keeps inactive runtime Result and error union payloads inactive" {
    const gpa = std.testing.allocator;
    var successes = try vec_repeat_owned(Result(?String, String), gpa, .{ .Ok = null }, 3);
    defer dropTemporary(gpa, &successes);
    for (successes.items) |success| try std.testing.expect(success.Ok == null);

    var failures = try vec_repeat_owned(error{Rejected}!String, gpa, @as(error{Rejected}!String, error.Rejected), 3);
    defer dropTemporary(gpa, &failures);
    for (failures.items) |failure| try std.testing.expectError(error.Rejected, failure);
}

test "vec_push_owned cleans transferred tuple owners when destination allocation fails" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const item = try makeOwnedVecTestTuple(gpa);
    var destination: Vec(OwnedVecTestTuple) = .empty;
    defer dropTemporary(gpa, &destination);
    const frees = tracking.deallocations;
    tracking.fail_index = tracking.alloc_index;
    try std.testing.expectError(error.OutOfMemory, vec_push_owned(OwnedVecTestTuple, gpa, &destination, item));
    try std.testing.expectEqual(frees + 4, tracking.deallocations);
    try std.testing.expectEqual(@as(usize, 0), destination.items.len);
}

test "dropTemporary releases tuple wrapper owners without following foreign structs or borrows" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const Foreign = struct {
        text: String,
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            @panic("foreign destructor must not run");
        }
    };
    var kept = try String.from_str(gpa, "caller owned");
    defer kept.deinit(gpa);
    const Tuple = @Tuple(&.{ Foreign, *String, []const u8, ?OwnedVecTestTuple, CowSlice(OwnedVecTestTuple) });
    var owned = try Vec(OwnedVecTestTuple).initCapacity(gpa, 1);
    owned.appendAssumeCapacity(try makeOwnedVecTestTuple(gpa));
    var value: Tuple = .{
        .{ .text = kept },
        &kept,
        kept.as_str(),
        try makeOwnedVecTestTuple(gpa),
        .{ .Owned = owned },
    };
    const frees = tracking.deallocations;
    dropTemporary(gpa, &value);
    try std.testing.expectEqual(frees + 9, tracking.deallocations);
    try std.testing.expectEqualStrings("caller owned", kept.as_str());
    try std.testing.expectEqualStrings("caller owned", value[0].text.as_str());
    try std.testing.expectEqualStrings("caller owned", value[1].as_str());
    try std.testing.expectEqualStrings("caller owned", value[2]);
    try std.testing.expect(value[4] == .Borrowed);
}

/// A wrapper over three owners the runtime reaches in one pass: an owned
/// string, an owned vector, and an owned `Cow`. Releasing it frees three
/// blocks; releasing it again must free none of them.
const ReleaseShapeWrapper = @Tuple(&.{ String, Vec(u8), CowStr });

/// How many blocks one release of `value` freed.
///
/// Counting the frees is what turns a leak and a double free into named
/// failures. The counters come from a `FailingAllocator` wrapping the suite's
/// leak-checking `std.testing.allocator`, which reports anything left behind
/// when the test ends and panics on a second free of a block it already
/// released, so a count that moves when it must not is a failure and a count
/// that never moves is a leak the checker reports on its own.
fn releaseCounting(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: *T,
    counter: *std.testing.FailingAllocator,
) usize {
    const before = counter.deallocations;
    dropTemporary(gpa, value);
    return counter.deallocations - before;
}

/// Release one block twice and report what the first release freed.
///
/// The second release must free nothing, and the first must free something,
/// or the claim being checked would hold vacuously.
fn releaseTwiceCounting(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: *T,
    counter: *std.testing.FailingAllocator,
) !usize {
    const freed = releaseCounting(T, gpa, value, counter);
    try std.testing.expect(freed > 0);
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(T, gpa, value, counter));
    return freed;
}

test "a release that reaches one block twice frees only the first time" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // Every shape a translated value can arrive in, and the exact number of
    // allocations the first release owes each one. A release that skipped a
    // block, or freed one it did not own, shows up as a wrong number rather
    // than as a release that quietly did nothing.
    var text = try String.from_str(gpa, "string owner");
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(String, gpa, &text, &tracking));

    var bytes: Vec(u8) = try vec_from_slice(u8, gpa, "vector owner");
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(Vec(u8), gpa, &bytes, &tracking));

    // Two element slabs and the slab that holds them.
    var strings: Vec(String) = .empty;
    try strings.append(gpa, try String.from_str(gpa, "first element"));
    try strings.append(gpa, try String.from_str(gpa, "second element"));
    try std.testing.expectEqual(@as(usize, 3), try releaseTwiceCounting(Vec(String), gpa, &strings, &tracking));

    var numbers: Vec(u32) = try vec_from_slice(u32, gpa, &.{ 1, 2, 3 });
    var cow_numbers = CowSlice(u32).from_owned(&numbers);
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(CowSlice(u32), gpa, &cow_numbers, &tracking));

    var cow_text = try String.from_str(gpa, "owned cow text");
    var owned_cow = CowStr.from_owned(&cow_text);
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(CowStr, gpa, &owned_cow, &tracking));

    var invalid: Vec(u8) = try vec_from_slice(u8, gpa, "ok\xf0\x90");
    var failure = switch (String.from_utf8(&invalid)) {
        .Ok => return error.ExpectedInvalidUtf8,
        .Err => |detail| detail,
    };
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(FromUtf8Error, gpa, &failure, &tracking));

    // The wrappers inherit the promise from the payloads they hold, and a
    // vector is the payload they cannot do without: `std.ArrayList.deinit`
    // leaves its receiver `undefined`, so a vector that did not empty itself
    // here would make every wrapper below a double free.
    var optional: ?String = try String.from_str(gpa, "optional owner");
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(?String, gpa, &optional, &tracking));

    var nested_optional: ?Vec(u8) = try vec_from_slice(u8, gpa, "nested vector owner");
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(?Vec(u8), gpa, &nested_optional, &tracking));

    var absent: ?String = null;
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(?String, gpa, &absent, &tracking));

    var union_payload: error{Failed}!String = try String.from_str(gpa, "error union owner");
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(error{Failed}!String, gpa, &union_payload, &tracking));

    // The tag survives a release because a tag names a shape rather than
    // storage, so the arm it still names is the one the second pass reaches.
    var result: Result(String, Vec(u8)) = .{ .Err = try vec_from_slice(u8, gpa, "result error owner") };
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(Result(String, Vec(u8)), gpa, &result, &tracking));

    var pair: [2]Vec(u8) = .{
        try vec_from_slice(u8, gpa, "left owner"),
        try vec_from_slice(u8, gpa, "right owner"),
    };
    try std.testing.expectEqual(@as(usize, 2), try releaseTwiceCounting([2]Vec(u8), gpa, &pair, &tracking));

    var tuple_cow = try String.from_str(gpa, "tuple cow owner");
    var wrapper: ReleaseShapeWrapper = .{
        try String.from_str(gpa, "tuple string owner"),
        try vec_from_slice(u8, gpa, "tuple vector owner"),
        CowStr.from_owned(&tuple_cow),
    };
    try std.testing.expectEqual(@as(usize, 3), try releaseTwiceCounting(ReleaseShapeWrapper, gpa, &wrapper, &tracking));
}

test "a release aimed at a borrowed Cow frees none of the caller's bytes" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The caller's storage is heap allocated, so a release that followed the
    // borrow either frees it out from under the caller — which the read below
    // catches and the leak checker reports at the end — or frees it again,
    // which panics inside the leak checker.
    var caller: String = try String.from_str(gpa, "caller owned bytes");
    const caller_address = @intFromPtr(caller.as_bytes().ptr);

    var borrowed: CowStr = CowStr.from_borrowed(caller.as_bytes());
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(CowStr, gpa, &borrowed, &tracking));

    var borrowed_slice: CowSlice(u8) = CowSlice(u8).from_borrowed(caller.as_bytes());
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(CowSlice(u8), gpa, &borrowed_slice, &tracking));

    // The same borrow one level down. A list walks its elements, and a
    // borrowed element is none of the list's business, so the only block this
    // release owes is the slab the list itself holds.
    var borrowed_elements: Vec(CowStr) = .empty;
    try borrowed_elements.append(gpa, CowStr.from_borrowed(caller.as_bytes()));
    try borrowed_elements.append(gpa, CowStr.from_borrowed("static literal"));
    try std.testing.expectEqual(@as(usize, 1), try releaseTwiceCounting(Vec(CowStr), gpa, &borrowed_elements, &tracking));

    // The caller still owns every byte, at the address it allocated them, and
    // releases them itself exactly once.
    try std.testing.expectEqual(caller_address, @intFromPtr(caller.as_bytes().ptr));
    try std.testing.expectEqualStrings("caller owned bytes", caller.as_str());
    try std.testing.expectEqual(@as(usize, 1), releaseCounting(String, gpa, &caller, &tracking));
}

test "a comparison operand bound with a plain defer releases once per owned operand" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();
    const before = tracking.deallocations;

    // The shape a translated `==` between owned rvalues emits: each operand is
    // bound to a mutable local of its own type and released by an
    // unconditional `defer` at the end of the comparison block. Nothing moves
    // an operand out of that block, so each defer is that operand's only
    // release and the comparison itself borrows every one of them.
    {
        var left: String = try String.from_str(gpa, "left operand");
        defer dropTemporary(gpa, &left);
        var borrowed: CowStr = CowStr.from_borrowed("borrowed operand");
        defer dropTemporary(gpa, &borrowed);
        var right: Vec(u8) = try vec_from_slice(u8, gpa, "right operand");
        defer dropTemporary(gpa, &right);

        try std.testing.expect(!std.mem.eql(u8, left.as_str(), borrowed.as_ref()));
        try std.testing.expect(!std.mem.eql(u8, right.items, "left operand"));
        try std.testing.expectEqualStrings("borrowed operand", borrowed.as_ref());
    }

    // The string and the vector, and not the borrow.
    try std.testing.expectEqual(before + 2, tracking.deallocations);
}

test "a moved container and the frame that built it release once between them" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The shape an owned element arrives in: the frame that built it and the
    // destination that took it are two releases over one block, and only one
    // of them may free. The frame's release runs first here, which is the
    // order a scope end and an `errdefer` both reach it in.
    var text = try String.from_str(gpa, "moved string");
    var string_owner = takeOwned(String, &text);
    const after_string_move = tracking.deallocations;
    dropTemporary(gpa, &text);
    try std.testing.expectEqual(after_string_move, tracking.deallocations);
    dropTemporary(gpa, &string_owner);
    try std.testing.expectEqual(after_string_move + 1, tracking.deallocations);
    dropTemporary(gpa, &string_owner);
    try std.testing.expectEqual(after_string_move + 1, tracking.deallocations);

    var numbers: Vec(u32) = try vec_from_slice(u32, gpa, &.{ 4, 5 });
    var borrowed_cow = CowSlice(u32).from_owned(&numbers);
    var cow_owner = takeOwned(CowSlice(u32), &borrowed_cow);
    const after_cow_move = tracking.deallocations;
    dropTemporary(gpa, &numbers);
    try std.testing.expectEqual(after_cow_move, tracking.deallocations);
    dropTemporary(gpa, &cow_owner);
    try std.testing.expectEqual(after_cow_move + 1, tracking.deallocations);

    var moved_bytes: Vec(u8) = try vec_from_slice(u8, gpa, "moved vector");
    var vector_owner = takeOwned(Vec(u8), &moved_bytes);
    const after_vector_move = tracking.deallocations;
    dropTemporary(gpa, &moved_bytes);
    try std.testing.expectEqual(after_vector_move, tracking.deallocations);
    dropTemporary(gpa, &vector_owner);
    try std.testing.expectEqual(after_vector_move + 1, tracking.deallocations);

    var cow_text = try String.from_str(gpa, "moved cow text");
    var owned_cow = CowStr.from_owned(&cow_text);
    var owned_cow_owner = takeOwned(CowStr, &owned_cow);
    const after_owned_cow_move = tracking.deallocations;
    dropTemporary(gpa, &cow_text);
    try std.testing.expectEqual(after_owned_cow_move, tracking.deallocations);
    dropTemporary(gpa, &owned_cow_owner);
    try std.testing.expectEqual(after_owned_cow_move + 1, tracking.deallocations);

    // A borrow names storage neither side owns, so the move and the two
    // releases over it between them free nothing at all.
    var borrowed = CowStr.from_borrowed("borrowed text");
    var borrowed_owner = takeOwned(CowStr, &borrowed);
    const before_borrowed_moves = tracking.deallocations;
    dropTemporary(gpa, &borrowed);
    dropTemporary(gpa, &borrowed_owner);
    try std.testing.expectEqual(before_borrowed_moves, tracking.deallocations);
}

test "a transferred element and the frame that staged it release once between them" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // The block an owned list element is built in, written the way the emitter
    // writes it: a mutable local of the element type, an `errdefer` that
    // releases it if the list cannot take it, and a `takeOwned` that hands it
    // over once the room is there. Both releases run on the same block, so
    // the frame's `defer` below has to find nothing left to free.
    {
        var slot = try String.from_str(gpa, "staged element");
        defer dropTemporary(gpa, &slot);
        var destination: Vec(String) = .empty;
        defer dropTemporary(gpa, &destination);
        try destination.ensureUnusedCapacity(gpa, 1);
        destination.appendAssumeCapacity(takeOwned(String, &slot));
        try std.testing.expectEqual(@as(usize, 1), destination.items.len);
        try std.testing.expectEqual(@as(usize, 0), slot.len());
        try std.testing.expectEqualStrings("staged element", destination.items[0].as_str());
    }

    // A push the destination cannot hold releases the transferred element
    // once, and the frame that staged it has nothing left to release. The
    // room is exactly one element and one element is held, so the push has to
    // resize; both counters are armed so the resize fails whether it allocates
    // afresh or grows the slab where it stands.
    {
        var slot = try String.from_str(gpa, "rejected element");
        defer dropTemporary(gpa, &slot);
        var full = try Vec(String).initCapacity(gpa, 1);
        defer dropTemporary(gpa, &full);
        full.appendAssumeCapacity(try String.from_str(gpa, "kept element"));
        const before_push = tracking.deallocations;
        tracking.fail_index = tracking.alloc_index;
        tracking.resize_fail_index = tracking.resize_index;
        try std.testing.expectError(
            error.OutOfMemory,
            vec_push_owned(String, gpa, &full, takeOwned(String, &slot)),
        );
        // The transferred element, and nothing else: the element the
        // destination already held is still the caller's to release.
        try std.testing.expectEqual(before_push + 1, tracking.deallocations);
        try std.testing.expectEqual(@as(usize, 0), slot.len());
        try std.testing.expectEqual(@as(usize, 1), full.items.len);
        try std.testing.expectEqualStrings("kept element", full.items[0].as_str());
    }
}

test "takeOwned empties a moved Cow slice and Cow str in place, and the source then releases nothing" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // One owner of each kind the two Cow arms add: the `CowSlice` payload is
    // itself a wrapper holding three blocks, so emptying it in place has to
    // rewrite a union whose payload is a tuple rather than a bare vector. The
    // `String` beside them gives the wrapper a second arm whose emptied state
    // is readable as bytes rather than as a union tag.
    const CowMoveWrapper = @Tuple(&.{ CowSlice(OwnedVecTestTuple), CowStr, String });
    var cow_elements = try Vec(OwnedVecTestTuple).initCapacity(gpa, 1);
    errdefer dropTemporary(gpa, &cow_elements);
    var cow_tuple: OwnedVecTestTuple = tuple: {
        var array: [2]?String = .{ null, null };
        errdefer dropTemporary(gpa, &array);
        array[0] = try String.from_str(gpa, "array first");
        array[1] = try String.from_str(gpa, "array second");
        var result: Result(String, String) = .{ .Err = try String.from_str(gpa, "result error") };
        errdefer dropTemporary(gpa, &result);
        const success: error{Rejected}!String = try String.from_str(gpa, "union success");
        break :tuple .{ array, result, success };
    };
    errdefer dropTemporary(gpa, &cow_tuple);
    cow_elements.appendAssumeCapacity(takeOwned(OwnedVecTestTuple, &cow_tuple));
    var cow_text = try String.from_str(gpa, "cow wrapper text");
    errdefer dropTemporary(gpa, &cow_text);
    var cow_string = try String.from_str(gpa, "cow wrapper string");
    errdefer dropTemporary(gpa, &cow_string);

    // Every block is built before any of them is handed over, so a failure
    // while the wrapper is being assembled leaves the errdefers above holding
    // every owner rather than half of them.
    var wrapper: CowMoveWrapper = .{
        // `from_owned` empties what it takes over, so the frame that built the
        // vector and the owner it hands the vector to are one release between
        // them rather than two.
        CowSlice(OwnedVecTestTuple).from_owned(&cow_elements),
        CowStr.from_owned(&cow_text),
        cow_string,
    };
    cow_string = .empty;

    // The address the source built the string at, which the owner must still
    // be naming after the move.
    const cow_address = @intFromPtr(wrapper[2].as_bytes().ptr);
    try std.testing.expectEqual(@as(usize, 1), wrapper[0].as_ref().len);

    var owner = takeOwned(CowMoveWrapper, &wrapper);

    // Both Cows are empty in place. `CowSlice` and `CowStr` write `.empty`,
    // which is a borrow of nothing, so the released union names no storage and
    // the source is left holding nothing the owner has not taken.
    try std.testing.expectEqual(@as(usize, 0), wrapper[0].as_ref().len);
    try std.testing.expect(wrapper[0] == .Borrowed);
    try std.testing.expectEqual(@as(usize, 0), wrapper[1].as_ref().len);
    try std.testing.expect(wrapper[1] == .Borrowed);
    try std.testing.expectEqual(@as(usize, 0), wrapper[2].len());

    const before_source_release = tracking.deallocations;
    dropTemporary(gpa, &wrapper);
    try std.testing.expectEqual(before_source_release, tracking.deallocations);

    // The owner reads the string the source built at the address it already
    // had, so the transfer handed the descriptor over instead of copying the
    // bytes into a second owner. The Cow fields are read for their bytes rather
    // than their address: emptying a `Cow` rewrites it to a borrow of nothing,
    // so the pointer it names after the move is not the one it named before.
    try std.testing.expectEqual(cow_address, @intFromPtr(owner[2].as_bytes().ptr));
    try std.testing.expectEqualStrings("cow wrapper text", owner[1].as_ref());
    try std.testing.expectEqualStrings("cow wrapper string", owner[2].as_str());

    // The payload tuple is still whole on the other side: both array slots, the
    // `Result` arm and the error union's payload, at the bytes the source built.
    try std.testing.expectEqualStrings("array first", owner[0].as_ref()[0][0][0].?.as_str());
    try std.testing.expectEqualStrings("array second", owner[0].as_ref()[0][0][1].?.as_str());
    try std.testing.expectEqualStrings("result error", owner[0].as_ref()[0][1].Err.as_str());
    try std.testing.expectEqualStrings("union success", (owner[0].as_ref()[0][2] catch unreachable).as_str());

    // The payload's four element blocks and the slab that holds them, the Cow
    // text, and the string beside it: seven blocks, released once each.
    const before_owner_release = tracking.deallocations;
    dropTemporary(gpa, &owner);
    try std.testing.expectEqual(before_owner_release + 7, tracking.deallocations);
}

test "a first release over a handle that owns nothing frees no block and is not counted" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = tracking.allocator();

    // A handle that was never filled reaches the allocator with a zero-length
    // slice, which frees no block and so moves no count. That is the same
    // bookkeeping the second release of a filled handle is measured by, and it
    // is what makes a count over an emptied handle mean "nothing was released"
    // rather than "one no-op release happened".
    var unallocated: String = .empty;
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(String, gpa, &unallocated, &tracking));
    try std.testing.expectEqual(@as(usize, 0), unallocated.len());

    // An empty list is the same case one level down: the element walk has
    // nothing to release and the slab is not there to free.
    var empty_list: Vec(String) = .empty;
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(Vec(String), gpa, &empty_list, &tracking));

    // The other direction of the same claim: a release that DID free a block
    // writes the released state back through the handle, so the second one is
    // free by the idempotence rule rather than because the first one skipped
    // the container. `capacity` is the observable that distinguishes the two —
    // a handle left `undefined` would not answer zero.
    var filled_then_empty = try String.from_str(gpa, "filled then emptied");
    try std.testing.expectEqual(@as(usize, 1), releaseCounting(String, gpa, &filled_then_empty, &tracking));
    try std.testing.expectEqual(@as(usize, 0), filled_then_empty.len());
    try std.testing.expectEqual(@as(usize, 0), filled_then_empty.capacity());
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(String, gpa, &filled_then_empty, &tracking));

    // And the same for a list, where `std.ArrayList.deinit` leaves the receiver
    // `undefined` rather than empty. The reset `dropTemporary` writes after it
    // is what makes the second release free, and this is the shape that proves
    // it: without the reset the count below would be a second free of a slab.
    var filled_list = try Vec(String).initCapacity(gpa, 2);
    try filled_list.append(gpa, try String.from_str(gpa, "list first"));
    // The element slab and the one string it holds.
    try std.testing.expectEqual(@as(usize, 2), releaseCounting(Vec(String), gpa, &filled_list, &tracking));
    try std.testing.expectEqual(@as(usize, 0), filled_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), filled_list.capacity);
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(Vec(String), gpa, &filled_list, &tracking));

    // A Cow in its released state is a borrow of nothing, so the release frees
    // none of the caller's bytes and counts no block.
    var released_cow: CowStr = .empty;
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(CowStr, gpa, &released_cow, &tracking));
    try std.testing.expect(released_cow == .Borrowed);
    try std.testing.expectEqual(@as(usize, 0), released_cow.as_ref().len);

    var released_cow_slice: CowSlice(u32) = .empty;
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(CowSlice(u32), gpa, &released_cow_slice, &tracking));
    try std.testing.expect(released_cow_slice == .Borrowed);

    // The wrapper over three such handles is the case a translated frame
    // reaches when every owner it was handed has already been moved on: three
    // containers emptied, zero blocks freed, and the count proving it.
    var wrapper: ReleaseShapeWrapper = .{
        .empty,
        .empty,
        .empty,
    };
    try std.testing.expectEqual(@as(usize, 0), releaseCounting(ReleaseShapeWrapper, gpa, &wrapper, &tracking));

    // And the same count over a filled handle of the same shape, so the zero
    // above is the emptiness and not an allocator that never counts.
    var filled_cow = try String.from_str(gpa, "counted cow text");
    // A no-op once the wrapper below takes it over, and the release that has to
    // happen on a path that fails before it does.
    defer dropTemporary(gpa, &filled_cow);
    var filled: ReleaseShapeWrapper = .{
        try String.from_str(gpa, "counted string"),
        try vec_from_slice(u8, gpa, "counted vector"),
        CowStr.from_owned(&filled_cow),
    };
    try std.testing.expectEqual(@as(usize, 3), releaseCounting(ReleaseShapeWrapper, gpa, &filled, &tracking));
}
