//! Multifile module-discovery fixture: one out-of-line module (`mod foo;`),
//! one nested two-level module (`mod foo;` -> `mod bar;`), and one module
//! declared through a `#[path = "..."]` attribute. Used by the frontend
//! pipeline test to prove submodule files are found and ingested recursively.

mod foo;
#[path = "custom.rs"]
pub mod custom_pub;

pub fn enter() -> u32 {
    42
}