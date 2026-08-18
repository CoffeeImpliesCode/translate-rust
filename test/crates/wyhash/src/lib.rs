//! Rust implementation of the [wyhash algorithm by Wang Yi][original].
//!
//! The hashing algorithm passes SMHasher and the random number generator
//! passes BigCrush and practrand.
//! As of now it is the fastest algorithm in the SMHasher benchmark
//! (faster than t1ha and XXH3).
//! See [here][original].
//!
//! Furthermore, this algorithm is solid, simple, portable (does not need
//! hardware support, can be used in `no_std` environments) and has
//! no dependencies.
//!
//! The generated hashes are equal (see tests) as of the version stated
//! [here][original-version] although the speed varies
//! ([PRs are welcome][issue-tracker]).
//!
//! [issue-tracker]: https://github.com/eldruin/wyhash-rs/issues
//! [original]: https://github.com/wangyi-fudan/wyhash
//! [original-version]: https://github.com/eldruin/wyhash-rs/blob/master/original/CMakeLists.txt
//!
//! ## Usage (see also examples folder)
//!
//! For the hashing function you can use the free function:
//!
//! ```
//! use wyhash::wyhash;
//!
//! let data = [0, 1, 2];
//! let seed = 3;
//! let hash = wyhash(&data, seed);
//!
//! assert_eq!(0xb0f9_4152_0b1a_d95d, hash);
//! ```
//!
//! ### `wyrng` function usage
//!
//! Note that the seed parameter is updated so that it is possible to
//! generate a sequence of random numbers.
//!
//! ```
//! use wyhash::wyrng;
//!
//! let mut seed = 3;
//! let random_number = wyrng(&mut seed);
//!
//! assert_eq!(0x3e9_9a77_2750_dcbe, random_number);
//! assert_eq!(0xa0761d6478bd6432, seed);
//! ```

#![no_std]
#![deny(missing_docs, unsafe_code)]

mod functions;
pub use crate::functions::{wyhash, wyrng};