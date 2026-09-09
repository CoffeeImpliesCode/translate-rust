//! Allocation-free Rust `std::io` compatibility primitives.

const std = @import("std");
const Result = @import("result.zig").Result;

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

/// Read until `bytes` is full, retrying only interrupted operations.
pub fn read_exact(reader: anytype, bytes: []u8) Result(void, Error) {
    var filled: usize = 0;
    while (filled < bytes.len) {
        const result = reader.read(bytes[filled..]);
        switch (result) {
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

/// Write until `bytes` is consumed, retrying only interrupted operations.
pub fn write_all(writer: anytype, bytes: []const u8) Result(void, Error) {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = writer.write(bytes[written..]);
        switch (result) {
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

fn expectErrorText(expected: []const u8, failure: Error) !void {
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

    try expectSuccess(write_all(&writer, "abcdef"));
    try std.testing.expectEqualStrings("abcdef", &destination);
    try std.testing.expectEqual(@as(usize, 6), writer.destination_position);
    try std.testing.expectEqual(@as(usize, 4), writer.calls);
}

test "write_all reports write zero after preserving consumed bytes" {
    var destination: [2]u8 = undefined;
    var writer = SliceWriter.init(&destination);

    const failure = try expectFailure(write_all(&writer, "abcd"));
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

    const failure = try expectFailure(write_all(&writer, "abcdef"));
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
    try std.testing.expectEqual(@as(usize, 2), reader.read(&read_buffer).unwrap());
    try std.testing.expectEqualStrings("ab", &read_buffer);
    try std.testing.expectEqual(@as(usize, 1), reader.read(&read_buffer).unwrap());
    try std.testing.expectEqual(@as(u8, 'c'), read_buffer[0]);
    try std.testing.expectEqual(@as(usize, 0), reader.read(&read_buffer).unwrap());

    var destination: [2]u8 = undefined;
    var writer = SliceWriter.init(&destination);
    try std.testing.expectEqual(@as(usize, 2), writer.write("abc").unwrap());
    try std.testing.expectEqualStrings("ab", &destination);
    try std.testing.expectEqual(@as(usize, 0), writer.write("c").unwrap());
}

test "empty exact operations do not invoke primitives" {
    var reader = ScriptedReader.init("", &.{});
    var empty_output: [0]u8 = .{};
    var writer = ScriptedWriter.init(&empty_output, &.{});
    var empty: [0]u8 = .{};

    try expectSuccess(read_exact(&reader, &empty));
    try expectSuccess(write_all(&writer, ""));
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    try std.testing.expectEqual(@as(usize, 0), writer.calls);
}
