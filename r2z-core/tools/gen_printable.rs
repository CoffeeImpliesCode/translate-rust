use std::fmt::{self, Write as FmtWrite};
use std::io::{self, Write as IoWrite};

struct ScalarCount(u8);
impl fmt::Write for ScalarCount {
    fn write_str(&mut self, value: &str) -> fmt::Result {
        self.0 += value.chars().count() as u8;
        Ok(())
    }
}

fn main() -> io::Result<()> {
    let version = std::env::args().nth(1).expect("usage: gen_printable <rustc-version>");
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(out, "// Generated with {version}; source: core::fmt::Debug for char.")?;
    writeln!(out, "// Regenerate with r2z-core/tools/gen_printable.rs.")?;
    out.write_all(br#"
pub fn isPrintable(value: u21) bool {
    if (value < 0x80) return value >= 0x20 and value != 0x7f;
    var lo: usize = 0;
    var hi: usize = non_printable.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (non_printable[mid][1] < value) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo == non_printable.len or value < non_printable[lo][0];
}

const non_printable = [_][2]u21{
"#)?;
    let mut start = None;
    for value in 0x80..=0x10ffffu32 {
        let escaped = match char::from_u32(value) {
            Some(character) => {
                let mut count = ScalarCount(0);
                write!(&mut count, "{character:?}").expect("counter writer cannot fail");
                count.0 != 3
            }
            None => true,
        };
        if escaped {
            start.get_or_insert(value);
        } else if let Some(first) = start.take() {
            writeln!(out, "    .{{ 0x{first:x}, 0x{:x} }},", value - 1)?;
        }
    }
    if let Some(first) = start {
        writeln!(out, "    .{{ 0x{first:x}, 0x10ffff }},")?;
    }
    writeln!(out, "}};")?;
    out.flush()
}
