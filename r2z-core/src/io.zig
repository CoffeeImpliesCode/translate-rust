//! Rust `std::io` compatibility primitives: borrowed errors, exact-read and
//! write-all loops over caller-owned receivers, the buffered-read surface
//! (`fill_buf` / `consume` / `BufReader`), and borrowed handles to concrete
//! `Read`, `Write` and `Error` implementors.
//!
//! Nothing here opens a file, allocates a buffer, or stores an allocator of
//! its own, but not every call is allocation-free: `write_all` and `DynWrite`
//! take an allocator because a receiver that is a caller-owned `Vec(u8)` grows
//! through it. Every other receiver writes into storage the caller already
//! owns, so those paths allocate nothing. An allocation failure on a vector
//! receiver surfaces as `error.OutOfMemory`, never as an invented I/O
//! category.
//!
//! Every type borrows. `SliceReader`, `SliceWriter`, `Cursor`, `DynRead`,
//! `DynWrite` and `DynError` own nothing and free nothing; their pointers and
//! slices must stay alive and unmodified for as long as a handle names them.
//! `DynWrite` additionally borrows its allocator, and reaches it only when a
//! write appends to a caller-owned vector.
//!
//! `BufReader` is the one type here that owns storage: it holds an 8 KiB
//! window inline, beside the inner reader it was handed. That storage is
//! bounded and fixed at construction, so the reader itself allocates nothing
//! and has no allocator and no release step. A read that its inner reader
//! performs may still allocate inside that reader, which is that reader's
//! own business and not a property of this one.
//!
//! A buffer `fill_buf` hands back is a BORROW OF THAT INLINE WINDOW, not a
//! buffer the caller receives ownership of: it points into the receiver's own
//! storage, and this module never allocates it and never releases it. So the
//! loop shape adler's `adler32` uses — `fill_buf`, exit on an empty buffer
//! without a matching `consume` — releases nothing, because nothing is owned,
//! and drops nothing, because the bytes never left the reader. The borrow is
//! valid until the next operation that mutates the receiver, and a later refill
//! writes through that same storage, which is what invalidates it.
//!
//! `Error` borrows its `explicit_message` and owns nothing. Its vtable
//! dispatches on the calling thread, synchronously, inside the call that
//! reaches it, and `DynError` adds no lifetime of its own to the borrowed
//! error.

const std = @import("std");
const Result = @import("result.zig").Result;

/// This module's own container, so a method that shares its name with a
/// module function (`DynRead.read_exact`, `DynWrite.write_all`) still reaches
/// the module function instead of itself.
const io = @This();

/// Rust's non-exhaustive categories for I/O failures.
///
/// A tag names a failure class, not a message. Every tag has one stable
/// default message, which is what `Error.format` renders when
/// `Error.explicit_message` is `null`. A receiver that reports one of these
/// tags keeps it: `read_exact` and `write_all` never rewrite a concrete
/// failure into another category, and retry only `Interrupted`.
pub const ErrorKind = enum {
    NotFound,
    PermissionDenied,
    ConnectionRefused,
    ConnectionReset,
    HostUnreachable,
    NetworkUnreachable,
    ConnectionAborted,
    NotConnected,
    AddrInUse,
    AddrNotAvailable,
    NetworkDown,
    BrokenPipe,
    AlreadyExists,
    WouldBlock,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    ReadOnlyFilesystem,
    FilesystemLoop,
    StaleNetworkFileHandle,
    InvalidInput,
    InvalidData,
    TimedOut,
    WriteZero,
    StorageFull,
    NotSeekable,
    QuotaExceeded,
    FileTooLarge,
    ResourceBusy,
    ExecutableFileBusy,
    Deadlock,
    CrossesDevices,
    TooManyLinks,
    InvalidFilename,
    ArgumentListTooLong,
    Interrupted,
    Unsupported,
    UnexpectedEof,
    OutOfMemory,
    InProgress,
    TooManyOpenFiles,
    Other,

    fn default_message(self: @This()) []const u8 {
        return switch (self) {
            .NotFound => "entity not found",
            .PermissionDenied => "permission denied",
            .ConnectionRefused => "connection refused",
            .ConnectionReset => "connection reset",
            .HostUnreachable => "host unreachable",
            .NetworkUnreachable => "network unreachable",
            .ConnectionAborted => "connection aborted",
            .NotConnected => "not connected",
            .AddrInUse => "address in use",
            .AddrNotAvailable => "address not available",
            .NetworkDown => "network down",
            .BrokenPipe => "broken pipe",
            .AlreadyExists => "entity already exists",
            .WouldBlock => "operation would block",
            .NotADirectory => "not a directory",
            .IsADirectory => "is a directory",
            .DirectoryNotEmpty => "directory not empty",
            .ReadOnlyFilesystem => "read-only filesystem",
            .FilesystemLoop => "filesystem loop",
            .StaleNetworkFileHandle => "stale network file handle",
            .InvalidInput => "invalid input",
            .InvalidData => "invalid data",
            .TimedOut => "timed out",
            .WriteZero => "failed to write whole buffer",
            .StorageFull => "storage full",
            .NotSeekable => "not seekable",
            .QuotaExceeded => "quota exceeded",
            .FileTooLarge => "file too large",
            .ResourceBusy => "resource busy",
            .ExecutableFileBusy => "executable file busy",
            .Deadlock => "deadlock",
            .CrossesDevices => "cross-device link",
            .TooManyLinks => "too many links",
            .InvalidFilename => "invalid filename",
            .ArgumentListTooLong => "argument list too long",
            .Interrupted => "interrupted",
            .Unsupported => "operation not supported",
            .UnexpectedEof => "failed to fill whole buffer",
            .OutOfMemory => "out of memory",
            .InProgress => "operation in progress",
            .TooManyOpenFiles => "too many open files",
            .Other => "other I/O error",
        };
    }
};

/// A borrowed I/O failure with a Rust-compatible category and message.
///
/// `Error` owns nothing: `explicit_message` is a slice the caller keeps and
/// must outlive this value. Copying an `Error` copies that pointer, so a copy
/// names the same message and needs no separate release.
pub const Error = struct {
    /// The Rust `ErrorKind` this failure stands for, preserved through every
    /// operation that carries an `Error`.
    error_kind: ErrorKind,
    /// Message text to render, borrowed from the caller. `null` means the
    /// failure carries no message of its own, and `format` renders the stable
    /// default for `error_kind` instead. It never means "no error": the
    /// absence of a `Result` wrapper is what carries that.
    explicit_message: ?[]const u8 = null,

    /// Construct an error without copying the caller-borrowed message.
    ///
    /// `message` is borrowed, not retained as owned storage: it must stay alive
    /// and unmodified for as long as the returned `Error` is read.
    pub fn new(error_kind: ErrorKind, message: []const u8) @This() {
        return .{
            .error_kind = error_kind,
            .explicit_message = message,
        };
    }

    /// Construct an error using the stable message for its category, with
    /// `explicit_message` left `null`.
    pub fn from_kind(error_kind: ErrorKind) @This() {
        return .{ .error_kind = error_kind };
    }

    /// Return the preserved Rust error category.
    pub fn kind(self: @This()) ErrorKind {
        return self.error_kind;
    }

    /// Rust `Display for io::Error`: write the explicit message, or the
    /// category's stable default when `explicit_message` is `null`.
    ///
    /// This is the native Zig `{f}` hook as well, so the same receiver serves
    /// `std.Io.Writer.print` and `r2z.format.write`. `writer` is borrowed for
    /// the call, retains nothing, and its own failure — including a short
    /// buffer — is returned unchanged, with the bytes written before it left
    /// in place.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.explicit_message orelse self.error_kind.default_message());
    }
};

/// True when `W` points at a caller-owned byte-slice descriptor, the shape
/// Rust's `impl Read for &[u8]` and `impl Write for &mut [u8]` take. The
/// descriptor is consumed in place, so the caller sees every byte move.
fn isSliceDescriptor(comptime W: type) bool {
    const outer = @typeInfo(W);
    if (outer != .pointer) return false;
    const inner = @typeInfo(std.meta.Child(W));
    if (inner != .pointer or inner.pointer.size != .slice) return false;
    return inner.pointer.child == u8;
}

/// True when `W` points at a caller-owned byte vector, the shape
/// `impl Write for Vec<u8>` takes: every write appends to that vector instead
/// of overwriting fixed storage.
fn isByteVector(comptime W: type) bool {
    const outer = @typeInfo(W);
    if (outer != .pointer) return false;
    return std.meta.Child(W) == std.ArrayList(u8);
}

/// True when `C` is a container that publishes `name`. A native receiver such
/// as a byte-slice descriptor owns no declarations at all, so it is never
/// handed to `@hasDecl`; the shape predicates above admit those on their own.
fn hasMethod(comptime C: type, comptime name: []const u8) bool {
    return switch (@typeInfo(C)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(C, name),
        else => false,
    };
}

/// Read until `bytes` is full, retrying only interrupted operations.
///
/// `reader` is a caller-owned object: an object with a `read` method, or a
/// byte-slice descriptor, which is advanced in place as its bytes are copied
/// and is therefore empty when the source runs out. `bytes` is the caller's
/// storage and is written in place.
///
/// A short read is not an error: the loop keeps going. On the failing path
/// every byte already transferred stays in `bytes[0..filled]`, the rest of
/// `bytes` keeps whatever the caller passed, and the reader has already
/// consumed exactly those bytes. `error.UnexpectedEof` means the source ran
/// out at a short read; any other concrete category is returned unchanged.
/// Allocating nothing.
pub fn read_exact(reader: anytype, bytes: []u8) Result(void, Error) {
    var filled: usize = 0;
    while (filled < bytes.len) {
        switch (readChunk(reader, bytes[filled..])) {
            .Ok => |count| {
                const remaining = bytes.len - filled;
                if (count > remaining) {
                    return .{
                        .Err = Error.new(
                            .InvalidData,
                            "reader returned more bytes than requested",
                        ),
                    };
                }
                if (count == 0) return .{ .Err = Error.from_kind(.UnexpectedEof) };
                filled += count;
            },
            .Err => |failure| {
                if (failure.kind() == .Interrupted) continue;
                return .{ .Err = failure };
            },
        }
    }
    return .{ .Ok = {} };
}

/// One read attempt, dispatched on the receiver's shape so a caller-owned
/// slice descriptor and a reader object with its own `read` both reach the
/// same loop above. A dynamic handle reaches a descriptor through this same
/// dispatch, so a `&[u8]` advances and drains identically behind a handle as
/// it does directly.
fn readChunk(reader: anytype, bytes: []u8) Result(usize, Error) {
    if (comptime isSliceDescriptor(@TypeOf(reader))) {
        const source = reader.*;
        if (source.len == 0) return .{ .Ok = 0 };
        const count = @min(source.len, bytes.len);
        @memcpy(bytes[0..count], source[0..count]);
        reader.* = source[count..];
        return .{ .Ok = count };
    } else {
        return reader.read(bytes);
    }
}

/// Borrow the reader's currently buffered bytes, Rust `BufRead::fill_buf`.
///
/// `reader` is a caller-owned object reached through a mutable handle — a
/// `SliceReader`, a `Cursor(T)`, a `BufReader(R)`, or a byte-slice descriptor
/// — and is never copied by value, so the borrow names the caller's own
/// storage and `consume` advances that same storage. A byte-slice descriptor
/// hands back its whole unread remainder, which is what
/// `impl BufRead for &[u8]` does; the reader types hand back the window they
/// already hold and reach their inner reader only when that window is empty.
///
/// The returned slice is a BORROW the runtime owns and lends out, never a
/// buffer the caller owns: it aliases the receiver's own storage — the caller's
/// slice, or the reader's inline window — and the runtime neither allocates it
/// nor releases it. There is therefore nothing for a caller to free, and a
/// loop that takes the window and exits WITHOUT calling `consume` — the shape
/// adler's `adler32` has before it returns on an empty buffer — leaks nothing
/// and loses nothing: the bytes stay in the receiver, and the next `fill_buf`
/// hands back the same window from the same address.
///
/// The borrow stays valid until the next operation that mutates that receiver.
/// A later refill writes through that same storage, so an already-handed-out
/// slice then reads the NEW window's bytes. That is the invalidation the Rust
/// borrow checker reports statically, and the reason a caller must be done with
/// a window before it consumes, reads, or refills. Allocating nothing.
pub fn fill_buf(reader: anytype) Result([]const u8, Error) {
    if (comptime isSliceDescriptor(@TypeOf(reader))) {
        return .{ .Ok = reader.* };
    } else {
        return reader.fill_buf();
    }
}

/// Mark `count` of the reader's buffered bytes as read, Rust
/// `BufRead::consume`.
///
/// `reader` is reached through a mutable handle exactly as `fill_buf` is, so
/// the advance lands on the caller's own storage. The count is not clamped to
/// what is buffered. A byte-slice descriptor advances by slicing, so a count
/// past its end panics the way Rust's own `&self[amt..]` does, and `Cursor`
/// adds to its position, which may therefore move past the end of its input.
/// Allocating nothing.
pub fn consume(reader: anytype, count: usize) void {
    if (comptime isSliceDescriptor(@TypeOf(reader))) {
        if (count > reader.*.len) {
            std.debug.panic("io.consume: count {d} exceeds the {d} bytes buffered", .{
                count,
                reader.*.len,
            });
        }
        reader.* = reader.*[count..];
    } else {
        reader.consume(count);
    }
}

/// Write until `bytes` is consumed, retrying only interrupted operations.
///
/// Only a caller-owned byte vector grows, and it grows through the allocator
/// threaded in here; every other receiver writes into storage the caller
/// already owns, so those paths allocate nothing. A vector that cannot grow is
/// a genuine allocation failure and surfaces as `error.OutOfMemory`, never as
/// a fabricated I/O category. `gpa` is borrowed for the call and is never
/// retained; a vector receiver must therefore outlive this call only.
///
/// A short write is not an error: the loop keeps going. On the failing path
/// every byte already written stays where the receiver put it, the receiver
/// has consumed exactly those bytes of `bytes`, and `error.WriteZero` means
/// the receiver accepted nothing while `bytes` still had bytes left. Any
/// other concrete category is returned unchanged.
pub fn write_all(
    gpa: std.mem.Allocator,
    writer: anytype,
    bytes: []const u8,
) std.mem.Allocator.Error!Result(void, Error) {
    var written: usize = 0;
    while (written < bytes.len) {
        switch (try writeChunk(gpa, writer, bytes[written..])) {
            .Ok => |count| {
                const remaining = bytes.len - written;
                if (count > remaining) {
                    return .{
                        .Err = Error.new(
                            .InvalidData,
                            "writer returned more bytes than requested",
                        ),
                    };
                }
                if (count == 0) return .{ .Err = Error.from_kind(.WriteZero) };
                written += count;
            },
            .Err => |failure| {
                if (failure.kind() == .Interrupted) continue;
                return .{ .Err = failure };
            },
        }
    }
    return .{ .Ok = {} };
}

/// One write attempt, dispatched on the receiver's shape so a caller-owned
/// vector, a caller-owned slice descriptor, and a writer object with its own
/// `write` all reach the same loop above.
fn writeChunk(
    gpa: std.mem.Allocator,
    writer: anytype,
    chunk: []const u8,
) std.mem.Allocator.Error!Result(usize, Error) {
    if (comptime isByteVector(@TypeOf(writer))) {
        try writer.appendSlice(gpa, chunk);
        return .{ .Ok = chunk.len };
    } else if (comptime isSliceDescriptor(@TypeOf(writer))) {
        const target = writer.*;
        if (target.len == 0) return .{ .Ok = 0 };
        const count = @min(chunk.len, target.len);
        @memcpy(target[0..count], chunk[0..count]);
        writer.* = target[count..];
        return .{ .Ok = count };
    } else {
        return writer.write(chunk);
    }
}

/// A borrowed, cursor-based reader over an immutable byte slice.
///
/// `SliceReader` owns nothing and frees nothing: `input` is borrowed and must
/// stay alive and unmodified for as long as the reader is used. A copy is a
/// second cursor over the same input, not a second owner, so advancing either
/// copy leaves the other where it was and neither needs a release.
pub const SliceReader = struct {
    /// The borrowed source. Its length bounds `position`.
    input: []const u8,
    /// Bytes already consumed. `read` keeps it at or below `input.len`; a
    /// value built by hand must satisfy that before the first `read`.
    position: usize = 0,

    /// Borrow `input` without allocating or copying it.
    pub fn init(input: []const u8) @This() {
        return .{ .input = input };
    }

    /// Consume at most `bytes.len` bytes and return the count consumed.
    ///
    /// `position` advances by that count, and a read at the end of the input
    /// returns `.Ok = 0` rather than a failure; end of input is the caller's
    /// to detect, and `read_exact` reports it as `UnexpectedEof`. On success
    /// `bytes[0..count]` holds the transferred bytes and the rest keeps
    /// whatever the caller passed.
    pub fn read(self: *@This(), bytes: []u8) Result(usize, Error) {
        std.debug.assert(self.position <= self.input.len);
        const available = self.input.len - self.position;
        const count = @min(bytes.len, available);
        @memcpy(bytes[0..count], self.input[self.position..][0..count]);
        self.position += count;
        return .{ .Ok = count };
    }

    /// Borrow every byte not yet consumed, Rust `BufRead::fill_buf`.
    ///
    /// The window is the reader's own unread remainder of `input` and this
    /// call does not advance `position`; `consume` is what advances it. An
    /// exhausted reader returns an empty slice rather than a failure, which
    /// is how end of input reaches a caller. The borrow is invalidated by the
    /// next operation that mutates this reader. Allocating nothing.
    pub fn fill_buf(self: *@This()) Result([]const u8, Error) {
        std.debug.assert(self.position <= self.input.len);
        return .{ .Ok = self.input[self.position..] };
    }

    /// Mark `count` bytes of the window read, Rust `BufRead::consume`.
    ///
    /// `count` is not clamped to the unread remainder: a count past the end
    /// panics, which is what `&self[amt..]` does in Rust. Allocating nothing.
    pub fn consume(self: *@This(), count: usize) void {
        std.debug.assert(self.position <= self.input.len);
        const available = self.input.len - self.position;
        if (count > available) {
            std.debug.panic("io.SliceReader.consume: count {d} exceeds the {d} unread bytes", .{
                count,
                available,
            });
        }
        self.position += count;
    }
};

/// A borrowed, cursor-based writer over a mutable byte slice.
///
/// `SliceWriter` owns nothing and frees nothing: `output` is the caller's
/// storage and must stay alive for as long as the writer is used. A copy is a
/// second cursor over the same storage, not a second owner, so writes through
/// one are visible through the other and neither needs a release.
pub const SliceWriter = struct {
    /// The caller's destination. Its length bounds `position`.
    output: []u8,
    /// Bytes already written. `write` keeps it at or below `output.len`; a
    /// value built by hand must satisfy that before the first `write`.
    position: usize = 0,

    /// Borrow `output` without allocating or copying it.
    pub fn init(output: []u8) @This() {
        return .{ .output = output };
    }

    /// Consume at most the remaining output capacity and return the count written.
    ///
    /// A full destination reports `.Ok = 0` rather than a failure, which
    /// `write_all` turns into `WriteZero`. Bytes past the destination are never
    /// written and are dropped; `bytes` is borrowed for the call and is not
    /// retained.
    pub fn write(self: *@This(), bytes: []const u8) Result(usize, Error) {
        std.debug.assert(self.position <= self.output.len);
        const available = self.output.len - self.position;
        const count = @min(bytes.len, available);
        @memcpy(self.output[self.position..][0..count], bytes[0..count]);
        self.position += count;
        return .{ .Ok = count };
    }
};

/// A read cursor over a byte source, the shape Rust's `io::Cursor<T>` takes.
/// The source is held by value beside a read position, so a cursor over an
/// owned array allocates nothing and a cursor over a borrowed slice leaves the
/// borrow untouched.
///
/// `T` is either `[N]u8`, which the cursor holds inline and therefore owns, or
/// a byte slice, which the cursor borrows and never frees. The borrowed form is
/// a second view of storage the caller still owns, so the slice must stay
/// alive and unmodified for as long as the cursor is used; the owned form
/// needs no release because nothing was allocated.
pub fn Cursor(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The source: owned inline for an array type, borrowed for a slice.
        inner: T,
        /// Bytes already consumed, as Rust's `Cursor::position`: a `u64`,
        /// because `consume` adds to it and may carry it past the end of the
        /// source. Reads clamp it to the source length, exactly as Rust's
        /// `Cursor::split` does, so a position beyond the end reads as EOF
        /// instead of producing an out-of-range index.
        position: u64 = 0,

        /// Take ownership of, or borrow, the cursor's source.
        pub fn init(inner: T) Self {
            return .{ .inner = inner };
        }

        /// Consume at most the unread bytes left in the cursor's source.
        ///
        /// A read at the end of the source returns `.Ok = 0` rather than a
        /// failure; `read_exact` reports that as `UnexpectedEof`. On success
        /// `bytes[0..count]` holds the transferred bytes and the rest keeps
        /// whatever the caller passed. Allocating nothing.
        pub fn read(self: *Self, bytes: []u8) Result(usize, Error) {
            const source = self.asBytes();
            const offset = self.readOffset(source.len);
            const count = @min(bytes.len, source.len - offset);
            @memcpy(bytes[0..count], source[offset..][0..count]);
            self.position += count;
            return .{ .Ok = count };
        }

        /// Borrow every byte not yet consumed, Rust `BufRead::fill_buf`.
        ///
        /// The window is this cursor's own unread remainder of its source and
        /// the call does not advance `position`; `consume` is what advances
        /// it. A position past the end of the source — which `consume` can
        /// produce — returns an empty slice rather than a failure, which is
        /// how end of input reaches a caller. The borrow is invalidated by the
        /// next operation that mutates this cursor. Allocating nothing.
        pub fn fill_buf(self: *Self) Result([]const u8, Error) {
            const source = self.asBytes();
            return .{ .Ok = source[self.readOffset(source.len)..] };
        }

        /// Mark `count` bytes of the window read, Rust `BufRead::consume`.
        ///
        /// The count is added to `position` without being clamped, which is
        /// what Rust's `set_position(self.position() + amt as u64)` does: a
        /// `count` larger than the window carries the position past the end of
        /// the source, and later reads then report EOF. Allocating nothing.
        pub fn consume(self: *Self, count: usize) void {
            self.position +|= @as(u64, count);
        }

        /// The position as a source index, clamped the way `Cursor::split`
        /// clamps it, so a position beyond the source never indexes past it.
        fn readOffset(self: *const Self, source_len: usize) usize {
            return @intCast(@min(self.position, @as(u64, source_len)));
        }

        fn asBytes(self: *const Self) []const u8 {
            return switch (@typeInfo(T)) {
                .array => &self.inner,
                .pointer => self.inner,
                else => @compileError(
                    "io.Cursor needs an owned byte array or a borrowed byte slice",
                ),
            };
        }
    };
}

/// The type `innerReceiver` reaches this reader's inner source through. A
/// byte-slice source is a descriptor that has to advance in place, so it is
/// passed by address; an `R` that is already a borrow is passed as that
/// borrow; anything else is reached through a pointer to the value held here.
fn BufReaderInner(comptime Reader: type) type {
    if (@typeInfo(Reader) == .pointer) {
        if (@typeInfo(Reader).pointer.size == .slice) return *Reader;
        return Reader;
    }
    return *Reader;
}

/// Rust `io::BufReader<R>` with the default 8 KiB window, the receiver the
/// module's `fill_buf` and `consume` work through on a `Read`.
///
/// This is the one type in the module that owns storage: `buffer` is a fixed
/// 8 KiB window held inline, beside the inner reader `init` was handed. It
/// holds no allocator, needs no release, and allocates nothing itself; a read
/// its inner reader performs may still allocate inside that reader, which is
/// that reader's own business.
///
/// `R` is the inner source. An `R` held by value — an array, a slice, or
/// another reader struct — is this reader's own private copy, so advancing it
/// leaves the caller's original where it was. An `R` that is a pointer is a
/// borrow: every read reaches through it, so the caller's reader holds the
/// read position and must stay alive and unmodified for as long as this
/// reader is used.
///
/// Construction is in-place: `init` fills the caller's storage directly, so
/// the window is never zeroed and never copied into place, and the reader
/// holds no pointer to itself. The window's bytes are undefined until a refill
/// initializes them, and only `fill_buf`'s window and `filled` describe them.
///
/// The failure residue is the module's: a refill that fails leaves an empty
/// window — never a wedged reader — and returns the inner reader's own
/// category and message unchanged. Bytes the inner reader wrote into the
/// window before failing are not served, because `Result`'s failure arm
/// carries no count to say how many there were.
pub fn BufReader(comptime R: type) type {
    return struct {
        const Self = @This();

        /// Rust's `DEFAULT_BUF_SIZE`, the capacity `BufReader::new` installs.
        pub const default_buffer_len: usize = 8 * 1024;

        /// The inner source: this reader's own copy when `R` is a value, or
        /// the borrow it was handed when `R` is a pointer.
        inner: R,
        /// The refill window. Its bytes are undefined until a refill
        /// initializes `buffer[0..filled]`.
        buffer: [default_buffer_len]u8 = undefined,
        /// Bytes of `buffer` the last refill initialized. Always at or above
        /// `pos`; a failed refill leaves it at zero.
        filled: usize = 0,
        /// Offset into `buffer` of the first byte not yet consumed. Always at
        /// or below `filled`.
        pos: usize = 0,

        /// Hold `inner` beside a fresh, empty window, allocating nothing.
        ///
        /// The window is left undefined rather than zeroed, and this reader
        /// stores no pointer to itself, so it is constructed in the caller's
        /// own storage with no copy of the window.
        pub fn init(inner: R) Self {
            return .{ .inner = inner };
        }

        /// Consume at most `bytes.len` bytes, Rust `BufReader`'s `Read`.
        ///
        /// When nothing is buffered and `bytes` is at least as large as the
        /// whole window, the window is discarded and the inner reader is read
        /// straight into `bytes`, which is what Rust does: a copy through the
        /// window would not save an inner read at that size. Any other read
        /// copies only what the window holds right now and advances `pos` by
        /// exactly that much.
        ///
        /// A read that returns `.Ok = 0` is a value, not a failure, and
        /// `read_exact` is what turns it into `UnexpectedEof`.
        pub fn read(self: *Self, bytes: []u8) Result(usize, Error) {
            if (self.pos == self.filled and bytes.len >= default_buffer_len) {
                self.pos = 0;
                self.filled = 0;
                return readChunk(self.innerReceiver(), bytes);
            }
            const window = switch (self.fill_buf()) {
                .Ok => |borrowed| borrowed,
                .Err => |failure| return .{ .Err = failure },
            };
            const count = @min(bytes.len, window.len);
            @memcpy(bytes[0..count], window[0..count]);
            self.consume(count);
            return .{ .Ok = count };
        }

        /// Borrow the buffered bytes, Rust `BufReader`'s `BufRead::fill_buf`.
        ///
        /// The window is served from what is already buffered and the inner
        /// reader is reached only when there is nothing left in it. The
        /// returned slice points into `buffer` itself, so it is a view of this
        /// reader's own storage rather than a copy, and it stays valid until
        /// the next operation that mutates this reader.
        ///
        /// A refill that fails returns the inner reader's own category and
        /// message unchanged and leaves an empty window, so the next call
        /// reaches the inner reader again rather than reporting end of input.
        /// Allocating nothing.
        pub fn fill_buf(self: *Self) Result([]const u8, Error) {
            if (self.pos >= self.filled) {
                switch (readChunk(self.innerReceiver(), self.buffer[0..])) {
                    .Ok => |count| {
                        if (count > default_buffer_len) {
                            return .{
                                .Err = Error.new(
                                    .InvalidData,
                                    "reader returned more bytes than requested",
                                ),
                            };
                        }
                        self.pos = 0;
                        self.filled = count;
                    },
                    .Err => |failure| {
                        self.pos = 0;
                        self.filled = 0;
                        return .{ .Err = failure };
                    },
                }
            }
            return .{ .Ok = self.buffer[self.pos..self.filled] };
        }

        /// Mark `count` buffered bytes read, Rust `BufReader`'s
        /// `BufRead::consume`.
        ///
        /// The advance stops at what is buffered, exactly as Rust's
        /// `cmp::min(self.pos + amt, self.filled)` does, so a count larger
        /// than the window consumes the window and no more. Allocating
        /// nothing.
        pub fn consume(self: *Self, count: usize) void {
            self.pos = @min(self.pos +| count, self.filled);
        }

        fn innerReceiver(self: *Self) BufReaderInner(R) {
            if (@typeInfo(R) == .pointer) {
                if (@typeInfo(R).pointer.size != .slice) return self.inner;
            }
            return &self.inner;
        }
    };
}

/// A borrowed handle to a concrete `std::io::Read` implementor, the fat
/// pointer Rust's `&mut dyn Read` lowers to. The handle owns nothing and every
/// call reaches the caller's own reader through the erased pointer, so read
/// position and error state live exactly where the caller left them.
///
/// `reader` must stay alive and unmodified for as long as a handle names it;
/// nothing checks that, and a handle to a released reader still dispatches.
/// Copying a handle copies the pointer, so a copy is a second alias of one
/// reader and not a second owner; both copies advance the same read position.
///
/// Every dispatch runs on the calling thread, synchronously, inside the call
/// that reaches it, and a receiver may reenter the handle that called it.
pub const DynRead = struct {
    /// Erased pointer to the caller's reader, cast back with its concrete type
    /// on every call.
    ptr: *anyopaque,
    /// The dispatch table `init` built for the concrete type.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called with the erased pointer as `context` and the caller's
        /// destination. It must return how many bytes it wrote into
        /// `bytes[0..count]` and never write past `bytes.len`.
        read: *const fn (context: *anyopaque, bytes: []u8) Result(usize, Error),
    };

    /// Bind a handle to `reader`, which must publish `read` or be a
    /// caller-owned byte-slice descriptor.
    ///
    /// `reader` is borrowed, not captured by value: the handle stores its
    /// address, so a byte-slice descriptor is advanced in place exactly as it
    /// would be without the handle. The handle is valid for as long as
    /// `reader` is, and needs no release.
    pub fn init(reader: anytype) DynRead {
        const Concrete = std.meta.Child(@TypeOf(reader));
        if (comptime !hasMethod(Concrete, "read") and !isSliceDescriptor(@TypeOf(reader))) {
            @compileError(
                "io.DynRead needs a concrete type with a read method or a caller-owned byte-slice descriptor",
            );
        }
        return .{
            .ptr = @ptrCast(reader),
            .vtable = &.{ .read = struct {
                fn call(context: *anyopaque, bytes: []u8) Result(usize, Error) {
                    const self: *Concrete = @ptrCast(@alignCast(context));
                    return readChunk(self, bytes);
                }
            }.call },
        };
    }

    /// Consume at most `bytes.len` bytes from the caller's reader.
    ///
    /// `bytes` is the caller's storage, written in place; the reader's own
    /// state advances by the count returned. A count of zero is a value, not a
    /// failure, and `read_exact` is what turns it into `UnexpectedEof`.
    pub inline fn read(self: DynRead, bytes: []u8) Result(usize, Error) {
        return self.vtable.read(self.ptr, bytes);
    }

    /// Fill `bytes` from the caller's reader, retrying only interruption.
    ///
    /// The failure residue is the module's: on the failing path every byte
    /// already transferred stays in `bytes[0..filled]`, the rest keeps
    /// whatever the caller passed, and the reader has consumed exactly those
    /// bytes.
    pub fn read_exact(self: DynRead, bytes: []u8) Result(void, Error) {
        return io.read_exact(self, bytes);
    }
};

/// A borrowed handle to a concrete `std::io::Write` implementor, the fat
/// pointer Rust's `&mut dyn Write` lowers to. The handle owns nothing; the
/// allocator is borrowed too and reaches the writer only when appending to a
/// caller-owned vector.
///
/// `writer` must stay alive and unmodified for as long as a handle names it;
/// nothing checks that, and a handle to a released writer still dispatches.
/// The stored `allocator` is borrowed and never retained by the callee, so it
/// only has to outlive the handle. Copying a handle copies the pointer, so a
/// copy is a second alias of one writer and not a second owner.
///
/// Every dispatch runs on the calling thread, synchronously, inside the call
/// that reaches it, and a receiver may reenter the handle that called it.
pub const DynWrite = struct {
    /// Erased pointer to the caller's writer, cast back with its concrete type
    /// on every call.
    ptr: *anyopaque,
    /// Borrowed allocator, handed to a write that appends to a caller-owned
    /// byte vector. It is not released by this handle.
    allocator: std.mem.Allocator,
    /// The dispatch table `init` built for the concrete type.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called with the erased pointer as `context`, the handle's borrowed
        /// allocator, and the caller's bytes. It must return how many bytes it
        /// accepted and never accept more than `bytes.len`; only a byte-vector
        /// receiver may use the allocator, and `error.OutOfMemory` from that
        /// one growth reaches the caller unchanged.
        write: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bytes: []const u8,
        ) std.mem.Allocator.Error!Result(usize, Error),
    };

    /// Bind a handle to `writer`, which must publish `write` or be a
    /// caller-owned byte vector or byte-slice descriptor, and to the allocator
    /// its writes may need.
    ///
    /// `writer` is borrowed, not captured by value: a byte vector grows through
    /// `allocator` exactly as it would without the handle, and a byte-slice
    /// descriptor is advanced in place. The handle is valid for as long as
    /// `writer` is, and needs no release.
    pub fn init(writer: anytype, allocator: std.mem.Allocator) DynWrite {
        const Concrete = std.meta.Child(@TypeOf(writer));
        if (comptime !hasMethod(Concrete, "write") and
            Concrete != std.ArrayList(u8) and
            !isSliceDescriptor(@TypeOf(writer)))
        {
            @compileError(
                "io.DynWrite needs a concrete type with a write method, a byte vector, or a caller-owned byte-slice descriptor",
            );
        }
        return .{
            .ptr = @ptrCast(writer),
            .allocator = allocator,
            .vtable = &.{ .write = struct {
                fn call(
                    context: *anyopaque,
                    gpa: std.mem.Allocator,
                    bytes: []const u8,
                ) std.mem.Allocator.Error!Result(usize, Error) {
                    const self: *Concrete = @ptrCast(@alignCast(context));
                    return writeChunk(gpa, self, bytes);
                }
            }.call },
        };
    }

    /// Write at most `bytes.len` bytes through the caller's writer.
    ///
    /// `bytes` is borrowed for the call and not retained. A count of zero is a
    /// value, not a failure, and `write_all` is what turns it into
    /// `WriteZero`; a byte-vector receiver may return `error.OutOfMemory`.
    pub inline fn write(
        self: DynWrite,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Result(usize, Error) {
        return self.vtable.write(self.ptr, self.allocator, bytes);
    }

    /// Write `bytes` in full through the caller's writer, retrying only
    /// interruption.
    ///
    /// The failure residue is the module's: on the failing path every byte
    /// already written stays where the receiver put it, and the receiver has
    /// consumed exactly those bytes of `bytes`.
    pub fn write_all(
        self: DynWrite,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Result(void, Error) {
        return io.write_all(self.allocator, self, bytes);
    }
};

/// A borrowed handle to a concrete `std::error::Error` implementor, the fat
/// pointer Rust's `&dyn Error` lowers to. Formatting and the cause chain both
/// dispatch to the caller's own error value, so no message is reconstructed
/// and no cause is invented.
///
/// `failure` must stay alive and unmodified for as long as a handle names it;
/// nothing checks that, and a handle to a released error still dispatches.
/// Copying a handle copies the pointer, so a copy is a second alias of one
/// error and not a second owner. A cause handed back by `source` is itself a
/// borrowed handle into the same error, so the whole chain dies with the
/// error that carries it.
///
/// Every dispatch runs on the calling thread, synchronously, inside the call
/// that reaches it, and a receiver may reenter the handle that called it.
pub const DynError = struct {
    /// Erased pointer to the caller's error, cast back with its concrete type
    /// on every call.
    ptr: *const anyopaque,
    /// The dispatch table `init` built for the concrete type.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called with the erased pointer as `context` and the caller's
        /// writer. It must render through the concrete type's own `format`
        /// method and return that method's own failure unchanged.
        format: *const fn (
            context: *const anyopaque,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void,
        /// Called with the erased pointer as `context`. A concrete type with
        /// no `source` method answers `null`, which is `std::error::Error`'s
        /// own default rather than an invented cause.
        source: *const fn (context: *const anyopaque) ?DynError,
    };

    /// Bind a handle to `failure`, which must publish `format`. A type with no
    /// explicit `source` keeps `std::error::Error`'s default, which is none.
    ///
    /// `failure` must declare a `format` callable as
    /// `format(self, writer: *std.Io.Writer) std.Io.Writer.Error!void` — the
    /// native hook a translated `Display` lowers to, with a by-value or by-
    /// pointer receiver. A type with no such declaration is a compile error,
    /// so a handle never exists for an error that cannot render itself.
    ///
    /// `failure` is borrowed, not captured by value: the handle stores its
    /// address, and a `*const` handle can therefore never mutate it. The
    /// handle is valid for as long as `failure` is, and needs no release.
    pub fn init(failure: anytype) DynError {
        const Concrete = std.meta.Child(@TypeOf(failure));
        if (!@hasDecl(Concrete, "format")) {
            @compileError("io.DynError needs a concrete type with a format method");
        }
        return .{
            .ptr = failure,
            .vtable = &.{
                .format = struct {
                    fn call(
                        context: *const anyopaque,
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        const self: *const Concrete = @ptrCast(@alignCast(context));
                        return self.format(writer);
                    }
                }.call,
                .source = struct {
                    fn call(context: *const anyopaque) ?DynError {
                        const self: *const Concrete = @ptrCast(@alignCast(context));
                        if (comptime @hasDecl(Concrete, "source")) {
                            return self.source();
                        } else {
                            return null;
                        }
                    }
                }.call,
            },
        };
    }

    /// Borrow the cause this error carries, or null when it carries none.
    ///
    /// The returned handle borrows the cause the concrete error names, so it
    /// is valid exactly as long as that error is. A chain that ends reports
    /// `null`, never itself.
    pub inline fn source(self: DynError) ?DynError {
        return self.vtable.source(self.ptr);
    }

    /// Render this error through the concrete type's own `format`.
    ///
    /// This is the native Zig `{f}` hook as well, so a `DynError` renders
    /// through `std.Io.Writer.print` and through `r2z.format.write` without a
    /// second route. `writer` is borrowed for the call, retains nothing, and
    /// the concrete hook's own failure — including a short buffer — is
    /// returned unchanged, with the bytes written before it left in place.
    pub inline fn format(
        self: DynError,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return self.vtable.format(self.ptr, writer);
    }
};

const ReadStep = union(enum) {
    transfer: usize,
    failure: Error,
};

const ScriptedReader = struct {
    source: []const u8,
    steps: []const ReadStep,
    source_position: usize = 0,
    step_position: usize = 0,
    calls: usize = 0,

    fn init(source: []const u8, steps: []const ReadStep) ScriptedReader {
        return .{ .source = source, .steps = steps };
    }

    pub fn read(self: *ScriptedReader, destination: []u8) Result(usize, Error) {
        std.debug.assert(self.source_position <= self.source.len);
        std.debug.assert(self.step_position < self.steps.len);

        self.calls += 1;
        const step = self.steps[self.step_position];
        self.step_position += 1;
        return switch (step) {
            .transfer => |limit| transfer: {
                const available = self.source.len - self.source_position;
                const count = @min(limit, @min(destination.len, available));
                @memcpy(
                    destination[0..count],
                    self.source[self.source_position..][0..count],
                );
                self.source_position += count;
                break :transfer .{ .Ok = count };
            },
            .failure => |failure| .{ .Err = failure },
        };
    }
};

const WriteStep = union(enum) {
    transfer: usize,
    failure: Error,
};

const ScriptedWriter = struct {
    destination: []u8,
    steps: []const WriteStep,
    destination_position: usize = 0,
    step_position: usize = 0,
    calls: usize = 0,

    fn init(destination: []u8, steps: []const WriteStep) ScriptedWriter {
        return .{ .destination = destination, .steps = steps };
    }

    pub fn write(self: *ScriptedWriter, source: []const u8) Result(usize, Error) {
        std.debug.assert(self.destination_position <= self.destination.len);
        std.debug.assert(self.step_position < self.steps.len);

        self.calls += 1;
        const step = self.steps[self.step_position];
        self.step_position += 1;
        return switch (step) {
            .transfer => |limit| transfer: {
                const available = self.destination.len - self.destination_position;
                const count = @min(limit, @min(source.len, available));
                @memcpy(
                    self.destination[self.destination_position..][0..count],
                    source[0..count],
                );
                self.destination_position += count;
                break :transfer .{ .Ok = count };
            },
            .failure => |failure| .{ .Err = failure },
        };
    }
};
/// Test-only innermost failure. It renders its own borrowed message and counts
/// renders through a cell the caller owns, so a dynamic handle that reached
/// the live object is distinguishable from one that copied or fabricated it.
const CauseFailure = struct {
    message: []const u8,
    rendered: *usize,

    pub fn format(self: CauseFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        self.rendered.* += 1;
        try writer.writeAll(self.message);
    }
};

/// Test-only error that borrows a cause the way a Rust error enum variant
/// wrapping another failure does: `source` hands back a handle onto the stored
/// cause, and `format` renders this level's own message.
const WrappedFailure = struct {
    message: []const u8,
    cause: *const CauseFailure,

    pub fn format(self: WrappedFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.message);
    }

    pub fn source(self: *const WrappedFailure) ?DynError {
        return DynError.init(self.cause);
    }
};

/// Test-only error with no explicit `source`, the shape a Rust error enum
/// variant carrying no underlying failure takes: `std::error::Error` leaves
/// `source` defaulted, and the default is `None`.
const PlainFailure = struct {
    message: []const u8,

    pub fn format(self: PlainFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.message);
    }
};

fn expectSuccess(result: Result(void, Error)) !void {
    switch (result) {
        .Ok => {},
        .Err => return error.ExpectedSuccess,
    }
}

fn expectFailure(result: Result(void, Error)) !Error {
    return switch (result) {
        .Ok => error.ExpectedFailure,
        .Err => |failure| failure,
    };
}

fn expectErrorText(expected: []const u8, failure: anytype) !void {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try failure.format(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "Error preserves its kind and borrowed explicit message" {
    const explicit = Error.new(.PermissionDenied, "read access denied");
    try std.testing.expectEqual(ErrorKind.PermissionDenied, explicit.kind());
    try expectErrorText("read access denied", explicit);

    const by_kind = Error.from_kind(.BrokenPipe);
    try std.testing.expectEqual(ErrorKind.BrokenPipe, by_kind.kind());
    try expectErrorText("broken pipe", by_kind);
}

test "Error borrows its explicit message rather than copying it" {
    // `Error` owns nothing, so a caller that keeps its own mutable buffer sees
    // the failure render whatever that buffer now says. A runtime that copied
    // the message would keep answering with the stale text.
    var message = [_]u8{0} ** "source is locked".len;
    @memcpy(&message, "source is locked");
    const failure = Error.new(.PermissionDenied, &message);
    try expectErrorText("source is locked", failure);

    message[0] = 'p';
    try expectErrorText("psurce is locked", failure);

    // The category is stored by value, so it does not move with the message.
    try std.testing.expectEqual(ErrorKind.PermissionDenied, failure.kind());
}

/// The `std::io::ErrorKind` variants the translator admits in value position
/// (`ts_ext.zig`'s `std_enum_variants`). Each reaches the generated program as
/// `r2z.io.ErrorKind.<name>`, so a name admitted there that this enum does not
/// declare is a program that cannot build against the runtime.
const emitted_error_kind_variants = [_][]const u8{
    "Other",
    "NotFound",
    "PermissionDenied",
    "ConnectionRefused",
    "ConnectionReset",
    "HostUnreachable",
    "NetworkUnreachable",
    "ConnectionAborted",
    "NotConnected",
    "AddrInUse",
    "AddrNotAvailable",
    "NetworkDown",
    "BrokenPipe",
    "AlreadyExists",
    "WouldBlock",
    "InvalidInput",
    "InvalidData",
    "TimedOut",
    "WriteZero",
    "UnexpectedEof",
    "Interrupted",
    "Unsupported",
    "OutOfMemory",
};

test "every emitted io::ErrorKind variant names a member of the runtime enum" {
    for (emitted_error_kind_variants) |name| {
        // A spelling the translator admits reaches the generated program as
        // `r2z.io.ErrorKind.<name>`, so a name with no member here is a
        // program that cannot build against this runtime.
        try std.testing.expect(std.meta.stringToEnum(ErrorKind, name) != null);
    }
}

// The categories this module produces on its own, rather than carrying
// through from a receiver: a reader or writer that ran dry, and a receiver
// that claimed more than the caller's storage held. Both are this runtime's
// own judgement and neither may be confused with a category a caller produced.
test "read_exact and write_all report their own categories, not the receiver's" {
    const steps = [_]ReadStep{.{ .transfer = 0 }};
    var reader = ScriptedReader.init("abcd", &steps);
    var destination = [_]u8{0} ** 4;
    const read_failure = try expectFailure(read_exact(&reader, &destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, read_failure.kind());

    var destination_buffer = [_]u8{0} ** 2;
    var writer = SliceWriter.init(&destination_buffer);
    const write_failure = try expectFailure(try write_all(std.testing.allocator, &writer, "abcd"));
    try std.testing.expectEqual(ErrorKind.WriteZero, write_failure.kind());

    // Both render their category's stable default, which is how a caller tells
    // them apart from a failure that carried its own message.
    try expectErrorText("failed to fill whole buffer", read_failure);
    try expectErrorText("failed to write whole buffer", write_failure);
}

test "every ErrorKind renders its own non-empty default message" {
    // A tag names a failure class, so two classes that render the same text
    // are indistinguishable to anything reading the message alone. Every
    // variant is rendered here, and each must be nonempty and unique across
    // the whole enum. The messages are collected first and compared pairwise
    // at runtime, so adding a variant cannot blow the test up quadratically at
    // compile time.
    const fields = @typeInfo(ErrorKind).@"enum".fields;
    try std.testing.expect(fields.len > 0);

    var rendered: [fields.len][64]u8 = undefined;
    var lengths: [fields.len]usize = undefined;
    for (fields, 0..) |field, index| {
        var writer: std.Io.Writer = .fixed(&rendered[index]);
        try Error.from_kind(@field(ErrorKind, field.name)).format(&writer);
        lengths[index] = writer.buffered().len;
        try std.testing.expect(lengths[index] > 0);
    }

    for (fields, 0..) |field, index| {
        for (fields[0..index], 0..) |earlier, earlier_index| {
            std.testing.expect(!std.mem.eql(
                u8,
                rendered[index][0..lengths[index]],
                rendered[earlier_index][0..lengths[earlier_index]],
            )) catch |failure| {
                std.debug.print(
                    "ErrorKind.{s} and .{s} render the same message: {s}\n",
                    .{ field.name, earlier.name, rendered[index][0..lengths[index]] },
                );
                return failure;
            };
        }
    }
}

test "read_exact completes short reads and retries interruption" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.Interrupted, "signal received") },
        .{ .transfer = 1 },
        .{ .transfer = 8 },
    };
    var reader = ScriptedReader.init("abcdef", &steps);
    var destination: [6]u8 = undefined;

    try expectSuccess(read_exact(&reader, &destination));
    try std.testing.expectEqualStrings("abcdef", &destination);
    try std.testing.expectEqual(@as(usize, 6), reader.source_position);
    try std.testing.expectEqual(@as(usize, 4), reader.calls);
}

test "read_exact reports EOF after preserving consumed bytes" {
    var reader = SliceReader.init("ab");
    var destination = [_]u8{0xaa} ** 4;

    const failure = try expectFailure(read_exact(&reader, &destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try expectErrorText("failed to fill whole buffer", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 2), reader.position);
}

test "read_exact preserves a concrete non-retry error after a short read" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.PermissionDenied, "source is locked") },
    };
    var reader = ScriptedReader.init("abcdef", &steps);
    var destination = [_]u8{0xcc} ** 6;

    const failure = try expectFailure(read_exact(&reader, &destination));
    try std.testing.expectEqual(ErrorKind.PermissionDenied, failure.kind());
    try expectErrorText("source is locked", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xcc, 0xcc, 0xcc }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 2), reader.source_position);
    try std.testing.expectEqual(@as(usize, 2), reader.calls);
}

test "write_all completes short writes and retries interruption" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.Interrupted, "signal received") },
        .{ .transfer = 1 },
        .{ .transfer = 8 },
    };
    var destination: [6]u8 = undefined;
    var writer = ScriptedWriter.init(&destination, &steps);

    try expectSuccess(try write_all(std.testing.allocator, &writer, "abcdef"));
    try std.testing.expectEqualStrings("abcdef", &destination);
    try std.testing.expectEqual(@as(usize, 6), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 4), writer.calls);
}

test "write_all reports write zero after preserving consumed bytes" {
    var destination: [2]u8 = undefined;
    var writer = SliceWriter.init(&destination);

    const failure = try expectFailure(try write_all(std.testing.allocator, &writer, "abcd"));
    try std.testing.expectEqual(ErrorKind.WriteZero, failure.kind());
    try expectErrorText("failed to write whole buffer", failure);
    try std.testing.expectEqualStrings("ab", &destination);
    try std.testing.expectEqual(@as(usize, 2), writer.position);
}

test "write_all preserves a concrete non-retry error after a short write" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.BrokenPipe, "peer closed") },
    };
    var destination = [_]u8{0xdd} ** 6;
    var writer = ScriptedWriter.init(&destination, &steps);

    const failure = try expectFailure(try write_all(std.testing.allocator, &writer, "abcdef"));
    try std.testing.expectEqual(ErrorKind.BrokenPipe, failure.kind());
    try expectErrorText("peer closed", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xdd, 0xdd, 0xdd }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 2), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 2), writer.calls);
}

test "slice adapters expose short transfer and exhaustion primitives" {
    var reader = SliceReader.init("abc");
    var read_buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), reader.read(&read_buffer).unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("ab", &read_buffer);
    try std.testing.expectEqual(@as(usize, 1), reader.read(&read_buffer).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 'c'), read_buffer[0]);
    try std.testing.expectEqual(@as(usize, 0), reader.read(&read_buffer).unwrap(std.testing.allocator));

    var destination: [2]u8 = undefined;
    var writer = SliceWriter.init(&destination);
    try std.testing.expectEqual(@as(usize, 2), writer.write("abc").unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("ab", &destination);
    try std.testing.expectEqual(@as(usize, 0), writer.write("c").unwrap(std.testing.allocator));
}

test "empty exact operations do not invoke primitives" {
    var reader = ScriptedReader.init("", &.{});
    var empty_output: [0]u8 = .{};
    var writer = ScriptedWriter.init(&empty_output, &.{});
    var empty: [0]u8 = .{};

    try expectSuccess(read_exact(&reader, &empty));
    try expectSuccess(try write_all(std.testing.allocator, &writer, ""));
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    try std.testing.expectEqual(@as(usize, 0), writer.calls);
}

test "read_exact advances a concrete slice cursor descriptor" {
    const backing: []const u8 = "abcdef";
    var cursor = backing;
    var destination: [4]u8 = undefined;

    try expectSuccess(read_exact(&cursor, &destination));
    try std.testing.expectEqualStrings("abcd", &destination);
    try std.testing.expectEqualStrings("ef", cursor);
    try std.testing.expectEqualStrings("abcdef", backing);
}

test "read_exact drains a concrete slice cursor before reporting EOF" {
    const backing: []const u8 = "ab";
    var cursor = backing;
    var destination = [_]u8{0xaa} ** 4;

    const failure = try expectFailure(read_exact(&cursor, &destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try expectErrorText("failed to fill whole buffer", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);
}

test "write_all advances a concrete mutable slice cursor descriptor" {
    var backing = [_]u8{ 0, 0, 0, 0 };
    var cursor: []u8 = &backing;

    try expectSuccess(try write_all(std.testing.allocator, &cursor, "ab"));
    try std.testing.expectEqualStrings("ab\x00\x00", &backing);
    try std.testing.expectEqualStrings("\x00\x00", cursor);
}

test "write_all reports WriteZero once a concrete slice cursor is exhausted" {
    var backing = [_]u8{0};
    var cursor: []u8 = &backing;

    try expectSuccess(try write_all(std.testing.allocator, &cursor, "\x80"));
    try std.testing.expectEqualStrings("\x80", &backing);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    const failure = try expectFailure(try write_all(std.testing.allocator, &cursor, "\x01"));
    try std.testing.expectEqual(ErrorKind.WriteZero, failure.kind());
    try expectErrorText("failed to write whole buffer", failure);
    try std.testing.expectEqualStrings("\x80", &backing);
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    try expectSuccess(try write_all(std.testing.allocator, &cursor, ""));
}

test "DynRead delegates every partial read to the original pointee" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .transfer = 1 },
    };
    var reader = ScriptedReader.init("abcdef", &steps);
    var dynamic = DynRead.init(&reader);
    var destination = [_]u8{0} ** 4;

    try std.testing.expectEqual(@as(usize, 2), dynamic.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqual(@as(usize, 1), dynamic.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 'c'), destination[0]);
    try std.testing.expectEqual(@as(usize, 2), reader.calls);
    try std.testing.expectEqual(@as(usize, 3), reader.source_position);
}

test "DynRead.read_exact completes short reads and retries interruption" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.Interrupted, "signal received") },
        .{ .transfer = 1 },
        .{ .transfer = 8 },
    };
    var reader = ScriptedReader.init("abcdef", &steps);
    var dynamic = DynRead.init(&reader);
    var destination: [6]u8 = undefined;

    try expectSuccess(dynamic.read_exact(&destination));
    try std.testing.expectEqualStrings("abcdef", &destination);
    try std.testing.expectEqual(@as(usize, 6), reader.source_position);
    try std.testing.expectEqual(@as(usize, 4), reader.calls);
}

test "DynRead.read_exact reports EOF after preserving transferred bytes" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .transfer = 0 },
    };
    var reader = ScriptedReader.init("ab", &steps);
    var dynamic = DynRead.init(&reader);
    var destination = [_]u8{0xaa} ** 4;

    const failure = try expectFailure(dynamic.read_exact(&destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try expectErrorText("failed to fill whole buffer", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 2), reader.calls);
}

test "DynRead.read_exact preserves a concrete error kind after a short read" {
    const steps = [_]ReadStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.PermissionDenied, "source is locked") },
    };
    var reader = ScriptedReader.init("abcdef", &steps);
    var dynamic = DynRead.init(&reader);
    var destination = [_]u8{0xcc} ** 6;

    const failure = try expectFailure(dynamic.read_exact(&destination));
    try std.testing.expectEqual(ErrorKind.PermissionDenied, failure.kind());
    try expectErrorText("source is locked", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqual(@as(usize, 2), reader.source_position);
    try std.testing.expectEqual(@as(usize, 2), reader.calls);
}

test "DynWrite delegates every partial write to the original pointee" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .transfer = 1 },
    };
    var destination = [_]u8{0xaa} ** 4;
    var writer = ScriptedWriter.init(&destination, &steps);
    var dynamic = DynWrite.init(&writer, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), (try dynamic.write("abcd")).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0xaa, 0xaa }, &destination);
    try std.testing.expectEqual(@as(usize, 1), (try dynamic.write("ef")).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'e', 0xaa }, &destination);
    try std.testing.expectEqual(@as(usize, 2), writer.calls);
    try std.testing.expectEqual(@as(usize, 3), writer.destination_position);
}

test "DynWrite.write_all completes short writes and retries interruption" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.Interrupted, "signal received") },
        .{ .transfer = 1 },
        .{ .transfer = 8 },
    };
    var destination: [6]u8 = undefined;
    var writer = ScriptedWriter.init(&destination, &steps);
    var dynamic = DynWrite.init(&writer, std.testing.allocator);

    try expectSuccess(try dynamic.write_all("abcdef"));
    try std.testing.expectEqualStrings("abcdef", &destination);
    try std.testing.expectEqual(@as(usize, 6), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 4), writer.calls);
}

test "DynWrite.write_all reports WriteZero after preserving transferred bytes" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .transfer = 0 },
    };
    var destination = [_]u8{0xdd} ** 4;
    var writer = ScriptedWriter.init(&destination, &steps);
    var dynamic = DynWrite.init(&writer, std.testing.allocator);

    const failure = try expectFailure(try dynamic.write_all("abcd"));
    try std.testing.expectEqual(ErrorKind.WriteZero, failure.kind());
    try expectErrorText("failed to write whole buffer", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xdd }, destination[2..]);
    try std.testing.expectEqual(@as(usize, 2), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 2), writer.calls);
}

test "DynWrite.write_all preserves a concrete error kind after a short write" {
    const steps = [_]WriteStep{
        .{ .transfer = 2 },
        .{ .failure = Error.new(.BrokenPipe, "peer closed") },
    };
    var destination = [_]u8{0xdd} ** 6;
    var writer = ScriptedWriter.init(&destination, &steps);
    var dynamic = DynWrite.init(&writer, std.testing.allocator);

    const failure = try expectFailure(try dynamic.write_all("abcdef"));
    try std.testing.expectEqual(ErrorKind.BrokenPipe, failure.kind());
    try expectErrorText("peer closed", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqual(@as(usize, 2), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 2), writer.calls);
}

test "DynWrite.write_all drains a native mutable slice descriptor" {
    // `let mut writable = &mut buf[..]` passed as `&mut dyn io::Write` is the
    // receiver shape leb128's own tests write through: the descriptor advances
    // as bytes land in the caller's own storage, and an exhausted descriptor
    // ends the write in `WriteZero`. A failing allocator proves the handle
    // never reaches it on this path.
    var backing = [_]u8{ 0xaa, 0xaa };
    var writable: []u8 = &backing;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var dynamic = DynWrite.init(&writable, failing.allocator());

    try expectSuccess(try dynamic.write_all("\x80\x01"));
    try std.testing.expectEqualStrings("\x80\x01", &backing);
    try std.testing.expectEqualStrings("", writable);

    const failure = try expectFailure(try dynamic.write_all("\x02"));
    try std.testing.expectEqual(ErrorKind.WriteZero, failure.kind());
    try expectErrorText("failed to write whole buffer", failure);
    try std.testing.expectEqualStrings("\x80\x01", &backing);
    try std.testing.expectEqualStrings("", writable);

    try expectSuccess(try dynamic.write_all(""));
}

test "DynError.source hands back the borrowed cause and ends the chain" {
    var rendered: usize = 0;
    var cause: CauseFailure = .{
        .message = "underlying io failure",
        .rendered = &rendered,
    };
    var wrapped: WrappedFailure = .{
        .message = "number could not be read",
        .cause = &cause,
    };
    var dynamic = DynError.init(&wrapped);

    try expectErrorText("number could not be read", dynamic);
    try std.testing.expectEqual(@as(usize, 0), rendered);

    const borrowed = dynamic.source() orelse return error.ExpectedSource;
    try expectErrorText("underlying io failure", borrowed);
    try std.testing.expectEqual(@as(usize, 1), rendered);

    try std.testing.expect(borrowed.source() == null);
    try expectErrorText("underlying io failure", borrowed);
    try std.testing.expectEqual(@as(usize, 2), rendered);
}

test "DynError admits a concrete error that declares no source" {
    var failure: PlainFailure = .{
        .message = "the number is larger than can be represented",
    };
    var dynamic = DynError.init(&failure);

    try expectErrorText("the number is larger than can be represented", dynamic);
    try std.testing.expect(dynamic.source() == null);
}

test "DynError formats a borrowed std::io::Error and reports no source" {
    var failure = Error.new(.PermissionDenied, "read access denied");
    var dynamic = DynError.init(&failure);

    try expectErrorText("read access denied", dynamic);
    try std.testing.expect(dynamic.source() == null);
}

test "Error and DynError render through Zig's own {f} specifier" {
    var rendered: usize = 0;
    var cause: CauseFailure = .{
        .message = "underlying io failure",
        .rendered = &rendered,
    };
    var wrapped: WrappedFailure = .{
        .message = "number could not be read",
        .cause = &cause,
    };
    var failure = Error.new(.PermissionDenied, "read access denied");

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f} {f} {f} {f}", .{
        failure,
        Error.from_kind(.BrokenPipe),
        DynError.init(&failure),
        DynError.init(&wrapped),
    });
    try std.testing.expectEqualStrings(
        "read access denied broken pipe read access denied number could not be read",
        writer.buffered(),
    );
    try std.testing.expectEqual(@as(usize, 0), rendered);

    // The chain is walked through the handle, so the cause renders only when
    // `source` reaches it.
    const borrowed = DynError.init(&wrapped).source() orelse return error.ExpectedSource;
    var cause_buffer: [64]u8 = undefined;
    var cause_writer: std.Io.Writer = .fixed(&cause_buffer);
    try cause_writer.print("{f}", .{borrowed});
    try std.testing.expectEqualStrings("underlying io failure", cause_writer.buffered());
    try std.testing.expectEqual(@as(usize, 1), rendered);
}

test "a short buffer fails through the Error and DynError hooks" {
    var failure = Error.new(.StorageFull, "the volume is out of space");
    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, writer.print("{f}", .{failure}));
    try std.testing.expectEqualStrings("the ", writer.buffered());

    var handle_buffer: [4]u8 = undefined;
    var handle_writer: std.Io.Writer = .fixed(&handle_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        handle_writer.print("{f}", .{DynError.init(&failure)}),
    );
    try std.testing.expectEqualStrings("the ", handle_writer.buffered());
}

test "Cursor over an owned byte array advances its read position" {
    var cursor = Cursor([1]u8).init(.{0});
    var destination = [_]u8{0xee} ** 2;

    try std.testing.expectEqual(@as(usize, 1), cursor.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 0), destination[0]);
    try std.testing.expectEqual(@as(u8, 0xee), destination[1]);
    try std.testing.expectEqual(@as(u64, 1), cursor.position);
    try std.testing.expectEqual(@as(usize, 0), cursor.read(&destination).unwrap(std.testing.allocator));
}

test "Cursor over a borrowed slice leaves the borrow untouched" {
    const backing: []const u8 = "abcdef";
    var cursor = Cursor([]const u8).init(backing);
    var destination: [4]u8 = undefined;

    try expectSuccess(read_exact(&cursor, &destination));
    try std.testing.expectEqualStrings("abcd", &destination);
    try std.testing.expectEqualStrings("abcdef", backing);
    try std.testing.expectEqual(@as(u64, 4), cursor.position);
}

test "Cursor over a borrowed slice drains before reporting EOF" {
    const backing: []const u8 = "ab";
    var cursor = Cursor([]const u8).init(backing);
    var destination = [_]u8{0xaa} ** 4;

    const failure = try expectFailure(read_exact(&cursor, &destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try expectErrorText("failed to fill whole buffer", failure);
    try std.testing.expectEqualStrings("ab", destination[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, destination[2..]);
    try std.testing.expectEqual(@as(u64, 2), cursor.position);
}

/// A source with a known byte at every offset, so the contents a refill
/// hands back can be checked against the offset that refill started at.
fn indexedSource(comptime length: usize) [length]u8 {
    var source: [length]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index);
    return source;
}

fn expectFillFailure(result: Result([]const u8, Error)) !Error {
    return switch (result) {
        .Ok => error.ExpectedFailure,
        .Err => |failure| failure,
    };
}

test "fill_buf borrows a slice descriptor's whole remainder and consume advances it" {
    var readable: []const u8 = "abcdef";

    try std.testing.expectEqualStrings("abcdef", fill_buf(&readable).unwrap(std.testing.allocator));
    consume(&readable, 2);
    try std.testing.expectEqualStrings("cdef", fill_buf(&readable).unwrap(std.testing.allocator));
    consume(&readable, 4);
    try std.testing.expectEqualStrings("", fill_buf(&readable).unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("", readable);
}

test "SliceReader fill_buf borrows the unread window and consume advances it" {
    var reader = SliceReader.init("abcdef");

    try std.testing.expectEqualStrings("abcdef", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), reader.position);
    consume(&reader, 3);
    try std.testing.expectEqualStrings("def", fill_buf(&reader).unwrap(std.testing.allocator));
    consume(&reader, 3);
    try std.testing.expectEqualStrings("", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 6), reader.position);
}

test "Cursor fill_buf borrows without advancing and consume moves the position" {
    const backing: []const u8 = "abcdef";
    var cursor = Cursor([]const u8).init(backing);

    try std.testing.expectEqualStrings("abcdef", fill_buf(&cursor).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u64, 0), cursor.position);
    consume(&cursor, 2);
    try std.testing.expectEqual(@as(u64, 2), cursor.position);
    try std.testing.expectEqualStrings("cdef", fill_buf(&cursor).unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("abcdef", backing);
}

test "fill_buf hands back a view of each reader's own storage, never a copy" {
    // The window is a BORROW: the runtime hands the caller a slice into
    // storage the receiver already holds, and never a fresh allocation the
    // caller would then own. Each receiver below is pinned by address, so a
    // runtime that copied the window out would fail this.
    var readable: []const u8 = "abcdef";
    const descriptor_window = fill_buf(&readable).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(readable.ptr), @intFromPtr(descriptor_window.ptr));
    // The borrow names the caller's own descriptor, so consuming it moves the
    // descriptor and the next borrow starts inside the bytes it already lent.
    consume(&readable, 2);
    const descriptor_rest = fill_buf(&readable).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(descriptor_window.ptr + 2), @intFromPtr(descriptor_rest.ptr));

    var slice_reader = SliceReader.init("abcdef");
    const slice_window = fill_buf(&slice_reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(slice_reader.input.ptr), @intFromPtr(slice_window.ptr));
    consume(&slice_reader, 2);
    const slice_rest = fill_buf(&slice_reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(slice_reader.input.ptr + 2), @intFromPtr(slice_rest.ptr));

    const backing: []const u8 = "abcdef";
    var cursor = Cursor([]const u8).init(backing);
    const cursor_window = fill_buf(&cursor).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(backing.ptr), @intFromPtr(cursor_window.ptr));
    consume(&cursor, 2);
    const cursor_rest = fill_buf(&cursor).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(backing.ptr + 2), @intFromPtr(cursor_rest.ptr));
    try std.testing.expectEqualStrings("cdef", cursor_rest);

    // A cursor over an owned array lends the array it holds, not a copy of it.
    var owned = Cursor([6]u8).init(.{ 'a', 'b', 'c', 'd', 'e', 'f' });
    const owned_window = fill_buf(&owned).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(&owned.inner[0]), @intFromPtr(owned_window.ptr));
    consume(&owned, 2);
    const owned_rest = fill_buf(&owned).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(&owned.inner[2]), @intFromPtr(owned_rest.ptr));
    try std.testing.expectEqualStrings("cdef", owned_rest);
}

test "an abandoned fill_buf window is still buffered and is served again unchanged" {
    // The early-exit question: adler's loop takes `buf.len()`, hashes it, and
    // calls `consume` — but a loop that exits between `fill_buf` and `consume`
    // abandons the window. Nothing is released (it was never owned) and
    // nothing is lost (it is still the reader's), so the next borrow returns
    // the same bytes from the same address without reaching the inner reader.
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = 0 },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    const abandoned = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8_192), abandoned.len);
    try std.testing.expectEqual(@as(usize, 1), inner.calls);

    // The borrow was dropped without `consume`, so nothing moved.
    const again = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(abandoned.ptr), @intFromPtr(again.ptr));
    try std.testing.expectEqualSlices(u8, abandoned, again);
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
    try std.testing.expectEqual(@as(usize, 0), reader.pos);

    // And the drain still completes over every byte of the source.
    var drained: usize = again.len;
    consume(&reader, again.len);
    while (true) {
        const window = fill_buf(&reader).unwrap(std.testing.allocator);
        if (window.len == 0) break;
        try std.testing.expectEqualSlices(u8, source[drained..][0..window.len], window);
        drained += window.len;
        consume(&reader, window.len);
    }
    try std.testing.expectEqual(@as(usize, 20_000), drained);
}

test "a borrowed window names the reader's own bytes, so a refill overwrites it" {
    // The other half of the ownership question. Because the caller borrows the
    // reader's storage rather than owning a copy, the bytes a window names are
    // the reader's: a later refill into that same storage changes what an
    // already-handed-out slice reads as. That is the invalidation the
    // `fill_buf` contract documents, observed rather than assumed.
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    const first = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, source[0..first.len], first);

    consume(&reader, first.len);
    const second = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
    try std.testing.expectEqualSlices(u8, source[8_192..][0..second.len], second);

    // The first window pointed at the reader's window all along, so it now
    // reads the refilled bytes.
    try std.testing.expectEqualSlices(u8, source[8_192..][0..first.len], first);
}

test "consume stops at the buffered window instead of skipping past it" {
    // Rust's `BufRead::consume` for `BufReader` is `cmp::min(pos + amt,
    // filled)`. A count past the window therefore consumes the window and no
    // more, which is what keeps a miscounted caller from silently dropping the
    // bytes of the NEXT refill.
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    try std.testing.expectEqual(@as(usize, 8_192), fill_buf(&reader).unwrap(std.testing.allocator).len);
    consume(&reader, 30_000);
    try std.testing.expectEqual(@as(usize, 8_192), reader.pos);
    try std.testing.expectEqual(@as(usize, 8_192), reader.filled);

    // The next refill starts where the last window ended, not past the input
    // the over-count named.
    const window = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, source[8_192..][0..window.len], window);
}

test "BufReader consume stops at the window and SliceReader consume refuses to pass it" {
    // The two clamped-and-panicking receivers differ deliberately: `BufReader`
    // clamps, `SliceReader` panics the way `&self[amt..]` does. A caller that
    // relied on the runtime to silently truncate a `SliceReader` would get a
    // panic here instead, so both behaviours are pinned.
    var reader = BufReader([]const u8).init("abcdef");
    try std.testing.expectEqualStrings("abcdef", fill_buf(&reader).unwrap(std.testing.allocator));
    consume(&reader, 4);
    consume(&reader, 30_000);
    try std.testing.expectEqual(@as(usize, 6), reader.pos);
    try std.testing.expectEqual(@as(usize, 6), reader.filled);
    try std.testing.expectEqualStrings("", fill_buf(&reader).unwrap(std.testing.allocator));

    var slice_reader = SliceReader.init("abcdef");
    consume(&slice_reader, 4);
    try std.testing.expectEqual(@as(usize, 4), slice_reader.position);
    try std.testing.expectEqualStrings("ef", fill_buf(&slice_reader).unwrap(std.testing.allocator));
}

test "Cursor past the end of its input reads as EOF and keeps its position" {
    var cursor = Cursor([]const u8).init("ab");
    consume(&cursor, 30_000);

    try std.testing.expectEqual(@as(u64, 30_000), cursor.position);
    try std.testing.expectEqualStrings("", fill_buf(&cursor).unwrap(std.testing.allocator));
    var destination = [_]u8{0xaa} ** 4;
    try std.testing.expectEqual(@as(usize, 0), cursor.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u64, 30_000), cursor.position);

    const failure = try expectFailure(read_exact(&cursor, &destination));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try std.testing.expectEqual(@as(u64, 30_000), cursor.position);
}

test "BufReader refills the default eight-kilobyte window and reports EOF after it" {
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = 0 },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    var total: usize = 0;
    const first = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8_192), first.len);
    try std.testing.expectEqualSlices(u8, source[0..8_192], first);
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
    total += first.len;
    consume(&reader, first.len);

    const second = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8_192), second.len);
    try std.testing.expectEqualSlices(u8, source[8_192..16_384], second);
    try std.testing.expectEqual(@as(usize, 2), inner.calls);
    total += second.len;
    consume(&reader, second.len);

    const last = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3_616), last.len);
    try std.testing.expectEqualSlices(u8, source[16_384..20_000], last);
    try std.testing.expectEqual(@as(usize, 3), inner.calls);
    total += last.len;
    consume(&reader, last.len);

    try std.testing.expectEqualStrings("", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 4), inner.calls);
    try std.testing.expectEqual(@as(usize, 20_000), total);
    try std.testing.expectEqual(@as(usize, 20_000), inner.source_position);
}

test "BufReader serves a small read from the cached window without reaching its inner reader" {
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{.{ .transfer = std.math.maxInt(usize) }};
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    try std.testing.expectEqual(@as(usize, 8_192), fill_buf(&reader).unwrap(std.testing.allocator).len);
    consume(&reader, 8_191);

    var destination: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), reader.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, source[8_191..8_192], destination[0..1]);
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
}

test "BufReader bypasses an empty window only for a read at least as large as it" {
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    var large: [10_000]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10_000), reader.read(&large).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, source[0..10_000], &large);
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
    try std.testing.expectEqual(@as(usize, 10_000), inner.source_position);

    var small: [8_191]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8_191), reader.read(&small).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, source[10_000..18_191], &small);
    try std.testing.expectEqual(@as(usize, 2), inner.calls);
}

test "BufReader interleaves read and fill_buf over one cached window" {
    const source = indexedSource(20_000);
    const steps = [_]ReadStep{
        .{ .transfer = std.math.maxInt(usize) },
        .{ .transfer = std.math.maxInt(usize) },
    };
    var inner = ScriptedReader.init(&source, &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    var destination: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), reader.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), inner.calls);

    // The window that read filled is still there: fill_buf borrows it without
    // another read, and consume empties exactly what the caller was lent.
    const window = fill_buf(&reader).unwrap(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8_182), window.len);
    try std.testing.expectEqual(@intFromPtr(&reader.buffer[10]), @intFromPtr(window.ptr));
    try std.testing.expectEqual(@as(usize, 1), inner.calls);
    consume(&reader, 8_182);

    try std.testing.expectEqual(@as(usize, 10), reader.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, source[8_192..8_202], &destination);
    try std.testing.expectEqual(@as(usize, 2), inner.calls);
}

test "BufReader returns a concrete refill failure without dropping buffered bytes" {
    const steps = [_]ReadStep{
        .{ .transfer = 4 },
        .{ .failure = Error.new(.PermissionDenied, "source is locked") },
        .{ .transfer = 2 },
        .{ .transfer = 0 },
    };
    var inner = ScriptedReader.init("abcdef", &steps);
    var reader = BufReader(*ScriptedReader).init(&inner);

    try std.testing.expectEqualStrings("abcd", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), inner.calls);

    // A refill that is not needed never reaches the inner reader, so the
    // bytes already buffered outlive the failure that follows them.
    consume(&reader, 2);
    try std.testing.expectEqualStrings("cd", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), inner.calls);

    consume(&reader, 2);
    const failure = try expectFillFailure(fill_buf(&reader));
    try std.testing.expectEqual(ErrorKind.PermissionDenied, failure.kind());
    try expectErrorText("source is locked", failure);
    try std.testing.expectEqual(@as(usize, 2), inner.calls);
    try std.testing.expectEqual(@as(usize, 4), inner.source_position);
    try std.testing.expectEqual(@as(usize, 0), reader.pos);
    try std.testing.expectEqual(@as(usize, 0), reader.filled);

    // A failed refill leaves an empty window, not a wedged reader: the next
    // fill reaches the inner reader again and serves what comes after it.
    try std.testing.expectEqualStrings("ef", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 3), inner.calls);
    try std.testing.expectEqual(@as(usize, 6), inner.source_position);
    consume(&reader, 2);
    try std.testing.expectEqualStrings("", fill_buf(&reader).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 4), inner.calls);
}

test "BufReader advances a borrowed inner reader and leaves a copied one alone" {
    var borrowed = SliceReader.init("abcdef");
    var reader = BufReader(*SliceReader).init(&borrowed);

    try std.testing.expectEqualStrings("abcdef", fill_buf(&reader).unwrap(std.testing.allocator));
    consume(&reader, 2);
    var destination: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), reader.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqualStrings("cd", &destination);
    // The refill drained the caller's own reader, and the buffered reader's
    // later `consume` never reached it again.
    try std.testing.expectEqual(@as(usize, 6), borrowed.position);

    // A reader held by value is this reader's own: draining it leaves the
    // caller's original at its own position.
    const copied = SliceReader.init("abcdef");
    var owner = BufReader(SliceReader).init(copied);
    var owned_destination: [6]u8 = undefined;
    try expectSuccess(read_exact(&owner, &owned_destination));
    try std.testing.expectEqualStrings("abcdef", &owned_destination);
    try std.testing.expectEqualStrings("", fill_buf(&owner).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), copied.position);
}

test "a BufReader over a borrowed slice refills and drains window by window" {
    // The shape adler's own `bufread` test uses: `BufReader::new(data)` over a
    // borrowed slice, drained window by window until the source runs out.
    const source = indexedSource(20_000);
    const readable: []const u8 = &source;
    var reader = BufReader([]const u8).init(readable);
    var drained: usize = 0;
    while (true) {
        const window = fill_buf(&reader).unwrap(std.testing.allocator);
        if (window.len == 0) break;
        try std.testing.expect(window.len <= 8_192);
        try std.testing.expectEqualSlices(u8, source[drained..][0..window.len], window);
        drained += window.len;
        consume(&reader, window.len);
    }
    try std.testing.expectEqual(@as(usize, 20_000), drained);
    // `BufReader::new` takes its source by value and `&[u8]` is `Copy`, so the
    // caller's own descriptor is untouched while the buffered reader's copy is
    // the one that drained.
    try std.testing.expectEqualStrings(&source, readable);
}

test "DynRead reads through a cursor over an owned byte array" {
    var cursor = Cursor([1]u8).init(.{0});
    var dynamic = DynRead.init(&cursor);
    var destination = [_]u8{0xee};

    try expectSuccess(dynamic.read_exact(&destination));
    try std.testing.expectEqual(@as(u8, 0), destination[0]);
    try std.testing.expectEqual(@as(u64, 1), cursor.position);
}

test "DynRead.read_exact drains a native immutable slice descriptor" {
    // `let mut readable = &buf[..]` passed as `&mut dyn io::Read` is the
    // receiver shape leb128's own tests read through: the descriptor advances
    // one byte per `read_exact`, and the read ends in `UnexpectedEof` once
    // the descriptor is empty, which is how a truncated continuation byte
    // surfaces.
    const backing: []const u8 = "\x80\x01";
    var readable = backing;
    var dynamic = DynRead.init(&readable);

    var byte: [1]u8 = undefined;
    try expectSuccess(dynamic.read_exact(&byte));
    try std.testing.expectEqual(@as(u8, 0x80), byte[0]);
    try std.testing.expectEqualStrings("\x01", readable);

    try expectSuccess(dynamic.read_exact(&byte));
    try std.testing.expectEqual(@as(u8, 0x01), byte[0]);
    try std.testing.expectEqualStrings("", readable);

    const failure = try expectFailure(dynamic.read_exact(&byte));
    try std.testing.expectEqual(ErrorKind.UnexpectedEof, failure.kind());
    try expectErrorText("failed to fill whole buffer", failure);
    try std.testing.expectEqualStrings("", readable);
    try std.testing.expectEqualStrings("\x80\x01", backing);
}

test "write_all appends to a caller vector and preserves earlier bytes" {
    const gpa = std.testing.allocator;
    var vector: std.ArrayList(u8) = .empty;
    defer vector.deinit(gpa);

    try vector.appendSlice(gpa, "keep");
    try expectSuccess(try write_all(gpa, &vector, " \x80\x01"));
    try std.testing.expectEqualStrings("keep \x80\x01", vector.items);
}

test "write_all surfaces a caller vector allocation failure as error.OutOfMemory" {
    const gpa = std.testing.allocator;
    var vector: std.ArrayList(u8) = .empty;
    defer vector.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        write_all(failing.allocator(), &vector, "ab"),
    );
    try std.testing.expectEqual(@as(usize, 0), vector.items.len);
}

test "write_all performs no allocation when the writer is a fixed slice" {
    var destination: [4]u8 = undefined;
    var writer = SliceWriter.init(&destination);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try expectSuccess(try write_all(failing.allocator(), &writer, "abcd"));
    try std.testing.expectEqualStrings("abcd", &destination);
}

test "DynWrite appends through a caller vector and preserves earlier bytes" {
    const gpa = std.testing.allocator;
    var vector: std.ArrayList(u8) = .empty;
    defer vector.deinit(gpa);

    try vector.appendSlice(gpa, "keep");
    var dynamic = DynWrite.init(&vector, gpa);

    try expectSuccess(try dynamic.write_all(" \x80"));
    try expectSuccess(try dynamic.write_all("\x01"));
    try std.testing.expectEqualStrings("keep \x80\x01", vector.items);
}

test "DynWrite surfaces a caller vector allocation failure as error.OutOfMemory" {
    const gpa = std.testing.allocator;
    var vector: std.ArrayList(u8) = .empty;
    defer vector.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var dynamic = DynWrite.init(&vector, failing.allocator());
    try std.testing.expectError(error.OutOfMemory, dynamic.write_all("ab"));
    try std.testing.expectEqual(@as(usize, 0), vector.items.len);
}

test "DynWrite performs no allocation when the writer is a fixed slice" {
    var destination: [4]u8 = undefined;
    var writer = SliceWriter.init(&destination);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    var dynamic = DynWrite.init(&writer, failing.allocator());
    try expectSuccess(try dynamic.write_all("abcd"));
    try std.testing.expectEqualStrings("abcd", &destination);
}
