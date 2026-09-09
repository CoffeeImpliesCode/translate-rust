//! translate_rust.driver — the high-level end-to-end translation pipeline.
//!
//! Exposes `pipeline.translate` and `translateWithOptions` (Rust source ->
//! staged package promotion), `translateWireJson` (wire JSON -> staged package
//! promotion), and `fixFingerprint` (self-healing build.zig.zon).
const std = @import("std");

/// End-to-end translation pipeline (Rust source / wire JSON -> Zig package).
pub const pipeline = @import("pipeline.zig");

/// Translate a Rust crate directory into a standalone Zig package at `out_dir`.
pub const translate = pipeline.translate;

/// Translate a Rust crate directory with explicit frontend analysis options.
pub const translateWithOptions = pipeline.translateWithOptions;

/// Translate canonical v6 wire JSON into a standalone Zig package.
/// Every other wire version is rejected before IR construction or package creation.
pub const translateWireJson = pipeline.translateWireJson;

/// Promote a lowered package through staging, validation, build tests, and
/// atomic publication.
pub const promotePackage = pipeline.promotePackage;
/// Injectable package promotion boundary for compile-failure and publish tests.
pub const promotePackageWithHooks = pipeline.promotePackageWithHooks;
pub const PackagePromotionHooks = pipeline.PackagePromotionHooks;
pub const PackagePromotionError = pipeline.PackagePromotionError;
pub const PackageBuildTestResult = pipeline.PackageBuildTestResult;
pub const PackageFillPromotionNonce = pipeline.PackageFillPromotionNonce;
pub const PackageRunBuildTest = pipeline.PackageRunBuildTest;
pub const PackageResolveFingerprint = pipeline.PackageResolveFingerprint;
/// Translate a wire-format JSON dump and emit canonical source files to stdout.
pub const emitWireJson = pipeline.emitWireJson;

/// Self-heal the `.fingerprint` in a generated package's `build.zig.zon`.
pub const fixFingerprint = pipeline.fixFingerprint;

/// Wire schema compatibility failures from the canonical translation boundary.
pub const WireCompatibilityError = pipeline.WireCompatibilityError;

/// Fingerprint probe result and injectable probe type for deterministic tests.
pub const FingerprintProbeResult = pipeline.FingerprintProbeResult;
pub const FingerprintProbe = pipeline.FingerprintProbe;
pub const FingerprintError = pipeline.FingerprintError;
pub const fixFingerprintWithProbe = pipeline.fixFingerprintWithProbe;

/// Read a whole file into memory with allocation (re-exported helper).
pub const readFileAlloc = pipeline.readFileAlloc;

test {
    std.testing.refAllDecls(@This());
    _ = @import("pipeline.zig");
}
