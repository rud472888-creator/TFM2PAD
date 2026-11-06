use serde_json::Value;
use std::collections::BTreeMap;
pub const POS: [&str; 5] = ["top", "jungle", "mid", "bottom", "support"];
pub const POS_LABEL: [&str; 5] = ["탑", "정글", "미드", "바텀", "서포터"];
pub const MODE: [&str; 7] = [
    "현재 유지",
    "팀 설정 따름",
    "근접",
    "원거리",
    "마법",
    "보조",
    "암살",
];
#[derive(Clone, Debug)]
pub struct Champion {
    pub name: String,
    pub category: usize,
}
#[derive(Clone, Debug)]
pub struct Athlete {
    pub id: usize,
    pub data: Value,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Assignment {
    pub athlete: usize,
    pub position: Option<usize>,
    pub target: Option<String>,
    pub label: String,
}
pub fn contract_team(v: &Value) -> Option<u64> {
    if let Some(c) = v.get("InContract") {
        c.get("team_id")?.as_u64()
    } else if v.get("FreeAgent").is_some() || v.as_str() == Some("FreeAgent") {
        None
    } else {
        v.get("team_id")?.as_u64()
    }
}
fn role(v: &Value) -> Option<usize> {
    if let Some(n) = v.as_u64() {
        return (n < 5).then_some(n as usize);
    }
    let s = v.as_str()?.to_ascii_lowercase();
    POS.iter().position(|x| *x == s)
}
fn find_role(v: &Value, key: &str) -> Option<usize> {
    match v {
        Value::Object(m) => m
            .get(key)
            .and_then(role)
            .or_else(|| m.values().find_map(|v| find_role(v, key))),
        Value::Array(a) => a.iter().find_map(|v| find_role(v, key)),
        _ => None,
    }
}
fn history(v: &Value, out: &mut [u64; 5]) {
    match v {
        Value::Object(m) => {
            if let Some(p) = m.get("by_position").and_then(Value::as_object) {
                for (k, v) in p {
                    if let Some(i) = role(&Value::String(k.clone())) {
                        out[i] = out[i].saturating_add(v["matches"].as_u64().unwrap_or(1));
                    }
                }
            }
            for v in m.values() {
                history(v, out);
            }
        }
        Value::Array(a) => {
            for v in a {
                history(v, out)
            }
        }
        _ => {}
    }
}
pub fn position(team: &Value, a: &Athlete) -> Option<usize> {
    if let Some(i) = team["last_starting"].as_array().and_then(|v| {
        v.iter()
            .take(5)
            .position(|x| x.as_u64() == Some(a.id as u64))
    }) {
        return Some(i);
    }
    if let Some(i) = find_role(&a.data, "main_position").or_else(|| find_role(&a.data, "position"))
    {
        return Some(i);
    }
    let mut counts = [0; 5];
    history(&a.data, &mut counts);
    if let Some((i, _)) = counts
        .iter()
        .enumerate()
        .filter(|(_, v)| **v > 0)
        .max_by_key(|(_, v)| **v)
    {
        return Some(i);
    }
    let stat = a.data.get("stat").unwrap_or(&a.data);
    POS.iter()
        .enumerate()
        .filter_map(|(i, k)| {
            stat[*k]
                .as_f64()
                .filter(|v| v.is_finite() && *v > 0.0)
                .map(|v| (i, v))
        })
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|v| v.0)
}
fn rank(v: &Value) -> Option<usize> {
    match v.as_str()? {
        "S" => Some(0),
        "A" => Some(1),
        "B" => Some(2),
        "C" => Some(3),
        "D" => Some(4),
        _ => None,
    }
}
pub fn top4(team: &Value, champions: &[Champion], category: usize) -> Vec<String> {
    let mut r: Vec<_> = champions
        .iter()
        .filter(|c| c.category == category)
        .filter_map(|c| rank(&team["champion_tiers"][&c.name]).map(|rank| (rank, c.name.clone())))
        .collect();
    r.sort();
    r.into_iter().take(4).map(|(_, s)| s).collect()
}
pub fn assignments(
    team: &Value,
    athletes: &[Athlete],
    champions: &[Champion],
    modes: [usize; 5],
) -> Result<Vec<Assignment>, String> {
    if modes.iter().any(|m| *m > 6) {
        return Err("훈련 분류가 올바르지 않습니다.".into());
    }
    let choices: Vec<_> = (0..5).map(|i| top4(team, champions, i)).collect();
    let mut rows = Vec::new();
    for a in athletes {
        let p = position(team, a);
        let mode = p.map(|i| modes[i]).unwrap_or(0);
        let target = if mode == 0 {
            None
        } else if mode == 1 {
            Some(String::new())
        } else {
            let names = &choices[mode - 2];
            if names.is_empty() {
                return Err(format!(
                    "{} 분류의 팀 티어가 없습니다. 챔피언 화면에서 먼저 티어를 설정해 주세요.",
                    MODE[mode]
                ));
            }
            Some(
                names
                    .iter()
                    .enumerate()
                    .map(|(i, n)| {
                        format!(
                            "{n}:{}",
                            100 / names.len() + usize::from(i < 100 % names.len())
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("|"),
            )
        };
        let label = if mode >= 2 {
            choices[mode - 2].join(" · ")
        } else {
            MODE[mode].into()
        };
        rows.push(Assignment {
            athlete: a.id,
            position: p,
            target,
            label,
        });
    }
    Ok(rows)
}
pub fn changed_map(
    current: &BTreeMap<usize, String>,
    rows: &[Assignment],
) -> BTreeMap<usize, String> {
    let mut out = current.clone();
    for r in rows {
        if let Some(s) = &r.target {
            if s.is_empty() {
                out.remove(&r.athlete);
            } else {
                out.insert(r.athlete, s.clone());
            }
        }
    }
    out
}
pub fn encode_map(map: &BTreeMap<usize, String>) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(map.len() as u64).to_le_bytes());
    for (id, s) in map {
        out.extend_from_slice(&(*id as u64).to_le_bytes());
        out.extend_from_slice(&(s.len() as u64).to_le_bytes());
        out.extend_from_slice(s.as_bytes());
    }
    out
}
pub fn decode_map(wire: &[u8]) -> Result<BTreeMap<usize, String>, String> {
    let mut p = 0;
    fn take(b: &[u8], p: &mut usize) -> Result<usize, String> {
        let end = p.checked_add(8).ok_or("overflow")?;
        let v = b.get(*p..end).ok_or("truncated")?;
        *p = end;
        usize::try_from(u64::from_le_bytes(v.try_into().unwrap())).map_err(|_| "overflow".into())
    }
    let count = take(wire, &mut p)?;
    if count > 10_000 {
        return Err("훈련 목록이 너무 큽니다.".into());
    }
    let mut map = BTreeMap::new();
    for _ in 0..count {
        let id = take(wire, &mut p)?;
        let len = take(wire, &mut p)?;
        let end = p.checked_add(len).ok_or("overflow")?;
        if len > 65536 {
            return Err("훈련 문자열이 너무 큽니다.".into());
        }
        let s = std::str::from_utf8(wire.get(p..end).ok_or("truncated")?).map_err(|_| "utf8")?;
        p = end;
        if map.insert(id, s.to_owned()).is_some() {
            return Err("duplicate".into());
        }
    }
    if p != wire.len() {
        return Err("trailing".into());
    }
    Ok(map)
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn role_precedence_and_no_role() {
        let team = json!({"last_starting":[90,5,2,4,3]});
        let a = Athlete {
            id: 5,
            data: json!({"main_position":"top","stat":{"mid":100}}),
        };
        assert_eq!(position(&team, &a), Some(1));
        let b = Athlete {
            id: 6,
            data: json!({"stat":{"top":20,"bottom":80}}),
        };
        assert_eq!(position(&team, &b), Some(3));
        let c = Athlete {
            id: 7,
            data: json!({}),
        };
        assert_eq!(position(&team, &c), None);
    }
    #[test]
    fn tier_top4_clear_keep_preserves_other_athletes() {
        let team = json!({"last_starting":[1,2,3],"champion_tiers":{"a":"A","b":"S","c":"D","d":"B","e":"C"}});
        let ch: Vec<_> = ["a", "b", "c", "d", "e"]
            .iter()
            .map(|n| Champion {
                name: (*n).into(),
                category: 0,
            })
            .collect();
        assert_eq!(top4(&team, &ch, 0), ["b", "a", "d", "e"]);
        let athletes = (1..=3)
            .map(|id| Athlete {
                id,
                data: json!({}),
            })
            .collect::<Vec<_>>();
        let rows = assignments(&team, &athletes, &ch, [2, 1, 0, 0, 0]).unwrap();
        let old = BTreeMap::from([
            (1, "old".into()),
            (2, "old".into()),
            (3, "keep".into()),
            (99, "foreign".into()),
        ]);
        let next = changed_map(&old, &rows);
        assert_eq!(next[&1], "b:25|a:25|d:25|e:25");
        assert!(!next.contains_key(&2));
        assert_eq!(next[&3], "keep");
        assert_eq!(next[&99], "foreign");
        assert_eq!(decode_map(&encode_map(&next)).unwrap(), next);
    }
    #[test]
    fn malformed_and_unknown_tiers_fail_closed() {
        assert!(decode_map(&[1]).is_err());
        assert!(decode_map(&[0; 9]).is_err());
        let a = Athlete {
            id: 1,
            data: json!({}),
        };
        assert!(assignments(&json!({"last_starting":[1]}), &[a], &[], [2, 0, 0, 0, 0]).is_err());
    }
}

#[cfg(test)]
mod regression {
    use super::*;
    use serde_json::json;
    #[test]
    fn history_and_position_fallback_are_separate_from_training_categories() {
        let a = Athlete {
            id: 12,
            data: json!({"history":{"by_position":{"Top":{"matches":2},"Support":{"matches":4}}},"stat":{"mid":99}}),
        };
        assert_eq!(position(&json!({}), &a), Some(4));
        let b = Athlete {
            id: 13,
            data: json!({"main_position":"Bottom","stat":{"top":99}}),
        };
        assert_eq!(position(&json!({}), &b), Some(3));
    }
    #[test]
    fn fewer_than_four_get_full_equal_total_and_unknown_role_stays_untouched() {
        let t = json!({"last_starting":[1],"champion_tiers":{"a":"S","b":"A","c":"B","other":"S"}});
        let ch = vec![
            Champion {
                name: "a".into(),
                category: 4,
            },
            Champion {
                name: "b".into(),
                category: 4,
            },
            Champion {
                name: "c".into(),
                category: 4,
            },
            Champion {
                name: "other".into(),
                category: 0,
            },
        ];
        let r = assignments(
            &t,
            &[
                Athlete {
                    id: 1,
                    data: json!({}),
                },
                Athlete {
                    id: 2,
                    data: json!({}),
                },
            ],
            &ch,
            [6, 0, 0, 0, 0],
        )
        .unwrap();
        assert_eq!(r[0].target.as_deref(), Some("a:34|b:33|c:33"));
        assert_eq!(r[1].target, None);
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn actual_nested_contracts_and_legacy_flat_are_explicit() {
        assert_eq!(contract_team(&json!({"InContract":{"team_id":0}})), Some(0));
        assert_eq!(contract_team(&json!({"InContract":{"team_id":7}})), Some(7));
        assert_eq!(contract_team(&json!({"team_id":7})), Some(7));
        assert_eq!(contract_team(&json!({"FreeAgent":{}})), None);
        assert_eq!(contract_team(&json!("FreeAgent")), None);
        assert_eq!(contract_team(&json!({"InContract":{}})), None);
    }
}
