# Third-Party Notices

The project's first-party code is licensed under MIT; see [LICENSE](LICENSE). The vendored components below keep their own licenses and notices.

| Component | Included paths | License | Copyright holder / notice | Upstream |
| --- | --- | --- | --- | --- |
| tree-sitter-rust 0.24.2 | `vendor/tree-sitter-rust/` | MIT | Maxim Sokolov (`LICENSE`) | https://github.com/tree-sitter/tree-sitter-rust |
| adler 1.0.2 | `test/crates/adler/` | 0BSD OR MIT OR Apache-2.0 | Jonas Schievink (`LICENSE-0BSD`) | https://github.com/jonas-schievink/adler.git |
| atoi 2.0.0 | `test/crates/atoi/` | MIT | Copyright holder not named in `LICENSE` (blank field); Cargo author: Markus Klein | https://github.com/pacman82/atoi-rs |
| crc16 0.4.0 | `test/crates/crc16/` | MIT in Cargo metadata; README also says MIT OR Apache-2.0 | Anatoly Ikorsky (`LICENSE-MIT`) | https://github.com/blackbeam/rust-crc16 |
| fletcher source snapshot (upstream 1.0.0; local fixture manifest 1.1.4) | `test/crates/fletcher/` | MIT | Copyright holder not named in upstream `LICENSE` (blank field); upstream author: Joseph Angelo | https://github.com/jbangelo/fletcher/tree/2d941b4c26061fd3b057485723d4df92315a757d |
| fnv 1.0.7 | `test/crates/fnv/` | Apache-2.0 OR MIT (MIT text restored as `LICENSE-MIT`) | Contributors (2017; `LICENSE-MIT`) | https://github.com/servo/rust-fnv |
| hex 0.4.3 | `test/crates/hex/` | MIT OR Apache-2.0 (MIT text restored as `LICENSE-MIT`) | The Rust Project Developers; The rust-hex Developers (`src/lib.rs`, `LICENSE-MIT`) | https://github.com/KokaKiwi/rust-hex |
| itoa 1.0.11 | `test/crates/itoa/` | MIT OR Apache-2.0 | Holder not named in the included license files; Cargo author: David Tolnay | https://github.com/dtolnay/itoa |
| leb128 0.2.5 | `test/crates/leb128/` | Apache-2.0 OR MIT | The Rust Project Developers (`LICENSE-MIT`) | https://github.com/gimli-rs/leb128 |
| percent-encoding 2.3.1 | `test/crates/percent-encoding/` | MIT OR Apache-2.0 | The rust-url developers (`LICENSE-MIT`) | https://github.com/servo/rust-url/ |
| seahash 4.1.0 | `test/crates/seahash/` | MIT | Holder not stated in upstream `LICENSE`; Cargo authors: ticki and Tom Almeida | https://gitlab.redox-os.org/redox-os/seahash |
| siphasher 1.0.1 | `test/crates/siphasher/` | MIT OR Apache-2.0 (MIT text restored as `LICENSE-MIT`) | The Rust Project Developers (2012-2016); Frank Denis (2016-2024; `COPYING`) | https://github.com/jedisct1/rust-siphash |
| syn 2.0.98 | `test/crates/syn/` | MIT OR Apache-2.0 | Holder not named in the included license files; Cargo author: David Tolnay | https://github.com/dtolnay/syn |
| wyhash 0.4.0 | `test/crates/wyhash/` | MIT OR Apache-2.0 (`LICENSE-APACHE` retained; MIT text restored as `LICENSE-MIT`) | Diego Barrios Romero (`LICENSE-MIT`) | https://github.com/eldruin/wyhash-rs |
| xxhash-rust 0.8.15 | `test/crates/xxhash-rust/` | BSL-1.0 | Holder not named in `LICENSE`; Cargo author: Douman | https://github.com/DoumanAsh/xxhash-rust |

Each listed fixture retains its per-component license files. The omitted MIT texts for fletcher, fnv, hex, seahash, siphasher, and wyhash are now present in their respective fixture directories. For dual-licensed fixtures, the MIT option is used where a missing license text had to be restored; existing third-party license files and source headers are unchanged.
