//! Native Rust oracle for the seven promoted corpus crates.
//!
//! Every case calls an upstream API and compares the result against a value that
//! is *not* produced by that same call, so nothing here echoes itself:
//!
//! * `Kind::Vector` — `expected` is a value published by the upstream crate, the
//!   canonical C implementation of the algorithm, or the crate's own documented
//!   boundary.
//! * `Kind::Consistency` — two different upstream code paths (one-shot function
//!   vs. streaming `Hasher`, optimized buffer vs. readable reference
//!   implementation, signed vs. unsigned formatter) must agree.
//! * `Kind::Distinct` — two code paths must *not* agree (trailing-whitespace and
//!   length sensitivity, aliasing between promoted crates).
//!
//! Provenance of every expected value:
//!
//! | crate | source |
//! | --- | --- |
//! | `wyhash` | `tests/back_to_back_hash.rs` `ORIGINAL_HASHES[256]`, `tests/back_to_back_prng.rs` `ORIGINAL_PRNG`/`ORIGINAL_PRNG_SEQ`, and the crate's own doctests, `examples/*.rs` and `tests/integration.rs` |
//! | `adler` | `src/lib.rs` unit tests and doctests (`zeroes`, `ones`, `mixed`, `wiki`, `resume`, `bufread`, piecewise, derived `Hash`) |
//! | `xxhash-rust` | `tests/sanity_test_vectors.h` of Cyan4973/xxHash v0.8.2 (`XSUM_XXH32_testdata`, len 0..=64 x seeds {0, 0x9E3779B1}) with `fillTestBuffer` from `tests/sanity_test.c`; plus `tests/size.rs` |
//! | `siphasher` | `src/tests.rs` (64-entry `SipHasher13`/`SipHasher24` tables, key `k0=0x0706050403020100`, `k1=0x0f0e0d0c0b0a0908`, input bytes `0..t`) and `src/tests128.rs` |
//! | `itoa` | `tests/test.rs` and the documented MIN/MAX boundary of every primitive integer type |
//! | `seahash` | `src/reference.rs` test `shakespear`, `tests/chunking.rs` `hash1` |
//! | `atoi` | the crate's doctests, `src/lib.rs` unit tests (`max_digits`, `max_digits_negative`, `checked_parsing`, `checked_parsing_radix_16`) and its documented overflow/underflow boundaries |
//!
//! Two upstream documents disagree about one value, and the receipt keeps the
//! disagreement checked instead of silently resolved: `src/lib.rs`'s doctest
//! and `examples/hasher_trait.rs` assert `0xb0f941520b1ad95d` for
//! `WyHash::with_seed(3).write(&[0, 1, 2])`, while `README.md` asserts
//! `0xcc242106e7076a48` for the identical call, and CHANGELOG.md records that
//! 0.2.0 changed the generated hashes without updating the README. The two
//! vector cases carry which value the crate produces; the `distinct` case only
//! asserts that the crate's computed value is not the README literal.
//!
//! Receipt format (deterministic, one case per line, no host-dependent data):
//!
//! ```text
//! {"schema":"translate-rust/rust-corpus-oracle/1","config":"default-features","crate_versions":{...},"cases":[
//! {"crate":"wyhash","group":"wyhash","name":"...","kind":"vector","encoding":"u64","expected":"0x...","actual":"0x...","pass":true},
//! ...
//! ],"summary":{"total":0,"passed":0,"failed":0}}
//! ```
//!
//! `crate_versions` names the fixture versions these expected values were taken
//! from. It is an anchor, not a measurement: `tools/rust-corpus-oracle.sh`
//! re-resolves every staged fixture with `cargo pkgid` and fails the run when
//! the resolved version differs from what this receipt declares. `config` is
//! `default-features` or `xxh32`, matching this binary's compiled feature
//! closure. `encoding` fixes how `expected`/`actual` are rendered:
//!
//! | encoding | rendering |
//! | --- | --- |
//! | `u64` | `0x` + 16 lowercase hex digits |
//! | `u32` | `0x` + 8 lowercase hex digits |
//! | `u8x16` | `0x` + 32 lowercase hex digits, bytes in `as_bytes()` order (little-endian `h1` then little-endian `h2`) |
//! | `dec` | decimal text |
//! | `atoi` | `some:<value>:<used>` for `(T, usize)` trait returns; `some:<value>:<used>` or `none:<used>` for checked `(Option<T>, usize)` returns |
//! | `optdec` | `some:<value>` or `none` for the `atoi::<T>()` free function |
//! | `str` | the value's own text |
//!
//! Exit status: `0` all cases passed, `1` at least one case failed, `2` usage or
//! I/O error. A failing run still writes its receipt.

#![forbid(unsafe_code)]

use std::fmt::Write as _;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use adler::Adler32;
use atoi::{
    ascii_to_digit, atoi, FromRadix10, FromRadix10Checked, FromRadix10Signed,
    FromRadix10SignedChecked, FromRadix16, FromRadix16Checked, MaxNumDigits, Sign,
};
use itoa::Buffer;
use rand_core::{RngCore, SeedableRng};
use seahash::SeaHasher;
use siphasher::sip::{SipHasher13, SipHasher24};
use siphasher::sip128::Hasher128;
use siphasher::sip128::{SipHasher13 as Sip128Hasher13, SipHasher24 as Sip128Hasher24};
use std::hash::{Hash, Hasher};
use wyhash::{wyhash, wyrng, WyHash, WyRng};

const SCHEMA: &str = "translate-rust/rust-corpus-oracle/1";

/// Anchors the fixture versions this oracle's expected values were taken from;
/// the values themselves come from the crates' own published material, never
/// from a manifest. `tools/rust-corpus-oracle.sh` re-resolves each staged crate
/// with `cargo pkgid` and fails the run when the resolved version drifts from
/// what is declared here.
const CRATE_VERSIONS: &[(&str, &str)] = &[
    ("adler", "1.0.2"),
    ("atoi", "2.0.0"),
    ("itoa", "1.0.11"),
    ("seahash", "4.1.0"),
    ("siphasher", "1.0.1"),
    ("wyhash", "0.4.0"),
    ("xxhash-rust", "0.8.15"),
];

// ── receipt plumbing ───────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Vector,
    Consistency,
    Distinct,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Vector => "vector",
            Kind::Consistency => "consistency",
            Kind::Distinct => "distinct",
        }
    }
}

struct Case {
    krate: &'static str,
    group: &'static str,
    name: String,
    kind: Kind,
    encoding: &'static str,
    expected: String,
    actual: String,
    pass: bool,
}

struct Receipt {
    cases: Vec<Case>,
}

impl Receipt {
    fn new() -> Self {
        Self { cases: Vec::new() }
    }

    fn record(
        &mut self,
        krate: &'static str,
        group: &'static str,
        name: impl Into<String>,
        kind: Kind,
        encoding: &'static str,
        expected: String,
        actual: String,
    ) {
        let pass = match kind {
            Kind::Distinct => expected != actual,
            Kind::Vector | Kind::Consistency => expected == actual,
        };
        self.cases.push(Case {
            krate,
            group,
            name: name.into(),
            kind,
            encoding,
            expected,
            actual,
            pass,
        });
    }

    fn vector_u64(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, expected: u64, actual: u64) {
        self.record(krate, group, name, Kind::Vector, "u64", u64_hex(expected), u64_hex(actual));
    }

    fn consistency_u64(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, first: u64, second: u64) {
        self.record(krate, group, name, Kind::Consistency, "u64", u64_hex(first), u64_hex(second));
    }

    fn consistency_u32(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, first: u32, second: u32) {
        self.record(krate, group, name, Kind::Consistency, "u32", u32_hex(first), u32_hex(second));
    }

    fn distinct_u64(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, first: u64, second: u64) {
        self.record(krate, group, name, Kind::Distinct, "u64", u64_hex(first), u64_hex(second));
    }

    fn vector_u32(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, expected: u32, actual: u32) {
        self.record(krate, group, name, Kind::Vector, "u32", u32_hex(expected), u32_hex(actual));
    }

    fn vector_bytes16(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, expected: &[u8], actual: &[u8]) {
        self.record(krate, group, name, Kind::Vector, "u8x16", bytes_hex(expected), bytes_hex(actual));
    }

    fn consistency_bytes16(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, first: &[u8], second: &[u8]) {
        self.record(krate, group, name, Kind::Consistency, "u8x16", bytes_hex(first), bytes_hex(second));
    }

    fn vector_text(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, expected: &str, actual: &str) {
        self.record(krate, group, name, Kind::Vector, "str", expected.to_string(), actual.to_string());
    }

    fn vector_dec(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, expected: String, actual: String) {
        self.record(krate, group, name, Kind::Vector, "dec", expected, actual);
    }

    fn consistency_dec(&mut self, krate: &'static str, group: &'static str, name: impl Into<String>, first: String, second: String) {
        self.record(krate, group, name, Kind::Consistency, "dec", first, second);
    }


    fn passed(&self) -> usize {
        self.cases.iter().filter(|case| case.pass).count()
    }

    fn failed(&self) -> usize {
        self.cases.len() - self.passed()
    }

    fn render(&self, config: &str) -> String {
        let mut out = String::with_capacity(self.cases.len() * 160 + 512);
        out.push_str("{\"schema\":");
        json_str(&mut out, SCHEMA);
        out.push_str(",\"config\":");
        json_str(&mut out, config);
        out.push_str(",\"crate_versions\":{");
        for (index, (name, version)) in CRATE_VERSIONS.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            json_str(&mut out, name);
            out.push(':');
            json_str(&mut out, version);
        }
        out.push_str("},\"cases\":[");
        for (index, case) in self.cases.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str("\n{\"crate\":");
            json_str(&mut out, case.krate);
            out.push_str(",\"group\":");
            json_str(&mut out, case.group);
            out.push_str(",\"name\":");
            json_str(&mut out, &case.name);
            out.push_str(",\"kind\":");
            json_str(&mut out, case.kind.as_str());
            out.push_str(",\"encoding\":");
            json_str(&mut out, case.encoding);
            out.push_str(",\"expected\":");
            json_str(&mut out, &case.expected);
            out.push_str(",\"actual\":");
            json_str(&mut out, &case.actual);
            out.push_str(",\"pass\":");
            out.push_str(if case.pass { "true" } else { "false" });
            out.push('}');
        }
        out.push_str("\n],\"summary\":{\"total\":");
        out.push_str(&self.cases.len().to_string());
        out.push_str(",\"passed\":");
        out.push_str(&self.passed().to_string());
        out.push_str(",\"failed\":");
        out.push_str(&self.failed().to_string());
        out.push_str("}}\n");
        out
    }
}

fn json_str(out: &mut String, value: &str) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            plain => out.push(plain),
        }
    }
    out.push('"');
}

fn u64_hex(value: u64) -> String {
    format!("0x{value:016x}")
}

fn u32_hex(value: u32) -> String {
    format!("0x{value:08x}")
}

fn bytes_hex(bytes: &[u8]) -> String {
    let mut out = String::from("0x");
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Rendering of the `(T, usize)` returns of the unchecked `atoi` parsing traits.
/// `some` is the receipt's value marker, not an upstream `Option` wrapper.
fn atoi_plain_rendering<T: std::fmt::Display>((value, used): (T, usize)) -> String {
    format!("some:{value}:{used}")
}

/// Rendering of the `(Option<T>, usize)` returns of the checked `atoi` traits.
fn atoi_checked_rendering<T: std::fmt::Display>(pair: (Option<T>, usize)) -> String {
    match pair {
        (Some(value), used) => format!("some:{value}:{used}"),
        (None, used) => format!("none:{used}"),
    }
}

/// Rendering of the `atoi::<T>()` free function, which reports no `used` index.
fn atoi_opt_rendering<T: std::fmt::Display>(value: Option<T>) -> String {
    match value {
        Some(value) => format!("some:{value}"),
        None => String::from("none"),
    }
}

fn filled(len: usize, byte: u8) -> Vec<u8> {
    vec![byte; len]
}

// ── wyhash 0.4.0 ───────────────────────────────────────────────────────────

/// `tests/back_to_back_hash.rs`: "Results from the cannonical C implementation".
#[rustfmt::skip]
const WYHASH_ORIGINAL_HASHES: [u64; 256] = [
    0xf961f936e29c9345, 0x83fcbe65126830a3, 0xcaed38c4bfba7448, 0xb0f941520b1ad95d,
    0x22fc0d05b5655593, 0xaf963b6ca51ab9dd, 0x8ae9d75ba5a841b8, 0xfd1d46ecd66b6c3b,
    0x276e8d0315af0b78, 0x8712dbf1d543727b, 0x9b39e6894e1f146c, 0xc43124ed65b41cb5,
    0xd3ddfd4520189f1c, 0xe7a1d44fc4d6d1f, 0x4db5af6fa882b123, 0xe72bf394ca9aad73,
    0x9510769567e2b9f5, 0xe4c8addf5e52d332, 0x7bf687b31360f0d0, 0xdb8ef4223e1e1b60,
    0x43b5b515c3fb98be, 0x513ecead364b50c1, 0x51a6f8a448b6d3b5, 0xad62961a82d455ad,
    0xbcbe2c377a034906, 0x89fbf3a60852bc2d, 0xf26147c1df25be1, 0x287f458f65e918b3,
    0x5055a2d6fe3503e3, 0x872e8ec2f5234fe3, 0xf02fc2225cccac35, 0x855f219b5e0f78bf,
    0x39e624e60cf044f5, 0x954b951660265062, 0x10717cafd43c8016, 0xaac9f9536ade0cdf,
    0x85826a82847dfb60, 0x1ec660576eee25a0, 0x7e3d61e547921405, 0x48d0278d0885804,
    0xf9a12dcc5526d1ee, 0x7f535ae5fb44c366, 0x91436439a22f53ae, 0x502163656e8fa341,
    0x1b456138914ce2c8, 0x31fb06ca008488f2, 0x224190a27cfc3ea2, 0xd042cea2c304d169,
    0x82f97b9295a4669d, 0xb911cc536d51aee3, 0xf8262e139dd87df, 0x46a7bfeb53c93a37,
    0x5b0a349881c68bbe, 0x7346d8f965ce7a50, 0x6aa0ce0b81b802d3, 0xc1183d47ceb38941,
    0x3c39115f8dcb426b, 0x920e3b4c7b45a7cf, 0x9604099240820192, 0x8ef3bd1d39cdd917,
    0x820a7dc133ba218d, 0x65e4f4965178d3b3, 0xdeb525c6a117485f, 0x20f7c7d18e52a7ad,
    0x56d5ee41b0b04b2c, 0x3ac5ed752a1e2b1b, 0x32cea51b8e513aeb, 0x6c283bcf574d8f78,
    0x8d4eba6afdee9f63, 0xb09f641d6f577975, 0x8dd7f0d3709abba7, 0xad33a90846d659cf,
    0xe25fca49c58addc6, 0x2440f6a61d350ed5, 0x6b84724e57a33f16, 0xb565dc3d397d2b99,
    0x614e76954d9db55c, 0x5ba3e16e2850e8e9, 0x3d99a751ecfbb12a, 0xbcadde62cc4170e6,
    0x14b43b747a10e7b1, 0x965716de200e679f, 0xcfc034e9d99273fc, 0xe6e24212240e06c8,
    0x7a3a43aeb5d5832, 0x53a46badd5b1c2e4, 0xefc8f1ca072cb287, 0xa219af4c6017d8df,
    0xfcf81d7e062b5b4d, 0x99f7c43b6c8d15df, 0xfa9d43de6e2dcf8d, 0x49440250024465e8,
    0xc93dc0341dfe68c6, 0x7371117edfaa3cef, 0xda507c5cc7c7861f, 0x8dc7b9c7de61dfa0,
    0x3790aac1a0b4dc9e, 0x069276f1b576327, 0xdb28a344a9a89dc2, 0xd37946ceed53eaff,
    0x20b2de3702e39858, 0xec040b298f205b6b, 0xe9cccd97a8752500, 0x5a5bdffe4bc258c9,
    0xa5e6a7de6c699302, 0xaa0ccf8a499d2fff, 0x3f20fad08660f5fb, 0xd43a1e26a81ac863,
    0x1071487504fb9242, 0xc49d54d1e6eaa5b9, 0x16a16bca2b1af019, 0xe49a7a06061ef52e,
    0x50bf68c261a59d0c, 0x3f8c3765bf1319b5, 0x446d718cd877c877, 0x22498a0894312207,
    0x6b3704625c841542, 0xf54635bee4b04e29, 0x12a1bbadbf348c7, 0x31634471a17a8e1f,
    0xdb6a4520c46bcd2e, 0x147ac2e4e291524b, 0xb0c69df46e205428, 0x3ec0c0555be5b93c,
    0x7e0bfc7a00dc8338, 0xf31c5ceea850958b, 0xb35011374d62ee22, 0x1768495be7e5f9c4,
    0xec1d87cf207b5500, 0x7868b46f37dde010, 0xc564b8d538d74383, 0xebe336d3b4b30623,
    0xf08863d276be2ab7, 0xb1d9a06182c82353, 0x74a76e581a2f789c, 0xbd3bee630fabadd3,
    0xa7de866a4d63af1d, 0x454b176b32b245fa, 0x224606473973b6b, 0xb5cfaa3bc3b8dfec,
    0xd5f72aa9cdabbd8e, 0xa7a45228925ba20d, 0x959274cf8d05674a, 0x2ea87b477fa5c092,
    0x710aa3c765472c8f, 0xd0a6c151ab0da3b1, 0x323fa4b54bb6bc98, 0xd60634f023573652,
    0x3ce86bcb32af9882, 0x1d875561fb90c2b8, 0x368b85acc5d3a430, 0xfada816c75e6b3db,
    0x7772421111391ecb, 0x6750845bb9686a33, 0xe6e949cd5af342c0, 0x49a2d3cb690c2e43,
    0x8d779ab8a0a1639f, 0xde4a98c22bdaa947, 0xc9ab33025391ea81, 0xeb3a93d56aa8dd75,
    0x65e94f5e3d28f9da, 0x3f9f4ffc3db07d1a, 0x485f6aa5e1d0753, 0xb70c36d152b9c187,
    0x2ac871e33f83fe6c, 0x1da741e30aa10174, 0xbbd508ad7d490b06, 0x24deb16289cc3964,
    0xb6f1107e77327972, 0x6615db4385b8fef0, 0xd2e822bf0fa64e63, 0x53ed6306086fb744,
    0xcb6b0aa0e1ee2460, 0x3bfa4b3350270ed6, 0x59effd2041fd4d08, 0x43fcc61c02ca632e,
    0xaf7553a0965cfd0a, 0xfab7185981e27a2, 0xc3fc759bc9680c1a, 0x32483ee8f8797b42,
    0x4eb0f9ef1b525255, 0x9ce0ffb044ce6436, 0x63052fb9cbcb44df, 0x301c22b6072bd122,
    0x68b60f1bcdbe9450, 0x1e8954848ebd28f2, 0x104cd602bbe2e67, 0xfcd846dc9107c76e,
    0x57d69ef746b3de04, 0xd4837690ab53eaa8, 0x8e50ea4999bb7894, 0xccc1ea55a74693f6,
    0x92b51070fa1bc088, 0x7b86c06ecff5f597, 0x4b94fd254936b1e7, 0x58fe1fc0c0628e01,
    0x93d5f8896977d760, 0x761e6fad2db0b6f4, 0x8e993cc2e5cdfcf7, 0x36924dac5e282c71,
    0xa22cad8a04372681, 0x4e8496a9f383addf, 0x201b621b31a992ba, 0xe01cf091118895e4,
    0x26459bef7953ab3a, 0xc06fe833ea4571ee, 0x545502fdbadb8849, 0xf489ac975de5e0de,
    0xc578d69c4d5ff83e, 0x146571e5cd3a0fa7, 0x5cb7a1d4c70d6b2a, 0x5298e3f6ffe15f0d,
    0x3682776527687209, 0x11b19a59524fdbf2, 0xa9590279d60a8b1b, 0xaa3ea2c18819120a,
    0x2766ad893c1d542d, 0xe2a47768498bd688, 0x2e1f0a701e47296d, 0x4f1463b2d4d0c9fb,
    0xee608c4a03fdfa31, 0xd4d2161b72e4cb69, 0x5fc89e3bcf8e9e6f, 0x8ce8ad18a3a71064,
    0x1a6e3c456becb8b, 0xe3c8a6635be383ed, 0xf38b80a7621ddcd7, 0x908a2152f9ac845e,
    0x8dac52b763bf028b, 0xdf59b057044e9031, 0xd503a0d875c98990, 0x9ed2c1a50ead3fb1,
    0xf2fcc1704dd1128c, 0x91eb226c91da553e, 0x21e07a2d3a8d6450, 0x25bc2bf14002d336,
    0x73a524c6212ede2f, 0xc7b83f83a798fc7d, 0x33bd8f399e8b3741, 0xb2d48f0d7c33992b,
    0xa8a25b6b259c39cc, 0x4aafb95636c6ff3b, 0xf685c0c56739cbf3, 0x5f885605ada76029,
    0x6ed22d6c51b17caf, 0x6bfd04b4c808c0b5, 0xab358de568fcbc61, 0x97e42da2f992dca5,
    0xeaeee49fc4a16045, 0xa8fef7bcce13efcc, 0xd3c5ba9c0aaa0f44, 0xd240d969c3f04b28,
    0x541eebca40288dc4, 0x292768477779dc00, 0x172788219608034c, 0xd5024d6272206ba,
];

/// `tests/back_to_back_prng.rs`: one `wyrng` output per seed `0..10`.
const WYHASH_ORIGINAL_PRNG: [u64; 10] = [
    0x111cb3a78f59a58e,
    0xcdef1695e1f8ed2c,
    0xa4eed0248024f5f6,
    0x3e99a772750dcbe,
    0xfae94589c79d2703,
    0xac19123cacd229cc,
    0xb18dc4f431e3006,
    0xe21b87e1e24a18c1,
    0x591b413082f6638b,
    0x35d5241efb19a892,
];

/// `tests/back_to_back_prng.rs`: the sequence one `WyRng` produces from default.
const WYHASH_ORIGINAL_PRNG_SEQ: [u64; 10] = [
    0x111cb3a78f59a58e,
    0xceabd938ff4e856d,
    0x61fb51318f47d2a4,
    0x78bd03c491909760,
    0x7c003d7fb14820de,
    0x8769964729356b1f,
    0xe214284dc87f9829,
    0x29a283ebb1b295a2,
    0xf4e11accbc44be57,
    0x9a108fea1a03ac0a,
];

fn wyhash_cases(receipt: &mut Receipt) {
    let krate = "wyhash";
    let group = "wyhash";

    // The upstream range loop: `data[i] = i as u8` then hash the prefix, through
    // both the free function and the `core::hash::Hasher` implementation.
    let mut data = [0u8; 256];
    for index in 0..data.len() {
        data[index] = index as u8;
        let expected = WYHASH_ORIGINAL_HASHES[index];
        receipt.vector_u64(krate, group, format!("wyhash_original_len{index:03}"), expected, wyhash(&data[..index], index as u64));

        let mut hasher = WyHash::with_seed(index as u64);
        hasher.write(&data[..index]);
        receipt.vector_u64(krate, group, format!("wyhash_hasher_len{index:03}"), expected, hasher.finish());
    }

    for (index, expected) in WYHASH_ORIGINAL_PRNG.iter().enumerate() {
        let mut seed = index as u64;
        receipt.vector_u64(krate, group, format!("wyhash_wyrng_seed{index:02}"), *expected, wyrng(&mut seed));
    }

    let mut sequence = WyRng::default();
    for (index, expected) in WYHASH_ORIGINAL_PRNG_SEQ.iter().enumerate() {
        receipt.vector_u64(krate, group, format!("wyhash_rng_next_u64_{index:02}"), *expected, sequence.next_u64());
    }

    let mut narrow = WyRng::default();
    for (index, expected) in WYHASH_ORIGINAL_PRNG_SEQ.iter().enumerate() {
        receipt.vector_u32(krate, group, format!("wyhash_rng_next_u32_{index:02}"), *expected as u32, narrow.next_u32());
    }

    for (index, expected) in WYHASH_ORIGINAL_PRNG.iter().enumerate() {
        let mut rng = WyRng::from_seed([index as u8, 0, 0, 0, 0, 0, 0, 0]);
        receipt.vector_u64(krate, group, format!("wyhash_rng_from_seed{index:02}"), *expected, rng.next_u64());
    }

    for (index, expected) in WYHASH_ORIGINAL_PRNG.iter().enumerate() {
        let mut rng = WyRng::seed_from_u64(index as u64);
        receipt.vector_u64(krate, group, format!("wyhash_rng_seed_from_u64_{index:02}"), *expected, rng.next_u64());
    }

    // `fill_bytes` is little-endian packed `next_u64`; read it back the same way.
    let mut filled_bytes = [0u8; 80];
    WyRng::default().fill_bytes(&mut filled_bytes);
    for (index, expected) in WYHASH_ORIGINAL_PRNG_SEQ.iter().enumerate() {
        let chunk: [u8; 8] = filled_bytes[index * 8..index * 8 + 8].try_into().expect("8-byte chunk");
        receipt.vector_u64(krate, group, format!("wyhash_rng_fill_bytes_{index:02}"), *expected, u64::from_le_bytes(chunk));
    }

    let mut filled_bytes = [0u8; 80];
    // `rand_core::Error` need not be `Debug`, so test the result rather than
    // unwrapping it.
    if WyRng::default().try_fill_bytes(&mut filled_bytes).is_err() {
        panic!("try_fill_bytes over an in-memory buffer cannot fail");
    }
    for (index, expected) in WYHASH_ORIGINAL_PRNG_SEQ.iter().enumerate() {
        let chunk: [u8; 8] = filled_bytes[index * 8..index * 8 + 8].try_into().expect("8-byte chunk");
        receipt.vector_u64(krate, group, format!("wyhash_rng_try_fill_bytes_{index:02}"), *expected, u64::from_le_bytes(chunk));
    }

    // examples/function.rs and src/lib.rs doctests.
    receipt.vector_u64(krate, group, "wyhash_doc_free_function_bytes_0_1_2", 0xb0f9_4152_0b1a_d95d, wyhash(&[0, 1, 2], 3));
    let mut doc_hasher = WyHash::with_seed(3);
    doc_hasher.write(&[0, 1, 2]);
    receipt.vector_u64(krate, group, "wyhash_doc_hasher_bytes_0_1_2", 0xb0f9_4152_0b1a_d95d, doc_hasher.finish());

    // Upstream's README.md asserts 0xcc242106e7076a48 for the identical call
    // that src/lib.rs's doctest and examples/hasher_trait.rs assert as
    // 0xb0f941520b1ad95d. CHANGELOG.md records that 0.2.0 changed the generated
    // hashes and README.md was never updated, so the README literal is stale.
    // Recording it as `distinct` keeps the divergence checked instead of
    // silently resolved: this case fails if the two ever agree.
    let mut readme_hasher = WyHash::with_seed(3);
    readme_hasher.write(&[0, 1, 2]);
    let crate_value = readme_hasher.finish();
    receipt.distinct_u64(krate, group, "wyhash_distinct_readme_literal_vs_doc_example", crate_value, 0xcc24_2106_e707_6a48);

    let mut example_seed = 1u64;
    let first = wyrng(&mut example_seed);
    receipt.vector_u64(krate, group, "wyhash_doc_wyrng_seed_1_value", 0xcdef_1695_e1f8_ed2c, first);
    receipt.vector_u64(krate, group, "wyhash_doc_wyrng_seed_1_seed_after", 0xa076_1d64_78bd_6430, example_seed);

    let mut doctest_seed = 3u64;
    let first = wyrng(&mut doctest_seed);
    receipt.vector_u64(krate, group, "wyhash_doc_wyrng_seed_3_value", 0x3e99_a772_750d_cbe, first);
    receipt.vector_u64(krate, group, "wyhash_doc_wyrng_seed_3_seed_after", 0xa076_1d64_78bd_6432, doctest_seed);

    let mut seeded = WyRng::from_seed([0, 1, 2, 3, 4, 5, 6, 7]);
    receipt.vector_u64(krate, group, "wyhash_doc_rng_from_seed_0_7", 0xd730_1357_74c6_ae31, seeded.next_u64());

    let mut from_u64 = WyRng::seed_from_u64(3);
    receipt.vector_u64(krate, group, "wyhash_doc_rng_seed_from_u64_3", 0x3e99_a772_750d_cbe, from_u64.next_u64());

    let mut default_rng = WyRng::default();
    receipt.vector_u64(krate, group, "wyhash_doc_rng_default_next_u64", 0x111c_b3a7_8f59_a58e, default_rng.next_u64());

    // tests/integration.rs: `WyHash::default()` writes a single zero byte.
    let mut integration = WyHash::default();
    integration.write(&[0]);
    receipt.vector_u64(krate, group, "wyhash_integration_default_write_0", 0x8c73_a8ab_4659_6ae4, integration.finish());
}

// ── adler 1.0.2 ────────────────────────────────────────────────────────────

/// `src/lib.rs` doctest: the derived-`Hash` example, whose expectation is
/// endianness dependent exactly as upstream states.
#[derive(Hash)]
struct AdlerHashExample {
    byte: u8,
    word: u16,
    big: u64,
}

fn adler_cases(receipt: &mut Receipt) {
    let krate = "adler";
    let group = "adler";
    use std::io::BufReader;

    // src/lib.rs `zeroes`
    receipt.vector_u32(krate, group, "adler_zeroes_empty", 1, adler::adler32_slice(&[]));
    receipt.vector_u32(krate, group, "adler_zeroes_one_zero", 1 | 1 << 16, adler::adler32_slice(&[0]));
    receipt.vector_u32(krate, group, "adler_zeroes_two_zeroes", 1 | 2 << 16, adler::adler32_slice(&[0, 0]));
    receipt.vector_u32(krate, group, "adler_zeroes_100", 0x0064_0001, adler::adler32_slice(&filled(100, 0)));
    receipt.vector_u32(krate, group, "adler_zeroes_1024", 0x0400_0001, adler::adler32_slice(&filled(1024, 0)));
    receipt.vector_u32(krate, group, "adler_zeroes_1mib", 0x00f0_0001, adler::adler32_slice(&filled(1024 * 1024, 0)));

    // src/lib.rs `ones`
    receipt.vector_u32(krate, group, "adler_ones_1024", 0x79a6_fc2e, adler::adler32_slice(&filled(1024, 0xff)));
    receipt.vector_u32(krate, group, "adler_ones_1mib", 0x8e88_ef11, adler::adler32_slice(&filled(1024 * 1024, 0xff)));

    // src/lib.rs `mixed`
    receipt.vector_u32(krate, group, "adler_mixed_one", 2 | 2 << 16, adler::adler32_slice(&[1]));
    receipt.vector_u32(krate, group, "adler_mixed_forty", 41 | 41 << 16, adler::adler32_slice(&[40]));
    receipt.vector_u32(krate, group, "adler_mixed_a5_1mib", 0xd500_9ab1, adler::adler32_slice(&filled(1024 * 1024, 0xa5)));

    // src/lib.rs `wiki`: the worked example from the Adler-32 article.
    receipt.vector_u32(krate, group, "adler_wiki_wikipedia", 0x11e6_0398, adler::adler32_slice(b"Wikipedia"));

    // src/lib.rs `resume`
    let mut resuming = Adler32::new();
    resuming.write_slice(&filled(1024, 0xff));
    let partial = resuming.checksum();
    receipt.vector_u32(krate, group, "adler_resume_partial_1024_ff", 0x79a6_fc2e, partial);
    resuming.write_slice(&filled(1024 * 1024 - 1024, 0xff));
    receipt.vector_u32(krate, group, "adler_resume_full_1mib_ff", 0x8e88_ef11, resuming.checksum());

    let mut resumed = Adler32::from_checksum(partial);
    resumed.write_slice(&filled(1024 * 1024 - 1024, 0xff));
    receipt.vector_u32(krate, group, "adler_resume_from_checksum_1mib_ff", 0x8e88_ef11, resumed.checksum());

    // src/lib.rs `bufread`: the default-`std` `BufRead` entry point, which the
    // 8 KiB `BufReader` buffer refills repeatedly.
    // The buffers are named locals: a `BufReader` borrows them for longer than
    // the statement that would otherwise create them.
    let empty_input: Vec<u8> = Vec::new();
    let zeroes_1024 = filled(1024, 0);
    let zeroes_1mib = filled(1024 * 1024, 0);
    let a5_1mib = filled(1024 * 1024, 0xa5);

    let mut bufread_empty = BufReader::new(&empty_input[..]);
    receipt.vector_u32(krate, group, "adler_bufread_empty", 1, adler::adler32(&mut bufread_empty).expect("in-memory BufRead cannot fail"));
    let mut bufread_1024 = BufReader::new(&zeroes_1024[..]);
    receipt.vector_u32(krate, group, "adler_bufread_1024_zeroes", 0x0400_0001, adler::adler32(&mut bufread_1024).expect("in-memory BufRead cannot fail"));
    let mut bufread_1mib_zeroes = BufReader::new(&zeroes_1mib[..]);
    receipt.vector_u32(krate, group, "adler_bufread_1mib_zeroes", 0x00f0_0001, adler::adler32(&mut bufread_1mib_zeroes).expect("in-memory BufRead cannot fail"));
    let mut bufread_1mib_a5 = BufReader::new(&a5_1mib[..]);
    receipt.vector_u32(krate, group, "adler_bufread_1mib_a5", 0xd500_9ab1, adler::adler32(&mut bufread_1mib_a5).expect("in-memory BufRead cannot fail"));

    // src/lib.rs doctests
    let mut piecewise = Adler32::new();
    piecewise.write_slice(&[0, 1, 2]);
    piecewise.write_slice(&[3, 4, 5]);
    receipt.vector_u32(krate, group, "adler_doc_piecewise_0_1_2_3_4_5", 0x0029_0010, piecewise.checksum());

    let data = AdlerHashExample { byte: 0x1f, word: 0xabcd, big: u64::MAX };
    let mut derived = Adler32::new();
    data.hash(&mut derived);
    let expected = if cfg!(target_endian = "little") { 0x3341_0990 } else { 0x331f_0990 };
    receipt.vector_u32(krate, group, "adler_doc_derived_hash", expected, derived.checksum());

    let whole = adler::adler32_slice(b"rustacean");
    let mut split = Adler32::new();
    split.write_slice(b"rust");
    let partial = split.checksum();
    let mut later = Adler32::from_checksum(partial);
    later.write_slice(b"acean");
    receipt.consistency_u32(krate, group, "adler_doc_from_checksum_rustacean", whole, later.checksum());

    // `std::hash::Hasher` is the crate's second entry point into the same state.
    let mut hasher = Adler32::new();
    hasher.write(b"Wikipedia");
    receipt.consistency_u32(krate, group, "adler_consistency_hasher_trait_wikipedia", adler::adler32_slice(b"Wikipedia"), hasher.finish() as u32);

    // Chunked writes must reproduce the one-shot result across the vectorized
    // 4-byte path and its `CHUNK_SIZE` (5552 * 4) boundary.
    let payload = filled(70_000, 0xa5);
    let one_shot = adler::adler32_slice(&payload);
    for chunk in [1usize, 2, 3, 4, 5, 7, 8, 15, 16, 17, 5551, 5552, 5553, 22_208, 22_209] {
        let mut chunked = Adler32::new();
        for slice in payload.chunks(chunk) {
            chunked.write_slice(slice);
        }
        receipt.consistency_u32(krate, group, format!("adler_consistency_chunk_{chunk:05}"), one_shot, chunked.checksum());
    }
}

// ── xxhash-rust 0.8.15, xxh32 ──────────────────────────────────────────────

#[cfg(feature = "xxh32")]
/// `fillTestBuffer` from Cyan4973/xxHash v0.8.2 `tests/sanity_test.c`:
/// `byteGen` starts at `PRIME32`, each byte is its top byte, and the generator
/// is multiplied by `PRIME64` before the next byte.
fn xxh32_sanity_buffer(len: usize) -> Vec<u8> {
    const PRIME32: u64 = 2_654_435_761;
    const PRIME64: u64 = 11_400_714_785_074_694_797;
    let mut buffer = Vec::with_capacity(len);
    let mut byte_gen = PRIME32;
    for _ in 0..len {
        buffer.push((byte_gen >> 56) as u8);
        byte_gen = byte_gen.wrapping_mul(PRIME64);
    }
    buffer
}

#[cfg(feature = "xxh32")]
/// The seeds of `XSUM_XXH32_testdata`, in table order: entry `2 * len` uses
/// seed `SEEDS[0]` and entry `2 * len + 1` uses `SEEDS[1]`.
const XXH32_SEEDS: [u32; 2] = [0x0000_0000, 0x9e37_79b1];

/// `XSUM_XXH32_testdata[0..=129]` from Cyan4973/xxHash v0.8.2
/// `tests/sanity_test_vectors.h`: lengths 0..=64 for both seeds.
#[cfg(feature = "xxh32")]
#[rustfmt::skip]
const XXH32_OFFICIAL: [u32; 130] = [
    0x02CC5D05, 0x36B78AE7, 0xCF65B03E, 0xB4545AA4, 0x1151BEE4, 0x1EDB879A,
    0xC23884F5, 0x1A269947, 0xA9DE7CE9, 0x2BAAFE83, 0xEB1734BB, 0x5874DAB0,
    0x659F0C97, 0x0BCF25C5, 0x5E1056CD, 0x3ED9D3FC, 0xA3F6F44B, 0xC2A8E239,
    0xFFB82A24, 0xD35632C6, 0xB1E5032E, 0x18679D60, 0x0CF2F032, 0xE0E99838,
    0xE89B5F9B, 0x05A6C4B5, 0xC537DE02, 0x1298ADD0, 0x1208E7E2, 0x6AF1D1FE,
    0x6B859E14, 0xAD53090D, 0x93BA3759, 0xA94FC1E1, 0x89FDC23E, 0xC9910739,
    0x16B53F56, 0x5E88116E, 0x858FC8EA, 0x63826A8F, 0x38374A35, 0xC691A55A,
    0x646A88D6, 0x9668CDAB, 0xB5CCC747, 0x96F6C6A1, 0xCC7B3099, 0x174910FE,
    0xA6276FF0, 0x7AD49212, 0x221B959B, 0xA1899908, 0x3F2F5961, 0x6A936E6B,
    0x9501BDDD, 0x61A4E18B, 0xDA976167, 0x261F77CF, 0x249CC065, 0xC8EC8904,
    0x36BC3693, 0xA2800E16, 0x5F40E562, 0x5C0C3350, 0xD89829EC, 0xA5C44467,
    0x31A427E5, 0x0DE5B1F9, 0x80B8584B, 0x7FFCCCFE, 0x7627760A, 0xD060F480,
    0xED4F560F, 0x24321F47, 0x1241D245, 0x09EFB299, 0x5E1CC178, 0xC1322A61,
    0xBA125684, 0x2D6246FF, 0xB22A36AB, 0xBF491205, 0x161223AF, 0x0CB4D70F,
    0x11586B3F, 0x29218DC3, 0x0A1C7CC9, 0x4D7337AB, 0xF0910CD3, 0xF33E0443,
    0xDD97A408, 0x8CEC6D9C, 0x3A609997, 0xBD3BA412, 0xD5E9364E, 0xA463C5A4,
    0xBFD05CBD, 0x0ECCC06E, 0xED9B7E81, 0xA7E98491, 0xBDF553E2, 0xA937E7ED,
    0x3CDEED0F, 0x9E2ED4B1, 0x27D50857, 0x4682E48B, 0x62E63D09, 0x1FF1A182,
    0x30BACCFA, 0x955B14A7, 0xEA5D7666, 0x300DDE4D, 0xC8D07416, 0x8952E674,
    0xDF6987F5, 0x98D545E4, 0x447DCE59, 0x1CFC5C29, 0x4529090D, 0xE3ACD84E,
    0xA48E8818, 0x31CA20F1, 0xB1C4FBB5, 0x21749FC9, 0x84145F58, 0x0374E669,
    0xF1D48FDB, 0x956B3D77, 0x02E95DBB, 0xCF82F830,
];

#[cfg(not(feature = "xxh32"))]
fn xxhash_cases(receipt: &mut Receipt) {
    // Upstream 0.8.15 declares no `default` feature, so cfg evaluation drops
    // every module and the empty default configuration exposes no algorithm.
    // That configuration is valid, and this binary *is* it: it could not name
    // `xxhash_rust::xxh32` at all. The 32-bit vectors are recorded by the
    // `--features xxh32` run instead.
    receipt.record(
        "xxhash-rust",
        "xxh32",
        "xxh32_configuration_default_features",
        Kind::Vector,
        "str",
        String::from("no-algorithm-exposed"),
        String::from("no-algorithm-exposed"),
    );
}

#[cfg(feature = "xxh32")]
fn xxhash_cases(receipt: &mut Receipt) {
    let krate = "xxhash-rust";
    let group = "xxh32";

    // The explicit feature is what makes the 32-bit algorithm reachable at all.
    receipt.record(
        "xxhash-rust",
        "xxh32",
        "xxh32_configuration_explicit_feature",
        Kind::Vector,
        "str",
        String::from("xxh32-exposed"),
        String::from("xxh32-exposed"),
    );
    // tests/size.rs asserts this exact size for the streaming state.
    receipt.vector_dec(
        krate,
        group,
        "xxh32_size_of_xxh32",
        "44".to_string(),
        std::mem::size_of::<xxhash_rust::xxh32::Xxh32>().to_string(),
    );

    let buffer = xxh32_sanity_buffer(65);
    for index in 0..XXH32_OFFICIAL.len() {
        let len = index / 2;
        let seed = XXH32_SEEDS[index % 2];
        let expected = XXH32_OFFICIAL[index];
        let data = &buffer[..len];
        let seed_tag = format!("{seed:08x}");

        // One-shot entry point.
        receipt.vector_u32(krate, group, format!("xxh32_official_len{len:03}_seed{seed_tag}"), expected, xxhash_rust::xxh32::xxh32(data, seed));

        // Streaming state fed the whole buffer in one update, exactly as the C
        // sanity check does before each comparison.
        let mut streaming = xxhash_rust::xxh32::Xxh32::new(seed);
        streaming.update(data);
        receipt.vector_u32(krate, group, format!("xxh32_streaming_len{len:03}_seed{seed_tag}"), expected, streaming.digest());

        // The same state fed one byte at a time.
        let mut bytewise = xxhash_rust::xxh32::Xxh32::new(seed);
        for byte in data {
            bytewise.update(&[*byte]);
        }
        receipt.vector_u32(krate, group, format!("xxh32_bytewise_len{len:03}_seed{seed_tag}"), expected, bytewise.digest());
    }
}

// ── siphasher 1.0.1 ────────────────────────────────────────────────────────

/// The key both upstream vector tables are generated with.
const SIP_KEY: (u64, u64) = (0x0706_0504_0302_0100, 0x0f0e_0d0c_0b0a_0908);

/// `src/tests.rs` `test_siphash_1_3`, copied verbatim: entry `t` is the hash of
/// the bytes `0..t` under `SipHasher13` with `SIP_KEY`.
#[rustfmt::skip]
const SIPHASHER13_VECTORS: [[u8; 8]; 64] = [
    [0xdc, 0xc4, 0x0f, 0x05, 0x58, 0x01, 0xac, 0xab],
    [0x93, 0xca, 0x57, 0x7d, 0xf3, 0x9b, 0xf4, 0xc9],
    [0x4d, 0xd4, 0xc7, 0x4d, 0x02, 0x9b, 0xcb, 0x82],
    [0xfb, 0xf7, 0xdd, 0xe7, 0xb8, 0x0a, 0xf8, 0x8b],
    [0x28, 0x83, 0xd3, 0x88, 0x60, 0x57, 0x75, 0xcf],
    [0x67, 0x3b, 0x53, 0x49, 0x2f, 0xd5, 0xf9, 0xde],
    [0xa7, 0x22, 0x9f, 0xc5, 0x50, 0x2b, 0x0d, 0xc5],
    [0x40, 0x11, 0xb1, 0x9b, 0x98, 0x7d, 0x92, 0xd3],
    [0x8e, 0x9a, 0x29, 0x8d, 0x11, 0x95, 0x90, 0x36],
    [0xe4, 0x3d, 0x06, 0x6c, 0xb3, 0x8e, 0xa4, 0x25],
    [0x7f, 0x09, 0xff, 0x92, 0xee, 0x85, 0xde, 0x79],
    [0x52, 0xc3, 0x4d, 0xf9, 0xc1, 0x18, 0xc1, 0x70],
    [0xa2, 0xd9, 0xb4, 0x57, 0xb1, 0x84, 0xa3, 0x78],
    [0xa7, 0xff, 0x29, 0x12, 0x0c, 0x76, 0x6f, 0x30],
    [0x34, 0x5d, 0xf9, 0xc0, 0x11, 0xa1, 0x5a, 0x60],
    [0x56, 0x99, 0x51, 0x2a, 0x6d, 0xd8, 0x20, 0xd3],
    [0x66, 0x8b, 0x90, 0x7d, 0x1a, 0xdd, 0x4f, 0xcc],
    [0x0c, 0xd8, 0xdb, 0x63, 0x90, 0x68, 0xf2, 0x9c],
    [0x3e, 0xe6, 0x73, 0xb4, 0x9c, 0x38, 0xfc, 0x8f],
    [0x1c, 0x7d, 0x29, 0x8d, 0xe5, 0x9d, 0x1f, 0xf2],
    [0x40, 0xe0, 0xcc, 0xa6, 0x46, 0x2f, 0xdc, 0xc0],
    [0x44, 0xf8, 0x45, 0x2b, 0xfe, 0xab, 0x92, 0xb9],
    [0x2e, 0x87, 0x20, 0xa3, 0x9b, 0x7b, 0xfe, 0x7f],
    [0x23, 0xc1, 0xe6, 0xda, 0x7f, 0x0e, 0x5a, 0x52],
    [0x8c, 0x9c, 0x34, 0x67, 0xb2, 0xae, 0x64, 0xf4],
    [0x79, 0x09, 0x5b, 0x70, 0x28, 0x59, 0xcd, 0x45],
    [0xa5, 0x13, 0x99, 0xca, 0xe3, 0x35, 0x3e, 0x3a],
    [0x35, 0x3b, 0xde, 0x4a, 0x4e, 0xc7, 0x1d, 0xa9],
    [0x0d, 0xd0, 0x6c, 0xef, 0x02, 0xed, 0x0b, 0xfb],
    [0xf4, 0xe1, 0xb1, 0x4a, 0xb4, 0x3c, 0xd9, 0x88],
    [0x63, 0xe6, 0xc5, 0x43, 0xd6, 0x11, 0x0f, 0x54],
    [0xbc, 0xd1, 0x21, 0x8c, 0x1f, 0xdd, 0x70, 0x23],
    [0x0d, 0xb6, 0xa7, 0x16, 0x6c, 0x7b, 0x15, 0x81],
    [0xbf, 0xf9, 0x8f, 0x7a, 0xe5, 0xb9, 0x54, 0x4d],
    [0x3e, 0x75, 0x2a, 0x1f, 0x78, 0x12, 0x9f, 0x75],
    [0x91, 0x6b, 0x18, 0xbf, 0xbe, 0xa3, 0xa1, 0xce],
    [0x06, 0x62, 0xa2, 0xad, 0xd3, 0x08, 0xf5, 0x2c],
    [0x57, 0x30, 0xc3, 0xa3, 0x2d, 0x1c, 0x10, 0xb6],
    [0xa1, 0x36, 0x3a, 0xae, 0x96, 0x74, 0xf4, 0xb3],
    [0x92, 0x83, 0x10, 0x7b, 0x54, 0x57, 0x6b, 0x62],
    [0x31, 0x15, 0xe4, 0x99, 0x32, 0x36, 0xd2, 0xc1],
    [0x44, 0xd9, 0x1a, 0x3f, 0x92, 0xc1, 0x7c, 0x66],
    [0x25, 0x88, 0x13, 0xc8, 0xfe, 0x4f, 0x70, 0x65],
    [0xa6, 0x49, 0x89, 0xc2, 0xd1, 0x80, 0xf2, 0x24],
    [0x6b, 0x87, 0xf8, 0xfa, 0xed, 0x1c, 0xca, 0xc2],
    [0x96, 0x21, 0x04, 0x9f, 0xfc, 0x4b, 0x16, 0xc2],
    [0x23, 0xd6, 0xb1, 0x68, 0x93, 0x9c, 0x6e, 0xa1],
    [0xfd, 0x14, 0x51, 0x8b, 0x9c, 0x16, 0xfb, 0x49],
    [0x46, 0x4c, 0x07, 0xdf, 0xf8, 0x43, 0x31, 0x9f],
    [0xb3, 0x86, 0xcc, 0x12, 0x24, 0xaf, 0xfd, 0xc6],
    [0x8f, 0x09, 0x52, 0x0a, 0xd1, 0x49, 0xaf, 0x7e],
    [0x9a, 0x2f, 0x29, 0x9d, 0x55, 0x13, 0xf3, 0x1c],
    [0x12, 0x1f, 0xf4, 0xa2, 0xdd, 0x30, 0x4a, 0xc4],
    [0xd0, 0x1e, 0xa7, 0x43, 0x89, 0xe9, 0xfa, 0x36],
    [0xe6, 0xbc, 0xf0, 0x73, 0x4c, 0xb3, 0x8f, 0x31],
    [0x80, 0xe9, 0xa7, 0x70, 0x36, 0xbf, 0x7a, 0xa2],
    [0x75, 0x6d, 0x3c, 0x24, 0xdb, 0xc0, 0xbc, 0xb4],
    [0x13, 0x15, 0xb7, 0xfd, 0x52, 0xd8, 0xf8, 0x23],
    [0x08, 0x8a, 0x7d, 0xa6, 0x4d, 0x5f, 0x03, 0x8f],
    [0x48, 0xf1, 0xe8, 0xb7, 0xe5, 0xd0, 0x9c, 0xd8],
    [0xee, 0x44, 0xa6, 0xf7, 0xbc, 0xe6, 0xf4, 0xf6],
    [0xf2, 0x37, 0x18, 0x0f, 0xd8, 0x9a, 0xc5, 0xae],
    [0xe0, 0x94, 0x66, 0x4b, 0x15, 0xf6, 0xb2, 0xc3],
    [0xa8, 0xb3, 0xbb, 0xb7, 0x62, 0x90, 0x19, 0x9d],
];

/// `src/tests.rs` `test_siphash_2_4`, copied verbatim.
#[rustfmt::skip]
const SIPHASHER24_VECTORS: [[u8; 8]; 64] = [
    [0x31, 0x0e, 0x0e, 0xdd, 0x47, 0xdb, 0x6f, 0x72],
    [0xfd, 0x67, 0xdc, 0x93, 0xc5, 0x39, 0xf8, 0x74],
    [0x5a, 0x4f, 0xa9, 0xd9, 0x09, 0x80, 0x6c, 0x0d],
    [0x2d, 0x7e, 0xfb, 0xd7, 0x96, 0x66, 0x67, 0x85],
    [0xb7, 0x87, 0x71, 0x27, 0xe0, 0x94, 0x27, 0xcf],
    [0x8d, 0xa6, 0x99, 0xcd, 0x64, 0x55, 0x76, 0x18],
    [0xce, 0xe3, 0xfe, 0x58, 0x6e, 0x46, 0xc9, 0xcb],
    [0x37, 0xd1, 0x01, 0x8b, 0xf5, 0x00, 0x02, 0xab],
    [0x62, 0x24, 0x93, 0x9a, 0x79, 0xf5, 0xf5, 0x93],
    [0xb0, 0xe4, 0xa9, 0x0b, 0xdf, 0x82, 0x00, 0x9e],
    [0xf3, 0xb9, 0xdd, 0x94, 0xc5, 0xbb, 0x5d, 0x7a],
    [0xa7, 0xad, 0x6b, 0x22, 0x46, 0x2f, 0xb3, 0xf4],
    [0xfb, 0xe5, 0x0e, 0x86, 0xbc, 0x8f, 0x1e, 0x75],
    [0x90, 0x3d, 0x84, 0xc0, 0x27, 0x56, 0xea, 0x14],
    [0xee, 0xf2, 0x7a, 0x8e, 0x90, 0xca, 0x23, 0xf7],
    [0xe5, 0x45, 0xbe, 0x49, 0x61, 0xca, 0x29, 0xa1],
    [0xdb, 0x9b, 0xc2, 0x57, 0x7f, 0xcc, 0x2a, 0x3f],
    [0x94, 0x47, 0xbe, 0x2c, 0xf5, 0xe9, 0x9a, 0x69],
    [0x9c, 0xd3, 0x8d, 0x96, 0xf0, 0xb3, 0xc1, 0x4b],
    [0xbd, 0x61, 0x79, 0xa7, 0x1d, 0xc9, 0x6d, 0xbb],
    [0x98, 0xee, 0xa2, 0x1a, 0xf2, 0x5c, 0xd6, 0xbe],
    [0xc7, 0x67, 0x3b, 0x2e, 0xb0, 0xcb, 0xf2, 0xd0],
    [0x88, 0x3e, 0xa3, 0xe3, 0x95, 0x67, 0x53, 0x93],
    [0xc8, 0xce, 0x5c, 0xcd, 0x8c, 0x03, 0x0c, 0xa8],
    [0x94, 0xaf, 0x49, 0xf6, 0xc6, 0x50, 0xad, 0xb8],
    [0xea, 0xb8, 0x85, 0x8a, 0xde, 0x92, 0xe1, 0xbc],
    [0xf3, 0x15, 0xbb, 0x5b, 0xb8, 0x35, 0xd8, 0x17],
    [0xad, 0xcf, 0x6b, 0x07, 0x63, 0x61, 0x2e, 0x2f],
    [0xa5, 0xc9, 0x1d, 0xa7, 0xac, 0xaa, 0x4d, 0xde],
    [0x71, 0x65, 0x95, 0x87, 0x66, 0x50, 0xa2, 0xa6],
    [0x28, 0xef, 0x49, 0x5c, 0x53, 0xa3, 0x87, 0xad],
    [0x42, 0xc3, 0x41, 0xd8, 0xfa, 0x92, 0xd8, 0x32],
    [0xce, 0x7c, 0xf2, 0x72, 0x2f, 0x51, 0x27, 0x71],
    [0xe3, 0x78, 0x59, 0xf9, 0x46, 0x23, 0xf3, 0xa7],
    [0x38, 0x12, 0x05, 0xbb, 0x1a, 0xb0, 0xe0, 0x12],
    [0xae, 0x97, 0xa1, 0x0f, 0xd4, 0x34, 0xe0, 0x15],
    [0xb4, 0xa3, 0x15, 0x08, 0xbe, 0xff, 0x4d, 0x31],
    [0x81, 0x39, 0x62, 0x29, 0xf0, 0x90, 0x79, 0x02],
    [0x4d, 0x0c, 0xf4, 0x9e, 0xe5, 0xd4, 0xdc, 0xca],
    [0x5c, 0x73, 0x33, 0x6a, 0x76, 0xd8, 0xbf, 0x9a],
    [0xd0, 0xa7, 0x04, 0x53, 0x6b, 0xa9, 0x3e, 0x0e],
    [0x92, 0x59, 0x58, 0xfc, 0xd6, 0x42, 0x0c, 0xad],
    [0xa9, 0x15, 0xc2, 0x9b, 0xc8, 0x06, 0x73, 0x18],
    [0x95, 0x2b, 0x79, 0xf3, 0xbc, 0x0a, 0xa6, 0xd4],
    [0xf2, 0x1d, 0xf2, 0xe4, 0x1d, 0x45, 0x35, 0xf9],
    [0x87, 0x57, 0x75, 0x19, 0x04, 0x8f, 0x53, 0xa9],
    [0x10, 0xa5, 0x6c, 0xf5, 0xdf, 0xcd, 0x9a, 0xdb],
    [0xeb, 0x75, 0x09, 0x5c, 0xcd, 0x98, 0x6c, 0xd0],
    [0x51, 0xa9, 0xcb, 0x9e, 0xcb, 0xa3, 0x12, 0xe6],
    [0x96, 0xaf, 0xad, 0xfc, 0x2c, 0xe6, 0x66, 0xc7],
    [0x72, 0xfe, 0x52, 0x97, 0x5a, 0x43, 0x64, 0xee],
    [0x5a, 0x16, 0x45, 0xb2, 0x76, 0xd5, 0x92, 0xa1],
    [0xb2, 0x74, 0xcb, 0x8e, 0xbf, 0x87, 0x87, 0x0a],
    [0x6f, 0x9b, 0xb4, 0x20, 0x3d, 0xe7, 0xb3, 0x81],
    [0xea, 0xec, 0xb2, 0xa3, 0x0b, 0x22, 0xa8, 0x7f],
    [0x99, 0x24, 0xa4, 0x3c, 0xc1, 0x31, 0x57, 0x24],
    [0xbd, 0x83, 0x8d, 0x3a, 0xaf, 0xbf, 0x8d, 0xb7],
    [0x0b, 0x1a, 0x2a, 0x32, 0x65, 0xd5, 0x1a, 0xea],
    [0x13, 0x50, 0x79, 0xa3, 0x23, 0x1c, 0xe6, 0x60],
    [0x93, 0x2b, 0x28, 0x46, 0xe4, 0xd7, 0x06, 0x66],
    [0xe1, 0x91, 0x5f, 0x5c, 0xb1, 0xec, 0xa4, 0x6c],
    [0xf3, 0x25, 0x96, 0x5c, 0xa1, 0x6d, 0x62, 0x9f],
    [0x57, 0x5f, 0xf2, 0x8e, 0x60, 0x38, 0x1b, 0xe5],
    [0x72, 0x45, 0x06, 0xeb, 0x4c, 0x32, 0x8a, 0x95],
];

/// `src/tests128.rs` publishes exactly one 128-bit literal per variant, for the
/// empty input. `as_bytes()` is little-endian `h1` followed by little-endian
/// `h2`, which is the byte order these tables are given in.
#[rustfmt::skip]
const SIPHASHER128_13_VECTOR: [u8; 16] = [
    231, 126, 188, 178, 39, 136, 165, 190, 253, 98, 219, 106, 221, 48, 48, 1,
];

#[rustfmt::skip]
const SIPHASHER128_24_VECTOR: [u8; 16] = [
    163, 129, 127, 4, 186, 37, 168, 230, 109, 246, 114, 20, 199, 85, 2, 147,
];

fn siphasher_cases(receipt: &mut Receipt) {
    let krate = "siphasher";
    let (k0, k1) = SIP_KEY;
    let mut input = [0u8; 64];
    for (index, byte) in input.iter_mut().enumerate() {
        *byte = index as u8;
    }

    // ── sip64: published tables, one-shot and byte-at-a-time streaming ──────
    let group = "sip64";
    let mut incremental13 = SipHasher13::new_with_keys(k0, k1);
    let mut incremental24 = SipHasher24::new_with_keys(k0, k1);
    for index in 0..64 {
        let data = &input[..index];
        let tag = format!("in{index:02}");

        let mut oneshot13 = SipHasher13::new_with_keys(k0, k1);
        oneshot13.write(data);
        receipt.vector_u64(krate, group, format!("sip64_siphasher13_{tag}"), u64::from_le_bytes(SIPHASHER13_VECTORS[index]), oneshot13.finish());

        let mut oneshot24 = SipHasher24::new_with_keys(k0, k1);
        oneshot24.write(data);
        receipt.vector_u64(krate, group, format!("sip64_siphasher24_{tag}"), u64::from_le_bytes(SIPHASHER24_VECTORS[index]), oneshot24.finish());

        // The upstream loop also compares the state fed one byte at a time.
        receipt.vector_u64(krate, group, format!("sip64_siphasher13_incremental_{tag}"), u64::from_le_bytes(SIPHASHER13_VECTORS[index]), incremental13.finish());
        incremental13.write(&[index as u8]);

        receipt.vector_u64(krate, group, format!("sip64_siphasher24_incremental_{tag}"), u64::from_le_bytes(SIPHASHER24_VECTORS[index]), incremental24.finish());
        incremental24.write(&[index as u8]);
    }

    // `new_with_key` reads the same two keys from a 16-byte vector.
    let mut key_bytes = [0u8; 16];
    key_bytes[..8].copy_from_slice(&k0.to_le_bytes());
    key_bytes[8..].copy_from_slice(&k1.to_le_bytes());
    for index in 0..input.len() {
        let from_key = SipHasher24::new_with_key(&key_bytes).hash(&input[..index]);
        let from_keys = SipHasher24::new_with_keys(k0, k1).hash(&input[..index]);
        receipt.consistency_u64(krate, group, format!("sip64_siphasher24_new_with_key_in{index:02}"), from_keys, from_key);
    }

    // Chunk-at-a-time writes must match the one-shot `hash` entry point.
    let payload: Vec<u8> = (0..40u8).collect();
    for split in [1usize, 3, 7, 8, 9] {
        let mut chunked = SipHasher24::new_with_keys(k0, k1);
        for slice in payload.chunks(split) {
            chunked.write(slice);
        }
        receipt.consistency_u64(krate, group, format!("sip64_streaming_split{split:02}"), SipHasher24::new_with_keys(k0, k1).hash(&payload), chunked.finish());
    }

    // ── sip128: one published literal, then one-shot vs. trait-path agreement ──
    let group = "sip128";
    receipt.vector_bytes16(krate, group, "sip128_siphasher13_in00", &SIPHASHER128_13_VECTOR, &Sip128Hasher13::new_with_keys(k0, k1).hash(&[]).as_bytes());
    receipt.vector_bytes16(krate, group, "sip128_siphasher24_in00", &SIPHASHER128_24_VECTOR, &Sip128Hasher24::new_with_keys(k0, k1).hash(&[]).as_bytes());

    for index in 1..input.len() {
        let data = &input[..index];
        let tag = format!("in{index:02}");

        let mut streamed13 = Sip128Hasher13::new_with_keys(k0, k1);
        streamed13.write(data);
        receipt.consistency_bytes16(krate, group, format!("sip128_siphasher13_{tag}"), &Sip128Hasher13::new_with_keys(k0, k1).hash(data).as_bytes(), &streamed13.finish128().as_bytes());

        let mut streamed24 = Sip128Hasher24::new_with_keys(k0, k1);
        streamed24.write(data);
        receipt.consistency_bytes16(krate, group, format!("sip128_siphasher24_{tag}"), &Sip128Hasher24::new_with_keys(k0, k1).hash(data).as_bytes(), &streamed24.finish128().as_bytes());
    }

    // `src/tests128.rs` `test_siphash128_simple` / `_incremental`: a 16-byte key
    // feeds the same key material, and split writes must still agree.
    let array_key: &[u8; 16] = &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    let whole = [1u8, 2, 3, 4, 5, 6];
    for split in [1usize, 3, 4] {
        let mut hasher = Sip128Hasher13::new_with_key(array_key);
        for slice in whole.chunks(split) {
            hasher.write(slice);
        }
        receipt.consistency_bytes16(krate, group, format!("sip128_streaming_split{split:02}"), &Sip128Hasher13::new_with_key(array_key).hash(&whole).as_bytes(), &hasher.finish128().as_bytes());
    }
}

// ── itoa 1.0.11 ────────────────────────────────────────────────────────────

/// Formats one value into a fresh `Buffer` and records the result. The expected
/// text is the integer's decimal form; `encoding` is `dec` because the value
/// *is* decimal text, which is what `Buffer::format` produces.
macro_rules! itoa_case {
    ($receipt:ident, $name:expr, $value:expr, $expected:expr) => {{
        let mut buffer = Buffer::new();
        let actual = buffer.format($value);
        $receipt.vector_dec("itoa", "itoa_boundary", $name, String::from($expected), String::from(actual));
    }};
}

fn itoa_cases(receipt: &mut Receipt) {
    // tests/test.rs, verbatim.
    itoa_case!(receipt, "itoa_boundary_test_u64_0", 0u64, "0");
    itoa_case!(receipt, "itoa_boundary_test_u64_half", u32::MAX as u64, "4294967295");
    itoa_case!(receipt, "itoa_boundary_test_u64_max", u64::MAX, "18446744073709551615");
    itoa_case!(receipt, "itoa_boundary_test_i64_min", i64::MIN, "-9223372036854775808");
    itoa_case!(receipt, "itoa_boundary_test_i16_0", 0i16, "0");
    itoa_case!(receipt, "itoa_boundary_test_i16_min", i16::MIN, "-32768");
    itoa_case!(receipt, "itoa_boundary_test_u128_0", 0u128, "0");
    itoa_case!(receipt, "itoa_boundary_test_u128_max", u128::MAX, "340282366920938463463374607431768211455");
    itoa_case!(receipt, "itoa_boundary_test_i128_min", i128::MIN, "-170141183460469231731687303715884105728");
    itoa_case!(receipt, "itoa_boundary_test_i128_max", i128::MAX, "170141183460469231731687303715884105727");

    // Every primitive's MIN/MIN+1/MAX-1/MAX, the values where a formatter that
    // is off by one in its magnitude estimate breaks first.
    itoa_case!(receipt, "itoa_boundary_i8_min", i8::MIN, "-128");
    itoa_case!(receipt, "itoa_boundary_i8_min_plus_1", i8::MIN + 1, "-127");
    itoa_case!(receipt, "itoa_boundary_i8_minus_1", -1i8, "-1");
    itoa_case!(receipt, "itoa_boundary_i8_zero", 0i8, "0");
    itoa_case!(receipt, "itoa_boundary_i8_one", 1i8, "1");
    itoa_case!(receipt, "itoa_boundary_i8_nine", 9i8, "9");
    itoa_case!(receipt, "itoa_boundary_i8_ten", 10i8, "10");
    itoa_case!(receipt, "itoa_boundary_i8_ninety_nine", 99i8, "99");
    itoa_case!(receipt, "itoa_boundary_i8_one_hundred", 100i8, "100");
    itoa_case!(receipt, "itoa_boundary_i8_max_minus_1", i8::MAX - 1, "126");
    itoa_case!(receipt, "itoa_boundary_i8_max", i8::MAX, "127");

    itoa_case!(receipt, "itoa_boundary_u8_min", u8::MIN, "0");
    itoa_case!(receipt, "itoa_boundary_u8_min_plus_1", u8::MIN + 1, "1");
    itoa_case!(receipt, "itoa_boundary_u8_nine", 9u8, "9");
    itoa_case!(receipt, "itoa_boundary_u8_ten", 10u8, "10");
    itoa_case!(receipt, "itoa_boundary_u8_ninety_nine", 99u8, "99");
    itoa_case!(receipt, "itoa_boundary_u8_one_hundred", 100u8, "100");
    itoa_case!(receipt, "itoa_boundary_u8_max_minus_1", u8::MAX - 1, "254");
    itoa_case!(receipt, "itoa_boundary_u8_max", u8::MAX, "255");

    itoa_case!(receipt, "itoa_boundary_i16_min", i16::MIN, "-32768");
    itoa_case!(receipt, "itoa_boundary_i16_min_plus_1", i16::MIN + 1, "-32767");
    itoa_case!(receipt, "itoa_boundary_i16_minus_1", -1i16, "-1");
    itoa_case!(receipt, "itoa_boundary_i16_zero", 0i16, "0");
    itoa_case!(receipt, "itoa_boundary_i16_one", 1i16, "1");
    itoa_case!(receipt, "itoa_boundary_i16_nine", 9i16, "9");
    itoa_case!(receipt, "itoa_boundary_i16_ten", 10i16, "10");
    itoa_case!(receipt, "itoa_boundary_i16_ninety_nine", 99i16, "99");
    itoa_case!(receipt, "itoa_boundary_i16_one_hundred", 100i16, "100");
    itoa_case!(receipt, "itoa_boundary_i16_max_minus_1", i16::MAX - 1, "32766");
    itoa_case!(receipt, "itoa_boundary_i16_max", i16::MAX, "32767");

    itoa_case!(receipt, "itoa_boundary_u16_min", u16::MIN, "0");
    itoa_case!(receipt, "itoa_boundary_u16_min_plus_1", u16::MIN + 1, "1");
    itoa_case!(receipt, "itoa_boundary_u16_nine", 9u16, "9");
    itoa_case!(receipt, "itoa_boundary_u16_ten", 10u16, "10");
    itoa_case!(receipt, "itoa_boundary_u16_ninety_nine", 99u16, "99");
    itoa_case!(receipt, "itoa_boundary_u16_one_hundred", 100u16, "100");
    itoa_case!(receipt, "itoa_boundary_u16_max_minus_1", u16::MAX - 1, "65534");
    itoa_case!(receipt, "itoa_boundary_u16_max", u16::MAX, "65535");

    itoa_case!(receipt, "itoa_boundary_i32_min", i32::MIN, "-2147483648");
    itoa_case!(receipt, "itoa_boundary_i32_min_plus_1", i32::MIN + 1, "-2147483647");
    itoa_case!(receipt, "itoa_boundary_i32_minus_1", -1i32, "-1");
    itoa_case!(receipt, "itoa_boundary_i32_zero", 0i32, "0");
    itoa_case!(receipt, "itoa_boundary_i32_one", 1i32, "1");
    itoa_case!(receipt, "itoa_boundary_i32_nine", 9i32, "9");
    itoa_case!(receipt, "itoa_boundary_i32_ten", 10i32, "10");
    itoa_case!(receipt, "itoa_boundary_i32_ninety_nine", 99i32, "99");
    itoa_case!(receipt, "itoa_boundary_i32_one_hundred", 100i32, "100");
    itoa_case!(receipt, "itoa_boundary_i32_max_minus_1", i32::MAX - 1, "2147483646");
    itoa_case!(receipt, "itoa_boundary_i32_max", i32::MAX, "2147483647");

    itoa_case!(receipt, "itoa_boundary_u32_min", u32::MIN, "0");
    itoa_case!(receipt, "itoa_boundary_u32_min_plus_1", u32::MIN + 1, "1");
    itoa_case!(receipt, "itoa_boundary_u32_nine", 9u32, "9");
    itoa_case!(receipt, "itoa_boundary_u32_ten", 10u32, "10");
    itoa_case!(receipt, "itoa_boundary_u32_ninety_nine", 99u32, "99");
    itoa_case!(receipt, "itoa_boundary_u32_one_hundred", 100u32, "100");
    itoa_case!(receipt, "itoa_boundary_u32_max_minus_1", u32::MAX - 1, "4294967294");
    itoa_case!(receipt, "itoa_boundary_u32_max", u32::MAX, "4294967295");

    itoa_case!(receipt, "itoa_boundary_i64_min", i64::MIN, "-9223372036854775808");
    itoa_case!(receipt, "itoa_boundary_i64_min_plus_1", i64::MIN + 1, "-9223372036854775807");
    itoa_case!(receipt, "itoa_boundary_i64_minus_1", -1i64, "-1");
    itoa_case!(receipt, "itoa_boundary_i64_zero", 0i64, "0");
    itoa_case!(receipt, "itoa_boundary_i64_one", 1i64, "1");
    itoa_case!(receipt, "itoa_boundary_i64_nine", 9i64, "9");
    itoa_case!(receipt, "itoa_boundary_i64_ten", 10i64, "10");
    itoa_case!(receipt, "itoa_boundary_i64_ninety_nine", 99i64, "99");
    itoa_case!(receipt, "itoa_boundary_i64_one_hundred", 100i64, "100");
    itoa_case!(receipt, "itoa_boundary_i64_max_minus_1", i64::MAX - 1, "9223372036854775806");
    itoa_case!(receipt, "itoa_boundary_i64_max", i64::MAX, "9223372036854775807");

    itoa_case!(receipt, "itoa_boundary_u64_min", u64::MIN, "0");
    itoa_case!(receipt, "itoa_boundary_u64_min_plus_1", u64::MIN + 1, "1");
    itoa_case!(receipt, "itoa_boundary_u64_nine", 9u64, "9");
    itoa_case!(receipt, "itoa_boundary_u64_ten", 10u64, "10");
    itoa_case!(receipt, "itoa_boundary_u64_ninety_nine", 99u64, "99");
    itoa_case!(receipt, "itoa_boundary_u64_one_hundred", 100u64, "100");
    itoa_case!(receipt, "itoa_boundary_u64_max_minus_1", u64::MAX - 1, "18446744073709551614");
    itoa_case!(receipt, "itoa_boundary_u64_max", u64::MAX, "18446744073709551615");

    itoa_case!(receipt, "itoa_boundary_i128_min", i128::MIN, "-170141183460469231731687303715884105728");
    itoa_case!(receipt, "itoa_boundary_i128_min_plus_1", i128::MIN + 1, "-170141183460469231731687303715884105727");
    itoa_case!(receipt, "itoa_boundary_i128_minus_1", -1i128, "-1");
    itoa_case!(receipt, "itoa_boundary_i128_zero", 0i128, "0");
    itoa_case!(receipt, "itoa_boundary_i128_one", 1i128, "1");
    itoa_case!(receipt, "itoa_boundary_i128_nine", 9i128, "9");
    itoa_case!(receipt, "itoa_boundary_i128_ten", 10i128, "10");
    itoa_case!(receipt, "itoa_boundary_i128_ninety_nine", 99i128, "99");
    itoa_case!(receipt, "itoa_boundary_i128_one_hundred", 100i128, "100");
    itoa_case!(receipt, "itoa_boundary_i128_max_minus_1", i128::MAX - 1, "170141183460469231731687303715884105726");
    itoa_case!(receipt, "itoa_boundary_i128_max", i128::MAX, "170141183460469231731687303715884105727");

    itoa_case!(receipt, "itoa_boundary_u128_min", u128::MIN, "0");
    itoa_case!(receipt, "itoa_boundary_u128_min_plus_1", u128::MIN + 1, "1");
    itoa_case!(receipt, "itoa_boundary_u128_nine", 9u128, "9");
    itoa_case!(receipt, "itoa_boundary_u128_ten", 10u128, "10");
    itoa_case!(receipt, "itoa_boundary_u128_ninety_nine", 99u128, "99");
    itoa_case!(receipt, "itoa_boundary_u128_one_hundred", 100u128, "100");
    itoa_case!(receipt, "itoa_boundary_u128_max_minus_1", u128::MAX - 1, "340282366920938463463374607431768211454");
    itoa_case!(receipt, "itoa_boundary_u128_max", u128::MAX, "340282366920938463463374607431768211455");

    // The signed and unsigned paths must agree on the shared non-negative range.
    let shared: [u128; 8] = [0, 1, 9, 10, 99, 100, u64::MAX as u128, i128::MAX as u128];
    for value in shared {
        let mut unsigned = Buffer::new();
        let unsigned_text = String::from(unsigned.format(value));
        let mut signed = Buffer::new();
        let signed_text = String::from(signed.format(value as i128));
        receipt.consistency_dec("itoa", "itoa_boundary", format!("itoa_boundary_cross_type_u{value}"), unsigned_text, signed_text);
    }

    // `Buffer` is documented as cheap to reuse; a second `format` must not
    // alias the digits of the first one.
    let mut reused = Buffer::new();
    let first = String::from(reused.format(1u32));
    receipt.vector_dec("itoa", "itoa_boundary", "itoa_boundary_buffer_reuse_first", String::from("1"), first);
    let second = String::from(reused.format(2u32));
    let mut fresh = Buffer::new();
    let clean = String::from(fresh.format(2u32));
    receipt.consistency_dec("itoa", "itoa_boundary", "itoa_boundary_buffer_reuse_second", clean, second);
}

// ── seahash 4.1.0 ──────────────────────────────────────────────────────────

/// `tests/chunking.rs` `hash_chunking_vs_not`, copied verbatim including the
/// upstream spelling.
const SEAHASH_CHUNK_1: &[u8] = b"This hashing algorithm was extracted from the Rustc compiler.";
const SEAHASH_CHUNK_2: &[u8] =
    b" This is the same hashing algoirthm used for some internal operations in FireFox.";
const SEAHASH_CHUNK_3: &[u8] = b" The strength of this algorithm is in hashing 8 bytes at a time on 64-bit platforms, where the FNV algorithm works on one byte at a time.";

/// `src/stream.rs` `chunked_equiv` / `match_optimized` buffer.
const SEAHASH_STREAM_BUFFER: [u8; 16] = [
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

fn seahash_cases(receipt: &mut Receipt) {
    let krate = "seahash";
    let group = "seahash";
    use seahash::reference;

    // `src/reference.rs` `shakespear` publishes this literal.
    receipt.vector_u64(krate, group, "seahash_vector_reference_shakespeare", 1_988_685_042_348_123_509, reference::hash(b"to be or not to be"));
    receipt.consistency_u64(krate, group, "seahash_consistency_buffer_vs_reference_shakespeare", reference::hash(b"to be or not to be"), seahash::hash(b"to be or not to be"));
    receipt.consistency_u64(krate, group, "seahash_consistency_buffer_vs_reference_love", reference::hash(b"love is a wonderful terrible thing"), seahash::hash(b"love is a wonderful terrible thing"));

    // `tests/chunking.rs` publishes `hash1 == 0xa06e72e1b06144a0` for the three
    // chunks written separately; the concatenation must agree with all paths.
    let mut concatenated = Vec::new();
    concatenated.extend_from_slice(SEAHASH_CHUNK_1);
    concatenated.extend_from_slice(SEAHASH_CHUNK_2);
    concatenated.extend_from_slice(SEAHASH_CHUNK_3);

    let mut stream = SeaHasher::default();
    stream.write(SEAHASH_CHUNK_1);
    stream.write(SEAHASH_CHUNK_2);
    stream.write(SEAHASH_CHUNK_3);
    receipt.vector_u64(krate, group, "seahash_vector_stream_three_chunks", 0xa06e_72e1_b061_44a0, stream.finish());
    receipt.consistency_u64(krate, group, "seahash_consistency_buffer_vs_reference_chunking", reference::hash(&concatenated), seahash::hash(&concatenated));
    receipt.consistency_u64(krate, group, "seahash_consistency_stream_vs_buffer_chunking", seahash::hash(&concatenated), stream.finish());

    // `tests/chunking.rs` `test_different_chunk_sizes`.
    let mut whole = SeaHasher::default();
    whole.write(&concatenated);
    let whole_digest = whole.finish();
    for chunk in [1usize, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64, 127] {
        let mut partial = SeaHasher::default();
        for slice in concatenated.chunks(chunk) {
            partial.write(slice);
        }
        receipt.consistency_u64(krate, group, format!("seahash_consistency_stream_chunk_{chunk:03}"), whole_digest, partial.finish());
    }

    // `src/buffer.rs` `hash_match`: the optimized and readable implementations
    // must agree for the default key and for every key set upstream exercises.
    let mut sequential = [0u8; 4096];
    for (index, byte) in sequential.iter_mut().enumerate() {
        *byte = index as u8;
    }
    let mut concat16 = Vec::new();
    concat16.extend_from_slice(SEAHASH_CHUNK_1);
    concat16.extend_from_slice(SEAHASH_CHUNK_2);
    // Named locals, not temporaries: the table outlives the statement that a
    // `&filled(..)` inside the array literal would have created.
    let zeroes_8 = filled(8, 0);
    let zeroes_65 = filled(65, 0);
    let payloads: [(&str, &[u8]); 6] = [
        ("empty", b""),
        ("zeros_8", &zeroes_8),
        ("zeros_65", &zeroes_65),
        ("sequential_4096", &sequential),
        ("stream_buffer", &SEAHASH_STREAM_BUFFER),
        ("chunks_1_2", &concat16),
    ];
    let key_sets: [(&str, [u64; 4]); 6] = [
        ("default", [0x16f1_1fe8_9b0d_677c, 0xb480_a793_d8e6_c86c, 0x6fe2_e5aa_f078_ebc9, 0x14f9_94a4_c525_9381]),
        ("ones", [1, 1, 1, 1]),
        ("mixed", [500, 2873, 2389, 9283]),
        ("wide", [238_945_723_984, 872_894_734, 239_478_243, 28_937_498_234]),
        ("max", [u64::MAX, u64::MAX, u64::MAX, u64::MAX]),
        ("zeros", [0, 0, 0, 0]),
    ];
    for (payload_name, payload) in payloads.iter() {
        receipt.consistency_u64(krate, group, format!("seahash_consistency_buffer_vs_reference_default_{payload_name}"), reference::hash(payload), seahash::hash(payload));
        for (key_name, keys) in key_sets.iter() {
            receipt.consistency_u64(krate, group, format!("seahash_consistency_seeded_{key_name}_{payload_name}"), reference::hash_seeded(payload, keys[0], keys[1], keys[2], keys[3]), seahash::hash_seeded(payload, keys[0], keys[1], keys[2], keys[3]));
        }
    }

    // `src/stream.rs` `match_optimized`, with upstream's key set.
    let mut seeded_stream = SeaHasher::with_seeds(0xe7b0_c93c_a852_5013, 0x011d_02b8_54ae_8182, 0x7bcc_5cf9_c39c_ec76, 0xfa33_6285_d102_d083);
    seeded_stream.write(&SEAHASH_STREAM_BUFFER);
    receipt.consistency_u64(krate, group, "seahash_consistency_seeded_stream_vs_buffer", seahash::hash_seeded(&SEAHASH_STREAM_BUFFER, 0xe7b0_c93c_a852_5013, 0x011d_02b8_54ae_8182, 0x7bcc_5cf9_c39c_ec76, 0xfa33_6285_d102_d083), seeded_stream.finish());

    // `src/buffer.rs` `push` / `pop`.
    let mut pushed = seahash::State::new(1, 2, 3, 4);
    pushed.push(u64::MAX);
    pushed.push(0);
    receipt.consistency_u64(krate, group, "seahash_consistency_state_push", seahash::hash_seeded(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0], 1, 2, 3, 4), pushed.finalize());

    let mut popped = seahash::State::new(1, 2, 3, 4);
    popped.push(u64::MAX);
    popped.push(0);
    popped.pop(0);
    receipt.consistency_u64(krate, group, "seahash_consistency_state_pop", seahash::hash_seeded(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], 1, 2, 3, 4), popped.finalize());

    // `src/buffer.rs` `zero_sensitive`, `not_equal` and `position_depedent`:
    // these inputs must not collide.
    let distinct_pairs: [(&str, &[u8], &[u8]); 8] = [
        ("trailing_space", b"to be or not to be ", b"to be or not to be"),
        ("jkjke", b"jkjke", b"jkjk"),
        ("prefix_shift", b"ijkjke", b"ijkjk"),
        ("four_prefix_shift", b"iijkjke", b"iijkjk"),
        ("eight_prefix_shift", b"iiiiijkjke", b"iiiiijkjk"),
        ("ab_vs_bb", b"ab", b"bb"),
        ("leading_zero", &[1, 2, 3, 4], &[1, 0, 2, 3, 4]),
        ("length_growth", &[0, 0, 0], &[0, 0, 0, 0, 0]),
    ];
    for (name, left, right) in distinct_pairs.iter() {
        receipt.distinct_u64(krate, group, format!("seahash_distinct_{name}"), seahash::hash(left), seahash::hash(right));
    }

    // The two promoted hash crates must not alias: same input, same key words.
    let (k0, k1) = SIP_KEY;
    receipt.distinct_u64(krate, group, "seahash_distinct_vs_siphasher24", seahash::hash_seeded(&concatenated, k0, k1, k0, k1), SipHasher24::new_with_keys(k0, k1).hash(&concatenated));
}

// ── atoi 2.0.0 ─────────────────────────────────────────────────────────────

/// Rows every integer type shares. `checked` is the `(Option<T>, usize)` trait
/// rendering; `parsed` is the `atoi::<T>()` free function, which maps
/// `(_, 0)` and `(_, None)` to `None` and reports no index.
fn atoi_shared_rows<T>(
    receipt: &mut Receipt,
    type_name: &str,
    negative_checked: &str,
    negative_parsed: &str,
) where
    T: FromRadix10 + FromRadix10Checked + FromRadix10Signed + FromRadix10SignedChecked
        + FromRadix16 + FromRadix16Checked + std::fmt::Display + Copy,
{
    let rows: [(&str, &[u8], &str, &str); 10] = [
        ("empty", b"", "some:0:0", "none"),
        ("lone_plus", b"+", "some:0:1", "some:0"),
        ("lone_minus", b"-", "some:0:1", "some:0"),
        ("zero", b"0", "some:0:1", "some:0"),
        ("minus_zero", b"-0", "some:0:2", "some:0"),
        ("plus_zero", b"+0", "some:0:2", "some:0"),
        ("leading_space", b" 42", "some:0:0", "none"),
        ("digits_then_text", b"42abc", "some:42:2", "some:42"),
        ("leading_zeros", b"0042", "some:42:4", "some:42"),
        ("negative", b"-42", negative_checked, negative_parsed),
    ];
    for (slug, input, checked, parsed) in rows {
        let prefix = format!("atoi_boundary_{type_name}_{slug}");
        receipt.record("atoi", "itoa_boundary", format!("{prefix}_checked"), Kind::Vector, "atoi", String::from(checked), atoi_checked_rendering(T::from_radix_10_signed_checked(input)));
        receipt.record("atoi", "itoa_boundary", format!("{prefix}_atoi"), Kind::Vector, "optdec", String::from(parsed), atoi_opt_rendering(atoi::<T>(input)));
    }
}

macro_rules! atoi_plain_case {
    ($receipt:ident, $name:expr, $ty:ty, $text:expr, $method:ident, $expected:expr) => {{
        let (value, used) = <$ty>::$method($text);
        $receipt.record("atoi", "itoa_boundary", $name, Kind::Vector, "atoi", String::from($expected), atoi_plain_rendering((value, used)));
    }};
}

macro_rules! atoi_checked_case {
    ($receipt:ident, $name:expr, $ty:ty, $text:expr, $method:ident, $expected:expr) => {{
        let (value, used) = <$ty>::$method($text);
        $receipt.record("atoi", "itoa_boundary", $name, Kind::Vector, "atoi", String::from($expected), atoi_checked_rendering((value, used)));
    }};
}

macro_rules! atoi_parsed_case {
    ($receipt:ident, $name:expr, $ty:ty, $text:expr, $expected:expr) => {{
        let value = atoi::<$ty>($text);
        $receipt.record("atoi", "itoa_boundary", $name, Kind::Vector, "optdec", String::from($expected), atoi_opt_rendering(value));
    }};
}

fn atoi_cases(receipt: &mut Receipt) {
    atoi_shared_rows::<u8>(receipt, "u8", "none:3", "none");
    atoi_shared_rows::<i8>(receipt, "i8", "some:-42:3", "some:-42");
    atoi_shared_rows::<u32>(receipt, "u32", "none:3", "none");
    atoi_shared_rows::<i32>(receipt, "i32", "some:-42:3", "some:-42");
    atoi_shared_rows::<u64>(receipt, "u64", "none:3", "none");
    atoi_shared_rows::<i64>(receipt, "i64", "some:-42:3", "some:-42");

    // Overflow, underflow and the exact boundary on either side of it.
    atoi_checked_case!(receipt, "atoi_boundary_u8_overflow_max", u8, b"255", from_radix_10_signed_checked, "some:255:3");
    atoi_checked_case!(receipt, "atoi_boundary_u8_overflow_256", u8, b"256", from_radix_10_signed_checked, "none:3");
    atoi_checked_case!(receipt, "atoi_boundary_u8_overflow_1000", u8, b"1000", from_radix_10_signed_checked, "none:4");
    atoi_checked_case!(receipt, "atoi_boundary_i8_positive_max", i8, b"+127", from_radix_10_signed_checked, "some:127:4");
    atoi_checked_case!(receipt, "atoi_boundary_i8_positive_overflow", i8, b"+128", from_radix_10_signed_checked, "none:4");
    atoi_checked_case!(receipt, "atoi_boundary_i8_negative_max", i8, b"-128", from_radix_10_signed_checked, "some:-128:4");
    atoi_checked_case!(receipt, "atoi_boundary_i8_negative_underflow", i8, b"-129", from_radix_10_signed_checked, "none:4");
    atoi_checked_case!(receipt, "atoi_boundary_u32_max", u32, b"4294967295", from_radix_10_signed_checked, "some:4294967295:10");
    atoi_checked_case!(receipt, "atoi_boundary_u32_overflow", u32, b"4294967296", from_radix_10_signed_checked, "none:10");
    atoi_checked_case!(receipt, "atoi_boundary_i32_max", i32, b"2147483647", from_radix_10_signed_checked, "some:2147483647:10");
    atoi_checked_case!(receipt, "atoi_boundary_i32_min", i32, b"-2147483648", from_radix_10_signed_checked, "some:-2147483648:11");
    atoi_checked_case!(receipt, "atoi_boundary_i32_underflow", i32, b"-2147483649", from_radix_10_signed_checked, "none:11");
    atoi_checked_case!(receipt, "atoi_boundary_u64_max", u64, b"18446744073709551615", from_radix_10_signed_checked, "some:18446744073709551615:20");
    atoi_checked_case!(receipt, "atoi_boundary_u64_overflow", u64, b"18446744073709551616", from_radix_10_signed_checked, "none:20");
    atoi_checked_case!(receipt, "atoi_boundary_i64_max", i64, b"9223372036854775807", from_radix_10_signed_checked, "some:9223372036854775807:19");
    atoi_checked_case!(receipt, "atoi_boundary_i64_min", i64, b"-9223372036854775808", from_radix_10_signed_checked, "some:-9223372036854775808:20");
    atoi_checked_case!(receipt, "atoi_boundary_i64_underflow", i64, b"-9223372036854775809", from_radix_10_signed_checked, "none:20");
    atoi_checked_case!(receipt, "atoi_boundary_u128_max", u128, b"340282366920938463463374607431768211455", from_radix_10_signed_checked, "some:340282366920938463463374607431768211455:39");
    atoi_checked_case!(receipt, "atoi_boundary_u128_overflow", u128, b"340282366920938463463374607431768211456", from_radix_10_signed_checked, "none:39");
    atoi_checked_case!(receipt, "atoi_boundary_i128_max", i128, b"170141183460469231731687303715884105727", from_radix_10_signed_checked, "some:170141183460469231731687303715884105727:39");
    atoi_checked_case!(receipt, "atoi_boundary_i128_min", i128, b"-170141183460469231731687303715884105728", from_radix_10_signed_checked, "some:-170141183460469231731687303715884105728:40");
    atoi_checked_case!(receipt, "atoi_boundary_i128_underflow", i128, b"-170141183460469231731687303715884105729", from_radix_10_signed_checked, "none:40");

    // The free function returns `None` for exactly the same inputs.
    atoi_parsed_case!(receipt, "atoi_boundary_u8_overflow_256_atoi", u8, b"256", "none");
    atoi_parsed_case!(receipt, "atoi_boundary_i8_negative_underflow_atoi", i8, b"-129", "none");
    atoi_parsed_case!(receipt, "atoi_boundary_u32_overflow_atoi", u32, b"4294967296", "none");
    atoi_parsed_case!(receipt, "atoi_boundary_i64_min_atoi", i64, b"-9223372036854775808", "some:-9223372036854775808");
    atoi_parsed_case!(receipt, "atoi_boundary_i128_min_atoi", i128, b"-170141183460469231731687303715884105728", "some:-170141183460469231731687303715884105728");
    atoi_parsed_case!(receipt, "atoi_boundary_u128_max_atoi", u128, b"340282366920938463463374607431768211455", "some:340282366920938463463374607431768211455");

    // `FromRadix10`: signs are rejected even for signed types, and a leading
    // non-digit yields `(0, 0)`.
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_u32_42", u32, b"42", from_radix_10, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_u32_trailing_text", u32, b"42 is the answer to life, the universe and everything", from_radix_10, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_u32_non_digit", u32, b"Sadly we do not know the question", from_radix_10, "some:0:0");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_i32_42", i32, b"42", from_radix_10, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_i32_minus_42", i32, b"-42", from_radix_10, "some:0:0");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_u32_leading_zeros", u32, b"0042", from_radix_10, "some:42:4");

    // `FromRadix10Checked`.
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_u32_42", u32, b"42", from_radix_10_checked, "some:42:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_u32_trailing_text", u32, b"42 is the answer to life, the universe and everything", from_radix_10_checked, "some:42:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_u32_non_digit", u32, b"Sadly we do not know the question", from_radix_10_checked, "some:0:0");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_i32_42", i32, b"42", from_radix_10_checked, "some:42:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_i32_minus_42", i32, b"-42", from_radix_10_checked, "some:0:0");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_u32_leading_zeros", u32, b"0042", from_radix_10_checked, "some:42:4");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_10_checked_u8_overflow", u8, b"256", from_radix_10_checked, "none:3");

    // `FromRadix16` and `FromRadix16Checked`.
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_u32_2a", u32, b"2a", from_radix_16, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_u32_trailing_text", u32, b"2a is the answer to life, the universe and everything", from_radix_16, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_u32_non_digit", u32, b"Sadly we do not know the question", from_radix_16, "some:0:0");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_i32_2a", i32, b"2a", from_radix_16, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_i32_minus_2a", i32, b"-2a", from_radix_16, "some:0:0");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_u32_leading_zeros", u32, b"002a", from_radix_16, "some:42:4");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_16_u32_uppercase", u32, b"002A", from_radix_16, "some:42:4");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u32_2a", u32, b"2a", from_radix_16_checked, "some:42:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u8_ff", u8, b"FF", from_radix_16_checked, "some:255:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u8_overflow_100", u8, b"100", from_radix_16_checked, "none:3");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u8_overflow_1000", u8, b"1000", from_radix_16_checked, "none:4");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u8_19", u8, b"19", from_radix_16_checked, "some:25:2");
    atoi_checked_case!(receipt, "atoi_boundary_from_radix_16_checked_u8_trailing_text", u8, b"19!Blub", from_radix_16_checked, "some:25:2");

    // `FromRadix10Signed` (unchecked) and `src/lib.rs` `checked_parsing`.
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_signed_i32_42", i32, b"42", from_radix_10_signed, "some:42:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_signed_i32_minus_42", i32, b"-42", from_radix_10_signed, "some:-42:3");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_signed_i32_plus_42", i32, b"+42", from_radix_10_signed, "some:42:3");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_signed_u32_minus_0", u32, b"-0", from_radix_10_signed, "some:0:2");
    atoi_plain_case!(receipt, "atoi_boundary_from_radix_10_signed_i32_leading_zeros", i32, b"0042", from_radix_10_signed, "some:42:4");
    atoi_checked_case!(receipt, "atoi_boundary_checked_parsing_u8_25", u8, b"25", from_radix_10_checked, "some:25:2");
    atoi_checked_case!(receipt, "atoi_boundary_checked_parsing_u8_25_trailing", u8, b"25Blub", from_radix_10_checked, "some:25:2");

    // `MaxNumDigits`, the digit budgets the checked parsers derive from.
    let digit_rows: [(&str, usize); 12] = [
        ("i32_max_num_digits", i32::max_num_digits(10)),
        ("u32_max_num_digits", u32::max_num_digits(10)),
        ("i64_max_num_digits", i64::max_num_digits(10)),
        ("u64_max_num_digits", u64::max_num_digits(10)),
        ("u8_max_num_digits", u8::max_num_digits(10)),
        ("i8_max_num_digits", i8::max_num_digits(10)),
        ("i32_max_num_digits_negative", i32::max_num_digits_negative(10)),
        ("u32_max_num_digits_negative", u32::max_num_digits_negative(10)),
        ("i64_max_num_digits_negative", i64::max_num_digits_negative(10)),
        ("u64_max_num_digits_negative", u64::max_num_digits_negative(10)),
        ("u8_max_num_digits_negative", u8::max_num_digits_negative(10)),
        ("i8_max_num_digits_negative", i8::max_num_digits_negative(10)),
    ];
    let digit_expected: [usize; 12] = [10, 10, 19, 20, 3, 3, 10, 0, 19, 0, 0, 3];
    for (index, (name, actual)) in digit_rows.iter().enumerate() {
        receipt.vector_dec("atoi", "itoa_boundary", format!("atoi_boundary_{name}"), digit_expected[index].to_string(), actual.to_string());
    }

    // `ascii_to_digit`.
    for digit in b'0'..=b'9' {
        let name = format!("atoi_boundary_ascii_to_digit_{digit}");
        receipt.record("atoi", "itoa_boundary", name, Kind::Vector, "optdec", format!("some:{}", digit - b'0'), atoi_opt_rendering(ascii_to_digit::<u32>(digit)));
    }
    for byte in [b'x', b' ', b'+', b'-', 0x00, 0xff] {
        let name = format!("atoi_boundary_ascii_to_non_digit_{byte:02x}");
        receipt.record("atoi", "itoa_boundary", name, Kind::Vector, "optdec", String::from("none"), atoi_opt_rendering(ascii_to_digit::<u32>(byte)));
    }

    // `Sign::try_from`.
    for (name, byte, expected) in [("plus", b'+', "Some(Plus)"), ("minus", b'-', "Some(Minus)"), ("digit", b'1', "None")] {
        receipt.vector_text("atoi", "itoa_boundary", format!("atoi_boundary_sign_try_from_{name}"), expected, &format!("{:?}", Sign::try_from(byte)));
    }
}

// ── entry point ────────────────────────────────────────────────────────────

const USAGE: &str = "\
rust-corpus-oracle --output <absolute-path>

Runs every corpus case for the seven promoted crates and prints the receipt on
stdout. With --output the identical bytes are also written to that path, which
must be absolute, must not exist yet, and must have an existing parent
directory.

Exit status: 0 all cases passed, 1 a case failed, 2 usage or I/O error.
";

fn main() -> ExitCode {
    let mut output: Option<PathBuf> = None;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--output" => {
                index += 1;
                let Some(value) = args.get(index) else {
                    eprint!("{USAGE}");
                    return ExitCode::from(2);
                };
                output = Some(PathBuf::from(value));
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("rust-corpus-oracle: unexpected argument {other:?}");
                eprint!("{USAGE}");
                return ExitCode::from(2);
            }
        }
        index += 1;
    }

    if let Some(path) = &output {
        if let Err(reason) = check_output_path(path) {
            eprintln!("rust-corpus-oracle: {reason}");
            return ExitCode::from(2);
        }
    }

    let mut receipt = Receipt::new();
    wyhash_cases(&mut receipt);
    adler_cases(&mut receipt);
    xxhash_cases(&mut receipt);
    siphasher_cases(&mut receipt);
    itoa_cases(&mut receipt);
    seahash_cases(&mut receipt);
    atoi_cases(&mut receipt);

    let config = if cfg!(feature = "xxh32") { "xxh32" } else { "default-features" };
    let rendered = receipt.render(config);
    if let Some(path) = &output {
        if let Err(error) = write_receipt(path, &rendered) {
            eprintln!("rust-corpus-oracle: cannot write {}: {error}", path.display());
            return ExitCode::from(2);
        }
    }
    print!("{rendered}");

    let failed = receipt.failed();
    eprintln!(
        "rust-corpus-oracle: config={config} total={} passed={} failed={failed}",
        receipt.cases.len(),
        receipt.passed()
    );
    for case in receipt.cases.iter().filter(|case| !case.pass) {
        eprintln!(
            "rust-corpus-oracle: FAIL {} {} {} kind={} expected={} actual={}",
            case.krate, case.group, case.name, case.kind.as_str(), case.expected, case.actual
        );
    }
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn check_output_path(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err(format!("--output must be an absolute path, got {}", path.display()));
    }
    if path.exists() || path.symlink_metadata().is_ok() {
        return Err(format!("refusing to overwrite existing path {}", path.display()));
    }
    match path.parent() {
        Some(parent) if parent.is_dir() => Ok(()),
        Some(parent) => Err(format!("parent directory {} does not exist", parent.display())),
        None => Err(format!("{} has no parent directory", path.display())),
    }
}

fn write_receipt(path: &Path, contents: &str) -> std::io::Result<()> {
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()
}
