//! Bounded, strict JSON reader for owned snapshots returned by the host.
//! No SDK/native layout assumptions and no mutation of management records.
use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool,
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}
impl Json {
    pub fn get(&self, key: &str) -> Option<&Self> {
        match self {
            Self::Object(v) => v.get(key),
            _ => None,
        }
    }
    pub fn string(&self) -> Option<&str> {
        match self {
            Self::String(v) => Some(v),
            _ => None,
        }
    }
    pub fn number(&self) -> Option<f64> {
        match self {
            Self::Number(v) => Some(*v),
            Self::Object(_) => self.get("value")?.number(),
            _ => None,
        }
    }
    pub fn id(&self) -> Option<usize> {
        let n = self.number()?;
        (n >= 0.0 && n.fract() == 0.0 && n < usize::MAX as f64).then_some(n as usize)
    }
    pub fn object(&self) -> Option<&BTreeMap<String, Self>> {
        match self {
            Self::Object(v) => Some(v),
            _ => None,
        }
    }
}
pub fn parse(text: &str) -> Option<Json> {
    if text.len() > 2 * 1024 * 1024 {
        return None;
    }
    let mut p = Parser {
        input: text.as_bytes(),
        at: 0,
    };
    let value = p.value(0)?;
    p.ws();
    (p.at == p.input.len()).then_some(value)
}
struct Parser<'a> {
    input: &'a [u8],
    at: usize,
}
impl Parser<'_> {
    fn ws(&mut self) {
        while matches!(self.input.get(self.at), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.at += 1;
        }
    }
    fn eat(&mut self, c: u8) -> Option<()> {
        self.ws();
        if self.input.get(self.at) != Some(&c) {
            return None;
        }
        self.at += 1;
        Some(())
    }
    fn string(&mut self) -> Option<String> {
        self.eat(b'"')?;
        let mut s = String::new();
        let mut start = self.at;
        loop {
            let c = *self.input.get(self.at)?;
            if c == b'"' || c == b'\\' {
                s.push_str(std::str::from_utf8(&self.input[start..self.at]).ok()?);
                self.at += 1;
                if c == b'"' {
                    return Some(s);
                }
                let e = *self.input.get(self.at)?;
                self.at += 1;
                match e {
                    b'"' => s.push('"'),
                    b'\\' => s.push('\\'),
                    b'/' => s.push('/'),
                    b'b' => s.push('\u{8}'),
                    b'f' => s.push('\u{c}'),
                    b'n' => s.push('\n'),
                    b'r' => s.push('\r'),
                    b't' => s.push('\t'),
                    b'u' => {
                        let high = self.hex4()?;
                        let cp = if (0xd800..=0xdbff).contains(&high) {
                            if self.input.get(self.at..self.at + 2)? != b"\\u" {
                                return None;
                            }
                            self.at += 2;
                            let low = self.hex4()?;
                            if !(0xdc00..=0xdfff).contains(&low) {
                                return None;
                            }
                            0x10000 + ((high - 0xd800) << 10) + low - 0xdc00
                        } else {
                            high
                        };
                        s.push(char::from_u32(cp)?);
                    }
                    _ => return None,
                }
                start = self.at;
            } else {
                if c < 0x20 {
                    return None;
                }
                self.at += 1;
            }
        }
    }
    fn hex4(&mut self) -> Option<u32> {
        let bytes = self.input.get(self.at..self.at + 4)?;
        let v = u32::from_str_radix(std::str::from_utf8(bytes).ok()?, 16).ok()?;
        self.at += 4;
        Some(v)
    }
    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > 48 {
            return None;
        }
        self.ws();
        match *self.input.get(self.at)? {
            b'"' => Some(Json::String(self.string()?)),
            b'{' => {
                self.at += 1;
                self.ws();
                let mut map = BTreeMap::new();
                if self.input.get(self.at) == Some(&b'}') {
                    self.at += 1;
                    return Some(Json::Object(map));
                }
                loop {
                    let key = self.string()?;
                    self.eat(b':')?;
                    if map.insert(key, self.value(depth + 1)?).is_some() {
                        return None;
                    }
                    self.ws();
                    match self.input.get(self.at)? {
                        b'}' => {
                            self.at += 1;
                            break;
                        }
                        b',' => self.at += 1,
                        _ => return None,
                    }
                }
                Some(Json::Object(map))
            }
            b'[' => {
                self.at += 1;
                self.ws();
                let mut values = Vec::new();
                if self.input.get(self.at) == Some(&b']') {
                    self.at += 1;
                    return Some(Json::Array(values));
                }
                loop {
                    values.push(self.value(depth + 1)?);
                    self.ws();
                    match self.input.get(self.at)? {
                        b']' => {
                            self.at += 1;
                            break;
                        }
                        b',' => self.at += 1,
                        _ => return None,
                    }
                }
                Some(Json::Array(values))
            }
            b'n' => {
                if self.input.get(self.at..self.at + 4)? != b"null" {
                    return None;
                }
                self.at += 4;
                Some(Json::Null)
            }
            b't' => {
                if self.input.get(self.at..self.at + 4)? != b"true" {
                    return None;
                }
                self.at += 4;
                Some(Json::Bool)
            }
            b'f' => {
                if self.input.get(self.at..self.at + 5)? != b"false" {
                    return None;
                }
                self.at += 5;
                Some(Json::Bool)
            }
            b'-' | b'0'..=b'9' => {
                let start = self.at;
                if self.input[self.at] == b'-' {
                    self.at += 1;
                }
                match self.input.get(self.at)? {
                    b'0' => self.at += 1,
                    b'1'..=b'9' => {
                        self.at += 1;
                        while self.input.get(self.at).is_some_and(u8::is_ascii_digit) {
                            self.at += 1;
                        }
                    }
                    _ => return None,
                }
                if self.input.get(self.at) == Some(&b'.') {
                    self.at += 1;
                    let a = self.at;
                    while self.input.get(self.at).is_some_and(u8::is_ascii_digit) {
                        self.at += 1;
                    }
                    if a == self.at {
                        return None;
                    }
                }
                if matches!(self.input.get(self.at), Some(b'e' | b'E')) {
                    self.at += 1;
                    if matches!(self.input.get(self.at), Some(b'+' | b'-')) {
                        self.at += 1;
                    }
                    let a = self.at;
                    while self.input.get(self.at).is_some_and(u8::is_ascii_digit) {
                        self.at += 1;
                    }
                    if a == self.at {
                        return None;
                    }
                }
                let value: f64 = std::str::from_utf8(&self.input[start..self.at])
                    .ok()?
                    .parse()
                    .ok()?;
                value.is_finite().then_some(Json::Number(value))
            }
            _ => None,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_and_nested() {
        let p = parse(r#"{"name":"한글\uD83D\uDE00","stat":{"value":{"last_hit":72}}}"#).unwrap();
        assert_eq!(p.get("name").unwrap().string(), Some("한글😀"));
        assert_eq!(
            p.get("stat")
                .unwrap()
                .get("value")
                .unwrap()
                .get("last_hit")
                .unwrap()
                .number(),
            Some(72.0)
        );
    }
    #[test]
    fn malformed_fails_closed() {
        for s in [
            "[1,]",
            "{\"x\":1,\"x\":2}",
            "01",
            "1.",
            "1e",
            "1e999",
            "null junk",
            r#""\uD800""#,
        ] {
            assert!(parse(s).is_none(), "{s}");
        }
    }
}
