// Minimal crate-shaped Rust for translate-rust's syntax front-end.
// Fed to tree-sitter-rust during smoke tests (see src/rust.zig).

pub struct Point {
    pub x: i32,
    pub y: i32,
}

pub enum Shape {
    Circle(f64),
    Rect {
        width: f64,
        height: f64,
    },
}

impl Point {
    pub fn new(x: i32, y: i32) -> Point {
        Point { x, y }
    }

    pub fn translate(&mut self, dx: i32, dy: i32) {
        self.x += dx;
        self.y += dy;
    }
}

pub fn area(shape: Shape) -> f64 {
    match shape {
        Shape::Circle(r) => r * r * 3.14159,
        Shape::Rect { width, height } => width * height,
    }
}
