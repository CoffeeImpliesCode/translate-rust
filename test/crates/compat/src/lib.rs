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

pub fn temporary_equal(input: &str) -> bool {
    String::from(input) == String::from("same")
}

pub fn temporary_result(input: &str) -> Result<String, u8> {
    if input == "bad" {
        Err(7)
    } else {
        Ok(String::from(input))
    }
}

pub fn temporary_result_equal(input: &str) -> bool {
    temporary_result(input) == temporary_result("same")
}

pub fn temporary_unwrap_equal(input: &str) -> bool {
    temporary_result(input).unwrap() == String::from("same")
}

pub fn temporary_ordered(input: &str, sequence: &mut u32) -> String {
    *sequence = *sequence * 10 + 1;
    String::from(input)
}

pub fn temporary_conditional(enabled: bool, sequence: &mut u32) -> bool {
    enabled && temporary_ordered("same", sequence) == {
        *sequence = *sequence * 10 + 2;
        String::from("same")
    }
}

pub fn temporary_borrowed_equal(input: &String) -> bool {
    *input == String::from("same")
}

pub fn temporary_vec(input: u8) -> Result<Vec<u8>, u8> {
    Ok(vec![input])
}

pub fn temporary_vec_equal(input: u8) -> bool {
    temporary_vec(input).unwrap() == [7u8]
}

// A user error whose `deinit` is an ordinary method rather than a `Drop`
// impl. Nothing in Rust calls it when a value goes out of scope, so releasing
// a comparison temporary must leave `code` exactly as the source left it.
#[derive(PartialEq)]
pub struct UserError {
    pub code: u8,
}

impl UserError {
    pub fn deinit(&mut self) {
        self.code = 0;
    }
}

// The parameter is spelled `error` on purpose. A formal parameter reaches
// the emitted declaration the same way a local binding does, so this is the
// other shape a user identifier takes while a native `error` namespace also
// exists, and reading a field through it must stay a field read.
pub fn user_error_code(error: &UserError) -> u8 {
    error.code
}

pub fn user_error() -> Result<String, UserError> {
    Err(UserError { code: 7 })
}

pub fn temporary_user_error_equal(code: u8) -> bool {
    user_error() == Err(UserError { code })
}

// One more level, returning nothing the caller owns. The producer builds no
// owned value, so the only allocator work is the comparison's release, and it
// has to reach that comparison through this frame.
pub fn temporary_user_error_caller(code: u8) -> bool {
    temporary_user_error_equal(code)
}

// The other error shape: every variant is field-free, which is exactly what
// a Zig error set can spell, so `Rejected` reaches the consumer as the native
// tag `error.Rejected` instead of as a user value. `unwrap` on a `Result`
// reports its error through `Debug`, so the derive is what keeps this source
// compiling Rust on its own terms.
#[derive(Debug)]
pub enum TagError {
    Rejected,
    Accepted,
}

pub fn tagged_result(accept: bool) -> Result<u8, TagError> {
    if accept {
        Ok(7)
    } else {
        Err(TagError::Rejected)
    }
}

// The same two constructors, but the frame around them returns something
// that is not a `Result`. Nothing in the signature names the error here, so
// the `Err` payload reaches the union as the native tag only because the
// local binding declares the `Result` itself. Returning the value inside an
// `Option` carries it out whole, so the consumer still sees both arms.
pub fn contextual_tagged_result(accept: bool) -> Option<Result<u8, TagError>> {
    let result: Result<u8, TagError> = if accept {
        Ok(7)
    } else {
        Err(TagError::Rejected)
    };
    Some(result)
}

// The payload and the error are the same type here, so the value alone cannot
// say which side of the union it belongs to. Only the `Ok` constructor does,
// and reading the enclosing return type instead spells the user's variant as
// the native tag.
pub fn native_ok_variant() -> Result<TagError, TagError> {
    Ok(TagError::Accepted)
}

// The parameter is spelled `error` for the same reason `user_error_code`'s is:
// it reaches the emitted declaration as `@"error"` while the native `error`
// namespace exists, and it must stay a user binding.
pub fn identity_tag_error(error: TagError) -> TagError {
    error
}

// The variant crosses an ordinary call before it reaches `Err`, so on the way
// in it is an argument and nothing more. Turning it into the native tag there
// would hand `identity_tag_error` a value its parameter type cannot name.
pub fn native_dynamic_error() -> Result<u8, TagError> {
    Err(identity_tag_error(TagError::Rejected))
}

// `String::new()` has no lowering yet, so the empty literal stands in: it
// copies nothing, yet the conversion still names the allocator, so the empty
// value still has to reach a cleanup.
pub fn temporary_empty_string() -> String {
    String::from("")
}

pub fn temporary_empty_equal(input: &str) -> bool {
    temporary_empty_string() == String::from(input)
}

// The `Ok` payload arrives already owned and the right-hand side is a borrow,
// so this frame constructs nothing. Its only allocator work is releasing what
// the caller handed over, which is why the parameter — not a literal — is what
// decides the comparison.
pub fn temporary_moved_result_equal(value: Result<String, u8>) -> bool {
    value.unwrap() == "same"
}

// One more level, so the allocator the release needs has to reach the
// comparison through a frame that owns nothing of its own.
pub fn temporary_moved_result_caller(value: Result<String, u8>) -> bool {
    temporary_moved_result_equal(value)
}

#[test]
fn user_error_cleanup_check() {
    assert!(temporary_user_error_caller(7));
    assert!(!temporary_user_error_caller(8));
}

#[test]
fn user_error_deinit_check() {
    let mut error = UserError { code: 7 };
    assert_eq!(user_error_code(&error), 7);
    error.deinit();
    assert_eq!(error.code, 0);
    assert_eq!(user_error_code(&error), 0);
}

// `unwrap` is the only arm a Zig error union answers: reading the tag back
// out of one needs the consumer, which is where `error.Rejected` is checked
// against this exact name.
#[test]
fn tagged_result_check() {
    assert_eq!(tagged_result(true).unwrap(), 7);
    // The frame that builds this one returns an `Option`, so the `Result` has
    // to name its own error rather than borrow the enclosing signature's.
    assert_eq!(contextual_tagged_result(true).unwrap().unwrap(), 7);
    // The successful payload is the user's own enum, so it matches as an
    // ordinary variant and not as the tag that spells the same word.
    let payload = match native_ok_variant().unwrap() {
        TagError::Accepted => true,
        TagError::Rejected => false,
    };
    assert!(payload);
}

#[test]
fn moved_result_comparison_check() {
    assert!(temporary_moved_result_caller(temporary_result("same")));
    assert!(!temporary_moved_result_caller(temporary_result("other")));
}

#[test]
fn empty_string_cleanup_check() {
    assert!(temporary_empty_equal(""));
    assert!(!temporary_empty_equal("other"));
}

#[test]
fn indexed_any_advances_original_cursor() {
    let bytes: &[u8] = b"a%b";
    let mut iters = [bytes.iter()];
    assert!(iters[0].any(|&byte| byte == b'%'));
    assert_eq!(iters[0].len(), 1);
    assert!(!iters[0].any(|&byte| byte == b'%'));
    assert_eq!(iters[0].len(), 0);
}

#[test]
fn dereferenced_any_advances_original_cursor() {
    let bytes: &[u8] = b"a%b";
    let mut iter = bytes.iter();
    let pointer = &mut iter;
    assert!((*pointer).any(|&byte| byte == b'%'));
    assert_eq!(iter.len(), 1);
    assert!(!iter.any(|&byte| byte == b'%'));
    assert_eq!(iter.len(), 0);
}

struct ArrayViewStorage {
    bytes: [u8; 2],
}

fn write_inferred_nested_array(value: u8) -> u8 {
    let mut rows = [[0; 2]; 2];
    let view = &mut rows[1][..];
    view[0] = value;
    rows[1][0]
}

#[test]
fn mutable_array_views_reach_owned_places() {
    let mut storage = ArrayViewStorage { bytes: [0u8; 2] };
    let field_view = &mut storage.bytes[..];
    field_view[0] = 37;
    assert_eq!(storage.bytes[0], 37);

    let mut rows = [[0u8; 2]; 2];
    let indexed_view = &mut rows[1][..];
    indexed_view[0] = 91;
    assert_eq!(rows[1][0], 91);
    assert_eq!(write_inferred_nested_array(143), 143);
}

enum OrPayload {
    A { n: u8 },
    B { flag: bool, n: u8 },
    C(u8),
    Other,
}

fn or_payload(mode: u8, n: u8, guarded: bool) -> u8 {
    let value = if mode == 0 {
        OrPayload::A { n }
    } else if mode == 1 {
        OrPayload::B { flag: true, n }
    } else if mode == 2 {
        OrPayload::C(n)
    } else {
        OrPayload::Other
    };
    if guarded {
        match value {
            OrPayload::A { n } | OrPayload::B { n, .. } | OrPayload::C(n) if n > 0 => n + 1,
            _ => 99,
        }
    } else {
        match value {
            OrPayload::A { n } | OrPayload::B { n, .. } | OrPayload::C(n) => n,
            _ => 99,
        }
    }
}

#[test]
fn or_patterns_keep_payload_identity_and_guarded_fallthrough() {
    assert_eq!(or_payload(0, 4, true), 5);
    assert_eq!(or_payload(1, 7, true), 8);
    assert_eq!(or_payload(2, 12, true), 13);
    assert_eq!(or_payload(1, 0, true), 99);
    assert_eq!(or_payload(3, 4, true), 99);
    assert_eq!(or_payload(0, 4, false), 4);
    assert_eq!(or_payload(1, 7, false), 7);
    assert_eq!(or_payload(2, 0, false), 0);
    assert_eq!(or_payload(3, 4, false), 99);
}

fn tuple_u8(value: u8) -> u8 { value }
fn tuple_i64(value: i64) -> i64 { value }

#[test]
fn tuple_literals_keep_distinct_contextual_element_types() {
    let first = (7, true);
    let second = (9, false);
    assert_eq!(tuple_u8(first.0), 7u8);
    assert_eq!(tuple_i64(second.0), 9i64);
    assert!(first.1);
    assert!(!second.1);
}

const DECODED_NEWLINE: &str = "\n";
const DECODED_TAB: &str = "\t";
const DECODED_HEX: &str = "\x41";
const DECODED_UNICODE: &str = "\u{e9}";
const DECODED_CONTINUATION: &str = "A\
    B";
const RAW_ESCAPE: &str = r"\n";

#[test]
fn constant_and_expression_strings_have_identical_bytes() {
    assert_eq!(DECODED_NEWLINE, "\n");
    assert_eq!(DECODED_NEWLINE.len(), 1);
    assert_eq!(DECODED_TAB, "\t");
    assert_eq!(DECODED_HEX, "A");
    assert_eq!(DECODED_UNICODE, "\u{e9}");
    assert_eq!(DECODED_CONTINUATION, "AB");
    assert_eq!(RAW_ESCAPE, r"\n");
}

enum OwnedOrPayload {
    A(String),
    B(String),
    C(String),
}

fn owned_or_payload_length(mode: u8, guarded: bool) -> usize {
    let value = if mode == 0 {
        OwnedOrPayload::A("first".to_string())
    } else if mode == 1 {
        OwnedOrPayload::B("second".to_string())
    } else {
        OwnedOrPayload::C("third".to_string())
    };
    if guarded {
        match value {
            OwnedOrPayload::A(text) | OwnedOrPayload::B(text) if text.len() > 5 => text.len(),
            OwnedOrPayload::C(text) => text.len(),
            OwnedOrPayload::A(text) | OwnedOrPayload::B(text) => text.len(),
        }
    } else {
        match value {
            OwnedOrPayload::A(text) | OwnedOrPayload::B(text) => text.len(),
            OwnedOrPayload::C(text) => text.len(),
        }
    }
}

#[test]
fn owned_or_patterns_release_only_the_selected_arm() {
    assert_eq!(owned_or_payload_length(0, false), 5);
    assert_eq!(owned_or_payload_length(1, false), 6);
    assert_eq!(owned_or_payload_length(2, false), 5);
    assert_eq!(owned_or_payload_length(0, true), 5);
    assert_eq!(owned_or_payload_length(1, true), 6);
    assert_eq!(owned_or_payload_length(2, true), 5);
}
