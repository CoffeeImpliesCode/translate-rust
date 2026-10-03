//! Nested out-of-line module containing its own child `mod bar;`, proving
//! discovery recurses into submodule files.

mod bar;

pub fn foo_fn() -> u32 {
    bar::bar_fn()
}

#[cfg(test)]
mod tests {
    #[test]
    fn foo_fn_delegates_to_bar_fn() {
        // `bar` is a private child module of `foo`, so a descendant names it
        // and nothing outside the crate does — the same privacy the emitted
        // root keeps with `const foo = @import("./foo.zig");`. This is the
        // only place `foo_fn` can be reached, because nothing on the public
        // surface calls it.
        assert_eq!(super::bar::bar_fn(), super::foo_fn());
        assert_eq!(7, super::foo_fn());
    }
}