//! Version-pinned ARM64 private adapter. No stack-frame channel access.
use crate::planner::{self, Assignment};
use mod_api_stable::ServerCtxV1;
#[cfg(target_arch = "aarch64")]
use std::arch::asm;
use std::{
    ffi::{c_char, c_void, CStr},
    mem::size_of,
};
#[repr(C)]
struct RawVec {
    cap: usize,
    ptr: *mut u8,
    len: usize,
}
unsafe extern "C" {
    fn _dyld_image_count() -> u32;
    fn _dyld_get_image_header(i: u32) -> *const u8;
    fn _dyld_get_image_name(i: u32) -> *const c_char;
    static mach_task_self_: u32;
    fn mach_vm_read_overwrite(task: u32, address: u64, size: u64, data: u64, out: *mut u64) -> i32;
    fn mach_vm_region(
        task: u32,
        address: *mut u64,
        size: *mut u64,
        flavor: i32,
        info: *mut i32,
        count: *mut u32,
        obj: *mut u32,
    ) -> i32;
    fn mach_port_deallocate(task: u32, name: u32) -> i32;
    fn free(ptr: *mut c_void);
}
#[derive(Clone, Copy)]
pub struct Native {
    base: usize,
}
// These descriptors never cross the ABI. Every owned nested allocation is
// released by the same original game routine that created it.
struct OwnedPlan {
    api: Native,
    words: [usize; 63],
    live: bool,
}
impl OwnedPlan {
    unsafe fn cloned(api: Native, source: *const u8) -> Self {
        let mut p = Self {
            api,
            words: [0; 63],
            live: false,
        };
        api.copy(p.words.as_mut_ptr().cast(), source);
        p.live = true;
        p
    }
    fn pointer(&mut self) -> *mut u8 {
        self.words.as_mut_ptr().cast()
    }
}
impl Drop for OwnedPlan {
    fn drop(&mut self) {
        if self.live {
            unsafe {
                self.api.call1(0x1020b0ce0, self.words.as_mut_ptr().cast());
            }
            #[cfg(test)]
            OWNED_PLAN_DROPS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }
}
struct OwnedMap {
    api: Native,
    words: [usize; 6],
    live: bool,
}
impl OwnedMap {
    unsafe fn decoded(api: Native, wire: &[u8]) -> Result<Self, String> {
        let mut map = Self {
            api,
            words: [0; 6],
            live: false,
        };
        let success = api.decode(wire, map.words.as_mut_ptr().cast());
        map.live = map.words[0] != 0;
        if !success {
            if !map.live && map.words[1] != 0 {
                free(map.words[2] as *mut c_void);
            }
            return Err(err());
        }
        Ok(map)
    }
}
impl Drop for OwnedMap {
    fn drop(&mut self) {
        if self.live {
            unsafe {
                self.api.call1(0x10226bd28, self.words.as_mut_ptr().cast());
            }
        }
    }
}
struct BorrowGuard(*mut usize);
impl Drop for BorrowGuard {
    fn drop(&mut self) {
        unsafe {
            *self.0 = 0;
        }
    }
}
#[cfg(test)]
static OWNED_PLAN_DROPS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
fn err() -> String {
    "이 게임 버전의 훈련 쓰기 경로를 확인하지 못했습니다.".into()
}
unsafe fn read<const N: usize>(address: usize) -> Option<[u8; N]> {
    if address < 0x10000 {
        return None;
    }
    let mut b = [0; N];
    let mut n = 0;
    let r = mach_vm_read_overwrite(
        mach_task_self_,
        address as u64,
        N as u64,
        b.as_mut_ptr() as u64,
        &mut n,
    );
    (r == 0 && n == N as u64).then_some(b)
}
unsafe fn word(address: usize) -> Option<usize> {
    Some(usize::from_ne_bytes(read::<8>(address)?))
}
unsafe fn writable(address: usize, len: usize) -> bool {
    let mut a = address as u64;
    let mut n = 0;
    let mut info = [0i32; 10];
    let mut count = 9;
    let mut obj = 0;
    let r = mach_vm_region(
        mach_task_self_,
        &mut a,
        &mut n,
        9,
        info.as_mut_ptr(),
        &mut count,
        &mut obj,
    );
    if obj != 0 {
        mach_port_deallocate(mach_task_self_, obj);
    }
    r == 0
        && info[0] & 3 == 3
        && a <= address as u64
        && (address as u64)
            .checked_add(len as u64)
            .is_some_and(|end| end <= a + n)
}
fn hash(b: &[u8]) -> u64 {
    b.iter().fold(0xcbf29ce484222325, |h, x| {
        (h ^ *x as u64).wrapping_mul(0x100000001b3)
    })
}
impl Native {
    pub fn find() -> Option<Self> {
        unsafe {
            for i in 0.._dyld_image_count() {
                let name = _dyld_get_image_name(i);
                if name.is_null() {
                    continue;
                }
                let name = CStr::from_ptr(name).to_bytes();
                if !name.ends_with(b"TFMGame.dylib")
                    && !name.ends_with(b"TeamfightManager2")
                    && !name.ends_with(b"TFMGameFixture.dylib")
                {
                    continue;
                }
                let base = _dyld_get_image_header(i) as usize;
                if base == 0 {
                    continue;
                }
                let Some(header) = read::<32>(base) else {
                    continue;
                };
                if u32::from_le_bytes(header[0..4].try_into().unwrap()) != 0xfeedfacf
                    || u32::from_le_bytes(header[4..8].try_into().unwrap()) != 0x0100000c
                {
                    continue;
                }
                let count = u32::from_le_bytes(header[16..20].try_into().unwrap()) as usize;
                let size = u32::from_le_bytes(header[20..24].try_into().unwrap()) as usize;
                if count > 256 || size > 16352 {
                    continue;
                }
                let Some(commands) = read::<16384>(base) else {
                    continue;
                };
                let mut cursor = 32;
                let mut uuid_ok = false;
                for _ in 0..count {
                    if cursor + 8 > size + 32 {
                        break;
                    }
                    let tag = u32::from_le_bytes(commands[cursor..cursor + 4].try_into().unwrap());
                    let len =
                        u32::from_le_bytes(commands[cursor + 4..cursor + 8].try_into().unwrap())
                            as usize;
                    if len < 8 || cursor + len > size + 32 {
                        break;
                    }
                    if tag == 0x1b && len == 24 {
                        uuid_ok = commands[cursor + 8..cursor + 24]
                            == [
                                0xd1, 0xee, 0x0f, 0xfa, 0xe0, 0x9c, 0x3f, 0x50, 0x91, 0xf7, 0xa3,
                                0xee, 0x97, 0x5c, 0x02, 0xae,
                            ];
                    }
                    cursor += len;
                }
                if !uuid_ok {
                    continue;
                }
                let n = Self { base };
                if crate::pins::PINS.iter().all(|&(a, l, h)| {
                    let mut bytes = vec![0u8; l];
                    let mut size = 0;
                    mach_vm_read_overwrite(
                        mach_task_self_,
                        n.at(a) as u64,
                        l as u64,
                        bytes.as_mut_ptr() as u64,
                        &mut size,
                    ) == 0
                        && size == l as u64
                        && hash(&bytes) == h
                }) {
                    return Some(n);
                }
            }
            None
        }
    }
    fn at(self, va: usize) -> usize {
        self.base + va - 0x100000000
    }
    unsafe fn call1(self, va: usize, p: *mut u8) {
        let f: unsafe extern "C" fn(*mut u8) = std::mem::transmute(self.at(va));
        f(p);
    }
    unsafe fn copy(self, dst: *mut u8, src: *const u8) {
        let f: unsafe extern "C" fn(*mut u8, *const u8) = std::mem::transmute(self.at(0x102196aac));
        f(dst, src);
    }
    #[cfg(target_arch = "aarch64")]
    unsafe fn decode(self, wire: &[u8], out: *mut u8) -> bool {
        let mut offset = 0usize;
        asm!("blr x9",in("x9")self.at(0x1017003f8),in("x0")wire.as_ptr(),in("x1")wire.len(),in("x2")&mut offset,in("x8")out,clobber_abi("C"));
        *(out as *const usize) != 0 && offset == wire.len()
    }
    #[cfg(not(target_arch = "aarch64"))]
    unsafe fn decode(self, _wire: &[u8], _out: *mut u8) -> bool {
        false
    }
    unsafe fn serialize(self, va: usize, p: *const u8) -> Result<Vec<u8>, String> {
        let mut raw = RawVec {
            cap: 0,
            ptr: 1usize as *mut u8,
            len: 0,
        };
        let f: unsafe extern "C" fn(*const u8, *mut RawVec) = std::mem::transmute(self.at(va));
        f(p, &mut raw);
        if raw.len
            > if va == 0x100e7ac10 {
                128 * 1024 * 1024
            } else {
                16 * 1024 * 1024
            }
            || raw.len > raw.cap
            || raw.ptr.is_null()
        {
            if raw.cap != 0 {
                free(raw.ptr.cast());
            }
            return Err(err());
        }
        let b = std::slice::from_raw_parts(raw.ptr, raw.len).to_vec();
        if raw.cap != 0 {
            free(raw.ptr.cast());
        }
        Ok(b)
    }
    unsafe fn plan(self, db: usize, team: usize) -> Result<*mut u8, String> {
        let map = db.checked_add(0x17938).ok_or_else(err)?;
        let len = word(map + 0x18).ok_or_else(err)?;
        let head = word(map + 0x20).ok_or_else(err)?;
        if len == 0 || len > 512 || head == 0 {
            return Err(err());
        }
        let mut node = word(head + 0x200).ok_or_else(err)?;
        for _ in 0..len {
            if node == head {
                return Err(err());
            }
            let key = word(node + 0x208).ok_or_else(err)?;
            if key == team {
                if !writable(node, 0x1f8) {
                    return Err(err());
                }
                return Ok(node as *mut u8);
            }
            node = word(node + 0x200).ok_or_else(err)?;
        }
        Err("현재 팀의 훈련 계획이 없습니다.".into())
    }
    /// Valid only within an actual command callback. The stable team-get slot
    /// proves the opaque state belongs to this exact pinned host adapter.
    pub unsafe fn apply(
        self,
        raw: *mut ServerCtxV1,
        team: usize,
        rows: &[Assignment],
    ) -> Result<usize, String> {
        if raw.is_null() || (*raw).size < size_of::<ServerCtxV1>() || (*raw).vtable.is_null() {
            return Err(err());
        }
        let table = &*(*raw).vtable;
        if table.size < size_of::<mod_api_stable::ServerVtableV1>()
            || table.team_get_json.map(|f| f as usize) != Some(self.at(0x1026faccc))
        {
            return Err(err());
        }
        let db = word((*raw).state as usize + 0x10).ok_or_else(err)?;
        self.apply_database(db, team, rows)
    }
    /// Isolated native test entry uses a decoded in-memory campaign Database;
    /// production reaches it only after stable sender/team validation above.
    pub unsafe fn apply_database(
        self,
        db: usize,
        team: usize,
        rows: &[Assignment],
    ) -> Result<usize, String> {
        let plan = self.plan(db, team)?;
        self.apply_plan(plan, rows)
    }
    pub unsafe fn apply_client(
        self,
        raw: *mut mod_api_stable::ClientCtxV1,
        team: usize,
        rows: &[Assignment],
    ) -> Result<usize, String> {
        if raw.is_null()
            || (*raw).size < size_of::<mod_api_stable::ClientCtxV1>()
            || (*raw).data.is_null()
        {
            return Err(err());
        }
        let data = &*(*raw).data;
        if data.size < size_of::<mod_api_stable::DataVtableV1>()
            || data.record_get_json.map(|f| f as usize) != Some(self.at(0x102748058))
        {
            return Err(err());
        }
        let scene = word((*raw).state as usize + 0x68).ok_or_else(err)?;
        if word(scene) != Some(6) {
            return Err(err());
        }
        let rc = word(scene + 8 + 0x30).ok_or_else(err)?;
        if word(rc).is_none_or(|n| n == 0)
            || word(rc + 0x10) != Some(0)
            || !writable(rc + 0x10, 8)
            || !writable(rc + 0xe660, 504)
        {
            return Err(err());
        }
        let plan = (rc + 0xe660) as *mut u8;
        if word(plan as usize + 0x1c8) != Some(team) {
            return Err("cached team changed".into());
        }
        // RefCell exclusive borrow mirrors native client mutation callbacks.
        let flag = (rc + 0x10) as *mut usize;
        *flag = usize::MAX;
        let _borrow = BorrowGuard(flag);
        self.apply_plan(plan, rows)
    }
    unsafe fn apply_plan(self, plan: *mut u8, rows: &[Assignment]) -> Result<usize, String> {
        self.apply_plan_inner(plan, rows, |api, p| api.serialize(0x101197fc4, p))
    }
    unsafe fn apply_plan_inner(
        self,
        plan: *mut u8,
        rows: &[Assignment],
        serialize_clone: impl FnOnce(Self, *const u8) -> Result<Vec<u8>, String>,
    ) -> Result<usize, String> {
        let full_before = self.serialize(0x101197fc4, plan)?;
        let before = self.serialize(0x1017007e0, plan.add(0x198))?;
        let current = planner::decode_map(&before)?;
        let next = planner::changed_map(&current, rows);
        let changed = rows
            .iter()
            .filter(|r| r.target.is_some() && current.get(&r.athlete) != next.get(&r.athlete))
            .count();
        if changed == 0 {
            return Ok(0);
        }
        let prefix = full_before
            .len()
            .checked_sub(before.len())
            .ok_or_else(err)?;
        let wire = planner::encode_map(&next);
        let mut map = OwnedMap::decoded(self, &wire)?;
        // Native allocations are created, cloned, and destroyed by the same game.
        // Never construct a Rust std HashMap/String/Vec with the mod's ABI.
        let mut clone = OwnedPlan::cloned(self, plan);
        let dst = clone.pointer().add(0x198);
        self.call1(0x10226bd28, dst);
        std::ptr::copy_nonoverlapping(map.words.as_ptr().cast::<u8>(), dst, 48);
        map.live = false; // Ownership moved into the native cloned plan.
        let verify = self
            .serialize(0x1017007e0, dst)
            .and_then(|b| planner::decode_map(&b));
        let full_after = serialize_clone(self, clone.pointer())?;
        if verify.as_ref().ok() != Some(&next)
            || full_after.get(..prefix) != full_before.get(..prefix)
        {
            return Err(err());
        }
        self.call1(0x1020b0ce0, plan);
        std::ptr::copy_nonoverlapping(clone.words.as_ptr().cast::<u8>(), plan, 504);
        clone.live = false; // Ownership moved into the authoritative/client plan.
        Ok(changed)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    unsafe extern "C" {
        fn dlopen(path: *const c_char, mode: i32) -> *mut c_void;
    }
    #[test]
    #[ignore]
    fn actual_arm64_campaign_plan_commit_preserves_other_fields_and_teams() {
        unsafe {
            let path = std::env::var("TFM_NATIVE_FIXTURE")
                .expect("explicit private fixture path required");
            let c = std::ffi::CString::new(path).unwrap();
            assert!(!dlopen(c.as_ptr(), 2 | 4 | 0x100).is_null());
            let api = Native::find().expect("all exact native function pins");
            let wire = std::fs::read(
                std::env::var("TFM_DB_FIXTURE")
                    .expect("explicit private campaign fixture required"),
            )
            .unwrap();
            let mut db = vec![0usize; 1024 * 1024 / 8];
            let mut offset = 0usize;
            let f: unsafe extern "C" fn(*mut usize, *const u8, usize, *mut usize) =
                std::mem::transmute(api.at(0x100e336ec));
            f(db.as_mut_ptr(), wire.as_ptr(), wire.len(), &mut offset);
            assert_ne!(db[0], usize::MAX);
            assert_eq!(offset, wire.len());
            let address = db.as_mut_ptr() as usize;
            let map = address + 0x17938;
            let len = word(map + 0x18).unwrap();
            assert!(len > 1 && len < 512);
            let head = word(map + 0x20).unwrap();
            let mut node = word(head + 0x200).unwrap();
            let mut snapshots = Vec::new();
            for _ in 0..len {
                let team = word(node + 0x208).unwrap();
                snapshots.push((team, api.serialize(0x101197fc4, node as *const u8).unwrap()));
                node = word(node + 0x200).unwrap();
            }
            assert_eq!(node, head);
            let team = snapshots[0].0;
            let plan = api.plan(address, team).unwrap();
            let before = api.serialize(0x1017007e0, plan.add(0x198)).unwrap();
            let old = planner::decode_map(&before).unwrap();
            let actor = old.keys().copied().next().unwrap_or(0);
            let rows = [Assignment {
                athlete: actor,
                position: Some(0),
                target: Some("knight:50|archer:50".into()),
                label: String::new(),
            }];
            let mut state = [0usize; 8];
            state[2] = address;
            let mut raw = ServerCtxV1 {
                size: size_of::<ServerCtxV1>(),
                vtable: api.at(0x104466940) as *const mod_api_stable::ServerVtableV1,
                state: state.as_mut_ptr().cast(),
            };
            let original_wire = api.serialize(0x101197fc4, plan).unwrap();
            let drops = OWNED_PLAN_DROPS.load(std::sync::atomic::Ordering::SeqCst);
            assert!(api
                .apply_plan_inner(plan, &rows, |_, _| Err(
                    "injected serialization refusal".into()
                ))
                .is_err());
            assert_eq!(
                OWNED_PLAN_DROPS.load(std::sync::atomic::Ordering::SeqCst),
                drops + 1
            );
            assert_eq!(api.serialize(0x101197fc4, plan).unwrap(), original_wire);
            assert!(api
                .apply_plan_inner(plan, &rows, |_, _| Ok(vec![0]))
                .is_err());
            assert_eq!(
                OWNED_PLAN_DROPS.load(std::sync::atomic::Ordering::SeqCst),
                drops + 2
            );
            assert_eq!(api.serialize(0x101197fc4, plan).unwrap(), original_wire);
            assert!(OwnedMap::decoded(api, &[1]).is_err());
            assert_eq!(api.apply(&mut raw, team, &rows).unwrap(), 1);
            assert_eq!(api.apply_database(address, team, &rows).unwrap(), 0);
            let after = api.serialize(0x1017007e0, plan.add(0x198)).unwrap();
            assert_eq!(
                planner::decode_map(&after).unwrap(),
                planner::changed_map(&old, &rows)
            );
            let all = api.serialize(0x101197fc4, plan).unwrap();
            let prefix = snapshots[0].1.len() - before.len();
            assert_eq!(&all[..prefix], &snapshots[0].1[..prefix]);
            // Save round-trip uses the original Database serializer and decoder only in memory.
            let database_wire = api.serialize(0x100e7ac10, db.as_ptr().cast()).unwrap();
            let mut saved = vec![0usize; 1024 * 1024 / 8];
            offset = 0;
            f(
                saved.as_mut_ptr(),
                database_wire.as_ptr(),
                database_wire.len(),
                &mut offset,
            );
            assert_eq!(offset, database_wire.len());
            assert_ne!(saved[0], usize::MAX);
            let saved_plan = api.plan(saved.as_mut_ptr() as usize, team).unwrap();
            assert_eq!(
                planner::decode_map(&api.serialize(0x1017007e0, saved_plan.add(0x198)).unwrap())
                    .unwrap(),
                planner::changed_map(&old, &rows)
            );
            for (other, before) in snapshots.iter().skip(1) {
                assert_eq!(
                    api.serialize(0x101197fc4, api.plan(address, *other).unwrap())
                        .unwrap(),
                    *before
                );
            }
            // Actual native ClientDatabase::default initializes the cached plan.
            let mut rc = vec![0usize; 1024 * 1024 / 8];
            rc[0] = 1;
            rc[1] = 1;
            asm!("blr x9",in("x9")api.at(0x10237b5bc),in("x8")(rc.as_mut_ptr()as *mut u8).add(0x18),clobber_abi("C"));
            let cached = (rc.as_mut_ptr() as *mut u8).add(0xe660);
            api.call1(0x1020b0ce0, cached);
            api.copy(cached, plan);
            let mut scene = [0usize; 64];
            scene[0] = 6;
            scene[7] = rc.as_mut_ptr() as usize;
            let mut client_state = [0usize; 32];
            client_state[0x68 / 8] = scene.as_mut_ptr() as usize;
            let mut client: mod_api_stable::ClientCtxV1 = std::mem::zeroed();
            client.size = size_of::<mod_api_stable::ClientCtxV1>();
            client.data = api.at(0x10446b758) as *const mod_api_stable::DataVtableV1;
            client.state = client_state.as_mut_ptr().cast();
            let client_rows = [Assignment {
                athlete: actor,
                position: Some(0),
                target: Some("archer:100".into()),
                label: String::new(),
            }];
            assert_eq!(
                api.apply_client(&mut client, team, &client_rows).unwrap(),
                1
            );
            assert_eq!(rc[2], 0);
            assert_eq!(
                planner::decode_map(&api.serialize(0x1017007e0, cached.add(0x198)).unwrap())
                    .unwrap()[&actor],
                "archer:100"
            );
            rc[2] = 1;
            assert!(api.apply_client(&mut client, team, &client_rows).is_err());
            assert_eq!(rc[2], 1);
            rc[2] = 0;
            assert!(api
                .apply_client(&mut client, team + 1000, &client_rows)
                .is_err());
            let clear = [Assignment {
                athlete: actor,
                position: Some(0),
                target: Some(String::new()),
                label: String::new(),
            }];
            assert_eq!(api.apply_database(address, team, &clear).unwrap(), 1);
            assert!(
                !planner::decode_map(&api.serialize(0x1017007e0, plan.add(0x198)).unwrap())
                    .unwrap()
                    .contains_key(&actor)
            );
            // Exercise the complete production server planner on the actual 11-person team0 roster.
            let mut ctx = mod_api_stable::StableServerCtx::from_raw(&mut raw).unwrap();
            let roster: Vec<_> = ctx
                .record_ids(mod_api_stable::RecordKindV1::Athlete)
                .into_iter()
                .filter(|&id| {
                    ctx.athlete_get_json(id, "contract")
                        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                        .and_then(|v| planner::contract_team(&v))
                        == Some(0)
                })
                .collect();
            assert_eq!(roster.len(), 11);
            let root: serde_json::Value =
                serde_json::from_str(&ctx.team_get_json(0, "").unwrap()).unwrap();
            assert_eq!(root["last_starting"].as_array().unwrap().len(), 5);
            assert!(root["champion_tiers"].is_object());
            // Seed only this in-memory test Database's tier prerequisites, using its real stable setter.
            assert!(ctx.team_set_json(
                0,
                "champion_tiers",
                r#"{"knight":"S","archer":"A","berserker":"B","priest":"C"}"#
            ));
            let body=serde_json::json!({"roles":[2,2,2,2,2],"nonce":"actual-fixture","champions":[{"name":"knight","category":0},{"name":"archer","category":0},{"name":"berserker","category":0},{"name":"priest","category":0}]}).to_string();
            let complete_before: Vec<_> = snapshots
                .iter()
                .map(|(id, _)| {
                    (
                        *id,
                        api.serialize(0x101197fc4, api.plan(address, *id).unwrap())
                            .unwrap(),
                    )
                })
                .collect();
            let team0_before_map = api
                .serialize(0x1017007e0, api.plan(address, 0).unwrap().add(0x198))
                .unwrap();
            let server = crate::Server::default();
            let mut command = mod_api_stable::StableCommand {
                command: "tvp_apply",
                payload: body.as_bytes(),
                sender_player_id: None,
                sender_team_id: None,
            };
            assert!(server.apply(&mut raw, &mut ctx, &command).is_err());
            command.sender_team_id = Some(0);
            let result = server.apply(&mut raw, &mut ctx, &command).unwrap();
            assert_eq!(result.1, 0);
            assert_eq!(result.2.len(), 11);
            assert!(result.2.iter().all(|r| roster.contains(&r.athlete)
                && r.target.as_deref() == Some("knight:25|archer:25|berserker:25|priest:25")));
            assert!(server.apply(&mut raw, &mut ctx, &command).is_err());
            let team0plan = api.plan(address, 0).unwrap();
            let finalmap =
                planner::decode_map(&api.serialize(0x1017007e0, team0plan.add(0x198)).unwrap())
                    .unwrap();
            for id in &roster {
                assert_eq!(finalmap[id], "knight:25|archer:25|berserker:25|priest:25");
            }
            for (id, before) in &complete_before {
                let now = api
                    .serialize(0x101197fc4, api.plan(address, *id).unwrap())
                    .unwrap();
                if *id == 0 {
                    let prefix = before.len() - team0_before_map.len();
                    assert_eq!(&now[..prefix], &before[..prefix]);
                } else {
                    assert_eq!(&now, before);
                }
            }
            let save_wire = api.serialize(0x100e7ac10, db.as_ptr().cast()).unwrap();
            let mut reload = vec![0usize; 1024 * 1024 / 8];
            offset = 0;
            f(
                reload.as_mut_ptr(),
                save_wire.as_ptr(),
                save_wire.len(),
                &mut offset,
            );
            assert_eq!(offset, save_wire.len());
            let savedplan = api.plan(reload.as_mut_ptr() as usize, 0).unwrap();
            assert_eq!(
                planner::decode_map(&api.serialize(0x1017007e0, savedplan.add(0x198)).unwrap())
                    .unwrap(),
                finalmap
            );
            println!("actual team0 complete server handler: 11 roster assignments; nested contracts; player-scope/replay guards; save-codec roundtrip PASS");
            println!("actual ARM64 campaign: {len} team plans; set/replay/clear/save-codec-roundtrip pass; other fields/teams identical; no save written");
        }
    }
}
