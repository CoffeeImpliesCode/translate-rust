//! Nested out-of-line module containing its own child `mod bar;`, proving
//! discovery recurses into submodule files.

mod bar;

pub fn foo_fn() -> u32 {
    bar::bar_fn()
}