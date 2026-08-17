//! CLI skeleton for the Rust → Zig translation tool.
//! Research phase: no translation pipeline yet (see notes/research/).

const std = @import("std");
const translate_rust = @import("translate_rust");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    // argv[0] — program name.
    _ = arg_it.next();

    const arg = arg_it.next();
    if (arg == null) {
        try printUsage(io, stdout);
        return;
    }
    const arg_slice = arg.?;

    if (std.mem.eql(u8, arg_slice, "--version")) {
        try stdout.writeStreamingAll(io, "translate-rust " ++ translate_rust.version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, arg_slice, "--help") or std.mem.eql(u8, arg_slice, "-h")) {
        try printUsage(io, stdout);
        return;
    }

    try stdout.writeStreamingAll(io,
        \\translate-rust: translation pipeline not implemented yet (research phase)
        \\see notes/research/ for the exploration that will drive it
        \\
    );
}

fn printUsage(io: std.Io, stdout: std.Io.File) !void {
    try stdout.writeStreamingAll(io,
        \\translate-rust — Rust → Zig translation (research phase, no pipeline yet)
        \\
        \\usage: translate-rust <crate-path>     translate a Rust crate to Zig (not implemented)
        \\       translate-rust --version        print version
        \\       translate-rust --help           show this help
        \\
    );
}
