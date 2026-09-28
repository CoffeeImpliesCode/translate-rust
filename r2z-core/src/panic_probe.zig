//! Test-only support for observing a runtime panic.
//!
//! Zig cannot catch a panic, so a guard whose whole contract is "this input
//! panics" cannot be asserted in process. `expectPanic` therefore re-runs
//! the guard inside a child copy of the same test binary: the parent sets
//! `case_variable` to name the guard, the child runs that guard alone, and
//! the parent asserts the child aborted after printing the expected message.
//!
//! Every other test in the binary also runs inside the child, so a guard is
//! only ever executed when the child selected its case name; the remaining
//! tests stay quiet and the recursion terminates.
//!
//! The child is located through `/proc/self/exe`, so these assertions only
//! run on Linux. Elsewhere `expectPanic` reports `error.SkipZigTest`: the
//! guard is still compiled and type-checked, it is just not executed.

const std = @import("std");
const builtin = @import("builtin");

/// Environment variable naming the guard a child must execute.
pub const case_variable = "R2Z_PANIC_CASE";

/// One guarded operation, and the observable it must and must not produce.
pub const Expect = struct {
    /// Name this guard is selected by inside a child.
    case_name: []const u8,
    /// Text the child's panic must report.
    expected: []const u8,
    /// The guard to run, and the observation it makes before panicking.
    body: *const fn () void,
    /// Further text the child must report, such as an observation the guard
    /// makes before it panics.
    required: []const []const u8 = &.{},
    /// Text the child must not report, when the guard should stay silent.
    forbidden: ?[]const u8 = null,
};

fn selectedCase() ?[]const u8 {
    return std.testing.environ.getPosix(case_variable);
}

fn selfExePath(buffer: []u8) ![]const u8 {
    const length = try std.Io.Dir.readLinkAbsolute(std.testing.io, "/proc/self/exe", buffer);
    return buffer[0..length];
}

/// Run `expect.body` when this process is the child selected by its case
/// name. Otherwise spawn a child, run the body there, and assert that the
/// child aborted having reported `expected` and every entry of `required`,
/// and not `forbidden`.
pub fn expectPanic(expect: Expect) !void {
    if (selectedCase()) |selected| {
        if (std.mem.eql(u8, selected, expect.case_name)) expect.body();
        return;
    }
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable = try selfExePath(&path_buffer);

    var environ_map = try std.testing.environ.createMap(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put(case_variable, expect.case_name);

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{executable},
        .environ_map = &environ_map,
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    if (result.term == .exited and result.term.exited == 0) {
        std.debug.print("child selected case {s} returned success\n", .{expect.case_name});
        return error.TestExpectedPanic;
    }
    if (std.mem.indexOf(u8, result.stderr, expect.expected) == null) {
        std.debug.print("child selected case {s} did not report {s}\nchild stderr:\n{s}\n", .{
            expect.case_name,
            expect.expected,
            result.stderr,
        });
        return error.TestExpectedPanic;
    }
    for (expect.required) |text| {
        if (std.mem.indexOf(u8, result.stderr, text) == null) {
            std.debug.print("child selected case {s} did not report {s}\nchild stderr:\n{s}\n", .{
                expect.case_name,
                text,
                result.stderr,
            });
            return error.TestExpectedPanic;
        }
    }
    if (expect.forbidden) |forbidden| {
        if (std.mem.indexOf(u8, result.stderr, forbidden) != null) {
            std.debug.print("child selected case {s} reported the forbidden {s}\nchild stderr:\n{s}\n", .{
                expect.case_name,
                forbidden,
                result.stderr,
            });
            return error.TestUnexpectedResult;
        }
    }
}
