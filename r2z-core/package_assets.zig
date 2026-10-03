//! The r2z-core package as data: every file a promoted package vendors under
//! `r2z-core/`, embedded in the translator executable.
//!
//! A promoted package carries this runtime with it, so its bytes have to live
//! inside `translate-rust` rather than beside it. An installed translator has
//! no source checkout, and a manifest whose `.path` pointed at one stopped
//! building the moment the generated directory was copied anywhere. The build
//! registers this file as a module (`r2z_core_assets`); the generated-package
//! writer imports it and writes each `asset` into staging before the promotion
//! gate compiles the result.
//!
//! Not part of the runtime library: `r2z-core/build.zig` roots that library at
//! `src/root.zig`, and nothing in `src/` reaches this file. Not shipped inside
//! a generated package either — it belongs to the translator, and the vendored
//! `r2z-core/` directory is its own package.

const build_options = @import("build_options");

/// One vendored file: where it lands inside the generated package, and its
/// exact bytes.
pub const Asset = struct {
    /// Path relative to the generated package root. Always under
    /// `vendor_prefix`, so the writer can hand it straight to the same
    /// path-joiner the translated sources use.
    path: []const u8,
    /// The file's bytes, verbatim. `@embedFile` puts these in the translator's
    /// read-only image, so writing one out is a copy, never a parse and never
    /// a second allocation.
    contents: []const u8,
};

/// Directory the runtime is vendored into. One string serves three roles that
/// must not drift: the manifest's `.path`, the prefix of every `Asset.path`,
/// and the entry the manifest lists under `.paths`.
pub const directory = "r2z-core";

const vendor_prefix = directory ++ "/";

/// Pair a vendored path with the file it embeds. `relative_path` names both,
/// so the recorded path cannot name a file that is not the one embedded.
fn asset(comptime relative_path: []const u8) Asset {
    return .{
        .path = vendor_prefix ++ relative_path,
        .contents = @embedFile(relative_path),
    };
}

/// The complete runtime package: its build script and manifest, plus the
/// `@import` closure of `src/root.zig`. These three names are exactly what
/// `r2z-core/build.zig.zon` ships, so the vendored copy resolves as a package
/// without this list having to describe anything else.
pub const files = [_]Asset{
    asset("build.zig"),
    asset("build.zig.zon"),
    asset("src/root.zig"),
    asset("src/alloc.zig"),
    asset("src/character.zig"),
    asset("src/collections.zig"),
    asset("src/convert.zig"),
    asset("src/format.zig"),
    asset("src/format_printable.zig"),
    asset("src/io.zig"),
    asset("src/memory.zig"),
    asset("src/ops.zig"),
    asset("src/option.zig"),
    asset("src/panic_probe.zig"),
    asset("src/random.zig"),
    asset("src/result.zig"),
};

/// License attribution for the vendored runtime, when this checkout carries
/// any. `@embedFile` cannot express a file that is absent, so the text arrives
/// as a build option the build reads when it finds one, and this stays null
/// otherwise — a package with no license file to reproduce must not invent
/// one.
pub const license: ?Asset = if (build_options.r2z_core_license) |text|
    .{ .path = vendor_prefix ++ "LICENSE", .contents = text }
else
    null;
