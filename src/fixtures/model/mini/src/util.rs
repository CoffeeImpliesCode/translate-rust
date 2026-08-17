//! A tiny submodule to exercise file-split modules and re-exports.

pub fn helper(v: u8) -> u8 {
    v.wrapping_add(1)
}
