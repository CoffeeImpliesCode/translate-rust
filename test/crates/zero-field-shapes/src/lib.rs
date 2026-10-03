//! Zero-field container fixture: the three ways a Rust struct can hold no
//! field, and an enum whose variants all hold no field.
//!
//! `struct Unit;` declares no field list at all, `struct Record {}` declares
//! an empty one, and `struct Tuple();` declares an ordered field list holding
//! nothing. All three are separate nominal types, so all three have to reach
//! Zig under their own name, be constructible on their own, and survive a
//! parameter type and a return type without any of them collapsing into
//! another. Nothing here holds data, so size cannot tell them apart and only
//! the nominal identity can; `Choice` is the control that proves the size
//! assertion is about emptiness rather than about a shared erased shape.
//!
//! The crate publishes values and types and asserts nothing about how they
//! are checked. Every claim below is read back out of the staged package by
//! `test/zero_field_shapes_consumer.zig`, which uses Zig reflection on the
//! declarations the translation produced.

/// `struct Unit;`: no field list at all.
pub struct Unit;

/// `struct Record {}`: an empty named field list.
pub struct Record {}

/// `struct Tuple();`: an ordered field list holding nothing.
pub struct Tuple();

/// A fieldless enum: every variant is a unit variant, so nothing here carries
/// a payload either. Unlike the three structs above it is inhabited, which is
/// what keeps "size zero" from being satisfied by any empty type at all.
pub enum Choice {
    Left,
    Right,
}

/// Builds the `Unit` nominal.
pub fn unit_value() -> Unit {
    Unit
}

/// Builds the `Record` nominal.
pub fn record_value() -> Record {
    Record
}

/// Builds the `Tuple` nominal.
pub fn tuple_value() -> Tuple {
    Tuple
}

/// `Unit` as a parameter type and as a return type.
pub fn unit_round_trip(value: Unit) -> Unit {
    value
}

/// `Record` as a parameter type and as a return type.
pub fn record_round_trip(value: Record) -> Record {
    value
}

/// `Tuple` as a parameter type and as a return type.
pub fn tuple_round_trip(value: Tuple) -> Tuple {
    value
}

/// Builds the first `Choice` variant.
pub fn left_value() -> Choice {
    Choice::Left
}

/// `Choice` as a parameter type and as a return type.
pub fn choice_round_trip(choice: Choice) -> Choice {
    choice
}

/// All four nominals as parameter types of one call. The three structs hold no
/// data and cannot be read, so the enum decides the answer; the point of the
/// signature is that four arguments of four different nominal types were
/// accepted at all, and the consumer compares the number this returns against
/// the one the enum says it must be.
pub fn shape_code(unit: Unit, record: Record, tuple: Tuple, choice: Choice) -> u8 {
    match choice {
        Choice::Left => 10,
        Choice::Right => 20,
    }
}
