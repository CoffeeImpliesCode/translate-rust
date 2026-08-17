//! mini — a tiny no_std crate exercising the v1 model surface.
//! translate-rust P1 fixture: file-split module, struct, data-carrying enum,
//! fn + match, and a `pub use` re-export.

#![no_std]

pub mod util;

pub struct Point {
    pub x: i32,
    pub y: i32,
}

pub enum Shape {
    Circle(f64),
    Rect { width: f64, height: f64 },
}

pub fn area(shape: Shape) -> f64 {
    match shape {
        Shape::Circle(r) => r * r * 3.14159,
        Shape::Rect { width, height } => width * height,
    }
}

pub fn origin() -> Point {
    Point { x: 0, y: 0 }
}

pub use util::helper;
