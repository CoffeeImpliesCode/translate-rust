pub struct Value {
    pub count: u32,
}

impl std::fmt::Display for Value {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = String::from("allocated");
        write!(formatter, "{}={}", text, self.count)
    }
}
