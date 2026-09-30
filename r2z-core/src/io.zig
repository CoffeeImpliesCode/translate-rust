//! Allocation-free Rust `std::io` compatibility primitives.

const std = @import("std");
const Result = @import("result.zig").Result;

/// This module's own container, so a method that shares its name with a
/// module function (`DynRead.read_exact`, `DynWrite.write_all`) still reaches
/// the module function instead of itself.
const io = @This();

/// Rust's non-exhaustive categories for I/O failures.
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

/// A borrowed I/O error with a Rust-compatible category and message.
pub const Error = struct {
    error_kind: ErrorKind,
    explicit_message: ?[]const u8 = null,

    /// Construct an error without copying the caller-borrowed message.
    pub fn new(error_kind: ErrorKind, message: []const u8) @This() {
        return .{
            .error_kind = error_kind,
            .explicit_message = message,
        };
    }

    /// Construct an error using the stable message for its category.
    pub fn from_kind(error_kind: ErrorKind) @This() {
        return .{ .error_kind = error_kind };
    }

    /// Return the preserved Rust error category.
    pub fn kind(self: @This()) ErrorKind {
        return self.error_kind;
    }

    /// Write the explicit message, or the category's stable default.
    pub fn fmt(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
/// A caller-owned byte-slice descriptor is advanced as it is copied, and it
/// is advanced before the short read becomes `UnexpectedEof`, so the
/// descriptor is drained on the failure path too.
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

/// Write until `bytes` is consumed, retrying only interrupted operations.
///
/// Only a caller-owned byte vector grows, and it grows through the allocator
/// threaded in here; every other receiver writes into storage the caller
/// already owns, so a successful run allocates nothing. A vector that cannot
/// grow is a genuine allocation failure and surfaces as `error.OutOfMemory`,
/// never as a fabricated I/O category.
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
pub const SliceReader = struct {
    input: []const u8,
    position: usize = 0,

    /// Borrow `input` without allocating or copying it.
    pub fn init(input: []const u8) @This() {
        return .{ .input = input };
    }

    /// Consume at most `bytes.len` bytes and return the count consumed.
    pub fn read(self: *@This(), bytes: []u8) Result(usize, Error) {
        std.debug.assert(self.position <= self.input.len);
        const available = self.input.len - self.position;
        const count = @min(bytes.len, available);
        @memcpy(bytes[0..count], self.input[self.position..][0..count]);
        self.position += count;
        return .{ .Ok = count };
    }
};

/// A borrowed, cursor-based writer over a mutable byte slice.
pub const SliceWriter = struct {
    output: []u8,
    position: usize = 0,

    /// Borrow `output` without allocating or copying it.
    pub fn init(output: []u8) @This() {
        return .{ .output = output };
    }

    /// Consume at most the remaining output capacity and return the count written.
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
pub fn Cursor(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: T,
        position: usize = 0,

        /// Take ownership of, or borrow, the cursor's source.
        pub fn init(inner: T) Self {
            return .{ .inner = inner };
        }

        /// Consume at most the unread bytes left in the cursor's source.
        pub fn read(self: *Self, bytes: []u8) Result(usize, Error) {
            const source = self.asBytes();
            std.debug.assert(self.position <= source.len);
            const count = @min(bytes.len, source.len - self.position);
            @memcpy(bytes[0..count], source[self.position..][0..count]);
            self.position += count;
            return .{ .Ok = count };
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

/// A borrowed handle to a concrete `std::io::Read` implementor, the fat
/// pointer Rust's `&mut dyn Read` lowers to. The handle owns nothing and every
/// call reaches the caller's own reader through the erased pointer, so read
/// position and error state live exactly where the caller left them.
pub const DynRead = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, bytes: []u8) Result(usize, Error),
    };

    /// Bind a handle to `reader`, which must publish `read` or be a
    /// caller-owned byte-slice descriptor.
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
    pub inline fn read(self: DynRead, bytes: []u8) Result(usize, Error) {
        return self.vtable.read(self.ptr, bytes);
    }

    /// Fill `bytes` from the caller's reader, retrying only interruption.
    pub fn read_exact(self: DynRead, bytes: []u8) Result(void, Error) {
        return io.read_exact(self, bytes);
    }
};

/// A borrowed handle to a concrete `std::io::Write` implementor, the fat
/// pointer Rust's `&mut dyn Write` lowers to. The handle owns nothing; the
/// allocator is borrowed too and reaches the writer only when appending to a
/// caller-owned vector.
pub const DynWrite = struct {
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            bytes: []const u8,
        ) std.mem.Allocator.Error!Result(usize, Error),
    };

    /// Bind a handle to `writer`, which must publish `write` or be a
    /// caller-owned byte vector or byte-slice descriptor, and to the allocator
    /// its writes may need.
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
    pub inline fn write(
        self: DynWrite,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Result(usize, Error) {
        return self.vtable.write(self.ptr, self.allocator, bytes);
    }

    /// Write `bytes` in full through the caller's writer, retrying only
    /// interruption.
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
pub const DynError = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fmt: *const fn (
            context: *const anyopaque,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void,
        source: *const fn (context: *const anyopaque) ?DynError,
    };

    /// Bind a handle to `failure`, which must publish `fmt`. A type with no
    /// explicit `source` keeps `std::error::Error`'s default, which is none.
    pub fn init(failure: anytype) DynError {
        const Concrete = std.meta.Child(@TypeOf(failure));
        if (!@hasDecl(Concrete, "fmt")) {
            @compileError("io.DynError needs a concrete type with a fmt method");
        }
        return .{
            .ptr = failure,
            .vtable = &.{
                .fmt = struct {
                    fn call(
                        context: *const anyopaque,
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        const self: *const Concrete = @ptrCast(@alignCast(context));
                        return self.fmt(writer);
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
    pub inline fn source(self: DynError) ?DynError {
        return self.vtable.source(self.ptr);
    }

    /// Render this error through its own `fmt`.
    pub inline fn fmt(
        self: DynError,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return self.vtable.fmt(self.ptr, writer);
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

    pub fn fmt(self: CauseFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        self.rendered.* += 1;
        try writer.writeAll(self.message);
    }
};

/// Test-only error that borrows a cause the way a Rust error enum variant
/// wrapping another failure does: `source` hands back a handle onto the stored
/// cause, and `fmt` renders this level's own message.
const WrappedFailure = struct {
    message: []const u8,
    cause: *const CauseFailure,

    pub fn fmt(self: WrappedFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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

    pub fn fmt(self: PlainFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
    try failure.fmt(&writer);
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

test "Cursor over an owned byte array advances its read position" {
    var cursor = Cursor([1]u8).init(.{0});
    var destination = [_]u8{0xee} ** 2;

    try std.testing.expectEqual(@as(usize, 1), cursor.read(&destination).unwrap(std.testing.allocator));
    try std.testing.expectEqual(@as(u8, 0), destination[0]);
    try std.testing.expectEqual(@as(u8, 0xee), destination[1]);
    try std.testing.expectEqual(@as(usize, 1), cursor.position);
    try std.testing.expectEqual(@as(usize, 0), cursor.read(&destination).unwrap(std.testing.allocator));
}

test "Cursor over a borrowed slice leaves the borrow untouched" {
    const backing: []const u8 = "abcdef";
    var cursor = Cursor([]const u8).init(backing);
    var destination: [4]u8 = undefined;

    try expectSuccess(read_exact(&cursor, &destination));
    try std.testing.expectEqualStrings("abcd", &destination);
    try std.testing.expectEqualStrings("abcdef", backing);
    try std.testing.expectEqual(@as(usize, 4), cursor.position);
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
    try std.testing.expectEqual(@as(usize, 2), cursor.position);
}

test "DynRead reads through a cursor over an owned byte array" {
    var cursor = Cursor([1]u8).init(.{0});
    var dynamic = DynRead.init(&cursor);
    var destination = [_]u8{0xee};

    try expectSuccess(dynamic.read_exact(&destination));
    try std.testing.expectEqual(@as(u8, 0), destination[0]);
    try std.testing.expectEqual(@as(usize, 1), cursor.position);
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
