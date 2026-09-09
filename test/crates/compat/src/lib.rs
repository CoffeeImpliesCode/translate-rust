pub fn cast(value: u32) -> u8 {
    value as u8
}
pub fn digit(value: char) -> Option<u32> {
    value.to_digit(16)
}
pub fn narrow(value: u16) -> Option<u8> {
    u8::try_from(value).ok()
}
#[test]
fn numeric_check() {
    assert_eq!(cast(511), 255);
    assert_eq!(digit('f'), Some(15));
    assert_eq!(narrow(255), Some(255));
    assert_eq!(narrow(256), None);
}

pub fn root_value() -> u32 {
    5
}

pub mod support {
    pub struct ParentValue {
        pub value: u32,
    }

    impl ParentValue {
        pub fn make() -> Self {
            Self { value: 11 }
        }
    }

    pub fn parent_value() -> u32 {
        3
    }

    pub mod child {
        pub fn total() -> u32 {
            let explicit = super::ParentValue { value: 7 };
            let constructed = super::ParentValue::make();
            explicit.value + constructed.value + super::parent_value() + crate::root_value()
        }
    }
}

#[test]
fn module_reference_check() {
    assert_eq!(support::child::total(), 26);
}

pub fn width() -> usize {
    core::mem::size_of::<u32>()
}
pub fn bits(value: f32) -> u32 {
    unsafe { core::mem::transmute::<f32, u32>(value) }
}
pub fn bits_callable(value: f32) -> u32 {
    let convert = core::mem::transmute::<f32, u32>;
    unsafe { convert(value) }
}
pub fn pointer_cast(value: *const u8) -> *mut u8 {
    value as *mut u8
}
#[test]
fn memory_check() {
    assert_eq!(width(), 4);
    assert_eq!(bits(1.0), 1065353216);
    assert_eq!(bits_callable(1.0), 1065353216);
}

pub fn render(f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
    write!(f, "value={} {:?}", 42u32, '\n')
}

pub fn owned(input: &str) -> String {
    String::from(input)
}
pub fn lossy(input: &[u8]) -> std::borrow::Cow<'_, str> {
    String::from_utf8_lossy(input)
}
pub fn borrowed_bytes(input: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    std::borrow::Cow::Borrowed(input)
}

pub fn sum(input: &[u32]) -> u32 {
    input
        .iter()
        .copied()
        .map(|x| x * 2)
        .filter(|x| *x > 4)
        .sum()
}
#[test]
fn iterator_check() {
    assert_eq!(sum(&[1, 2, 3, 4]), 14);
}

pub fn generic_narrow<T: core::convert::TryInto<u8>>(value: T) -> Option<u8> {
    value.try_into().ok()
}
#[test]
fn generic_check() {
    assert_eq!(generic_narrow(255u16), Some(255));
    assert_eq!(generic_narrow(256u16), None);
}

pub fn byte_sum(input: &[u8]) -> u32 {
    let mut sum = 0u32;
    for &byte in input {
        sum += u32::from(byte);
    }
    sum
}

#[test]
fn slice_value_check() {
    assert_eq!(byte_sum(&[1, 127, 255]), 383);
    assert_eq!(byte_sum(&[]), 0);
}

pub fn collected(input: &[u32]) -> Vec<u32> {
    input
        .iter()
        .copied()
        .map(|x| x * 2)
        .filter(|x| *x > 4)
        .collect()
}

pub fn owner(owner: &[u8]) -> Vec<u8> {
    (0..2).flat_map(|_| owner.iter().cloned()).collect()
}

pub fn flattened() -> Vec<u32> {
    (0u32..3).flat_map(|x| x..x + 2).collect()
}

pub fn stateful_flattened() -> Vec<u32> {
    let mut end = 0u32;
    (0u32..3)
        .flat_map(move |x| {
            end += 1;
            x..end
        })
        .collect()
}

pub fn reversed(end: u32) -> Vec<u32> {
    (0..end).rev().collect()
}

pub fn signed_flattened() -> Vec<i32> {
    (-1i32..1).flat_map(|x| x..=x + 1).collect()
}

pub fn signed_range_sum(start: i32, end: i32) -> i32 {
    (start..end).map(|x| x * 2).sum()
}

pub fn inclusive_range_sum(start: u8, end: u8) -> u32 {
    (start..=end).map(|x| u32::from(x)).sum()
}

pub fn reverse_range_fold(start: u8, end: u8) -> u32 {
    let mut result = 0u32;
    for value in (start..=end).rev() {
        result = result * 10 + u32::from(value);
    }
    result
}

pub fn continued_range_sum(end: u8) -> u32 {
    let mut result = 0u32;
    for value in (0u8..=end).map(|x| x) {
        if value == end {
            continue;
        }
        result += u32::from(value);
    }
    result
}

#[test]
fn range_boundaries_check() {
    assert_eq!(signed_range_sum(-2, 2), -4);
    assert_eq!(inclusive_range_sum(254, 255), 509);
    assert_eq!(reverse_range_fold(254, 255), 2804);
    assert_eq!(reverse_range_fold(255, 254), 0);
    assert_eq!(continued_range_sum(255), 32385);
}

pub fn indexed_sum(input: &[u32]) -> u32 {
    input
        .iter()
        .copied()
        .enumerate()
        .map(|(index, value)| index as u32 + value)
        .sum()
}

pub fn zipped_sum(left: &[u32], right: &[u32]) -> u32 {
    left.iter()
        .copied()
        .zip(right.iter().copied())
        .map(|(a, b)| a * b)
        .sum()
}

pub fn apply_capture(base: u32, value: u32) -> u32 {
    let add = |x: u32| x + base;
    add(value)
}

pub fn apply_move_capture(base: u32, value: u32) -> u32 {
    let mut captured = base;
    let add = move |x: u32| x + captured;
    captured = 20;
    add(value) + captured
}

pub fn apply_mut_capture(base: u32, value: u32) -> u32 {
    let mut total = base;
    let mut add = |x: u32| {
        total += x;
        total
    };
    add(value);
    add(value)
}

pub fn apply_mut_move_capture(base: u32, value: u32) -> u32 {
    let mut captured = base;
    let mut add = move |x: u32| {
        captured += x;
        captured
    };
    add(value);
    add(value)
}

pub fn borrowed_sum(input: &[u32]) -> u32 {
    input.iter().map(|x| *x + 1).sum()
}

pub fn increment_sum(input: &mut [u32]) -> u32 {
    input
        .iter_mut()
        .map(|x| {
            *x += 1;
            *x
        })
        .sum()
}

pub fn filtered_index_sum(input: &[u32]) -> u32 {
    input
        .iter()
        .copied()
        .filter(|x| *x % 2 == 0)
        .enumerate()
        .map(|(index, value)| index as u32 * 100 + value)
        .sum()
}

pub fn filtered_zip_sum(left: &[u32], right: &[u32]) -> u32 {
    left.iter()
        .copied()
        .filter(|x| *x % 2 == 0)
        .zip(right.iter().copied())
        .map(|(a, b)| a * b)
        .sum()
}

pub fn for_adapter_sum(input: &[u32], offset: u32) -> u32 {
    let mut total = 0;
    for value in input.iter().copied().map(|x| x + offset).filter(|x| *x > 4) {
        total += value;
    }
    total
}

pub fn moved_adapter_sum(input: &[u32], base: u32) -> u32 {
    let mut running = base;
    let result: u32 = input
        .iter()
        .copied()
        .map(move |x| {
            running += x;
            running
        })
        .sum();
    result + running
}

pub fn counted_filter_sum(input: &[u32]) -> u32 {
    let mut calls = 0u32;
    let total: u32 = input
        .iter()
        .copied()
        .map(|x| {
            calls += 1;
            x
        })
        .filter(|&x| x % 2 == 0)
        .sum();
    total + calls * 100
}

#[test]
fn adapter_boundaries_check() {
    assert_eq!(indexed_sum(&[10, 20, 30]), 63);
    assert_eq!(indexed_sum(&[]), 0);
    assert_eq!(borrowed_sum(&[1, 3]), 6);
    assert_eq!(zipped_sum(&[2, 3, 99], &[4, 5]), 23);
    assert_eq!(zipped_sum(&[], &[4, 5]), 0);
    assert_eq!(zipped_sum(&[4, 5], &[]), 0);
    assert_eq!(filtered_index_sum(&[1, 2, 3, 4]), 106);
    assert_eq!(filtered_zip_sum(&[1, 2, 3, 4], &[10, 20, 30]), 100);
    assert_eq!(for_adapter_sum(&[1, 2, 3, 4], 2), 11);
    assert_eq!(moved_adapter_sum(&[2, 3], 1), 10);
    assert_eq!(counted_filter_sum(&[1, 2, 3]), 302);
}

#[test]
fn closure_capture_check() {
    assert_eq!(apply_capture(7, 3), 10);
    assert_eq!(apply_move_capture(7, 3), 30);
    assert_eq!(apply_mut_capture(7, 3), 13);
    assert_eq!(apply_mut_move_capture(7, 3), 13);
}

pub struct OptionalValue {
    value: Option<u8>,
}

impl OptionalValue {
    pub fn consume(&mut self) -> u8 {
        match self.value.take() {
            Some(value) => value,
            None => 0,
        }
    }
}

#[test]
fn option_take_check() {
    let mut state = OptionalValue { value: Some(7u8) };
    assert_eq!(state.consume(), 7);
    assert_eq!(state.consume(), 0);
}
