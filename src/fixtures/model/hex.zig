// Golden emitter output for the hex crate (P2/P3 golden corpus #2).
//
// Reduced subset: the v1 emitter lowers `let`, `for` over a slice, `assign`,
// `return`, path, and string literals. It does not yet lower method calls
// (`out.append`), `try`/`catch`, `defer`, or error-union return types, so the
// full allocator-backed `hex::encode` body cannot be represented. This golden
// holds the slice/string subset that the emitter produces verbatim:
//   * slice-handling — `bytes: []const u8` param and `for (bytes) |byte|`
//   * string-emission — `var out` initialized from a string literal
// The golden-file test compares emitter output against this core textually.

pub fn encode(bytes: []const u8) []const u8 {
    var out: []const u8 = "";
    for (bytes) |byte| {
        out = bytes;
    }
    return out;
}
