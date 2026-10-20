//! Small C ABI around RustCrypto SPAKE2. No protocol math is implemented here.
//! Callers provide an eight-digit code and a 32-byte authenticated context.
use spake2::{Ed25519Group, Identity, Password, Spake2};
use std::{collections::HashMap, panic::{catch_unwind, AssertUnwindSafe}, slice,
          sync::{Mutex, OnceLock}, sync::atomic::{AtomicU64, Ordering}};
use zeroize::Zeroize;

static STATES: OnceLock<Mutex<HashMap<u64, Spake2<Ed25519Group>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);

/// role 0 is the app, role 1 the core. Output is exactly 33 bytes.
/// All pointers refer to valid caller-owned buffers of the specified lengths.
#[no_mangle]
pub unsafe extern "C" fn ep_pake_start(role: u8, code: *const u8, context: *const u8, message: *mut u8) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        if code.is_null() || context.is_null() || message.is_null() || role > 1 { return 0; }
        let code = slice::from_raw_parts(code, 8);
        if !code.iter().all(u8::is_ascii_digit) { return 0; }
        let context = slice::from_raw_parts(context, 32);
        let identity_a = Identity::new(b"easyprivacy.pairing.v1.app");
        let identity_b = Identity::new(context);
        let password = Password::new(code);
        let mut states = match STATES.get_or_init(|| Mutex::new(HashMap::new())).lock() { Ok(s) => s, Err(_) => return 0 };
        if states.len() >= 256 { return 0; }
        let (state, outbound) = if role == 0 {
            Spake2::<Ed25519Group>::start_a(&password, &identity_a, &identity_b)
        } else {
            Spake2::<Ed25519Group>::start_b(&password, &identity_a, &identity_b)
        };
        if outbound.len() != 33 { return 0; }
        std::ptr::copy_nonoverlapping(outbound.as_ptr(), message, 33);
        let handle = NEXT.fetch_add(1, Ordering::Relaxed);
        states.insert(handle, state);
        handle
    })).unwrap_or(0)
}

/// Consumes the state even on failure. Peer is 33 bytes, output key 32 bytes.
#[no_mangle]
pub unsafe extern "C" fn ep_pake_finish(handle: u64, peer: *const u8, key: *mut u8) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if peer.is_null() || key.is_null() { return -1; }
        let state = match STATES.get_or_init(|| Mutex::new(HashMap::new())).lock() {
            Ok(mut states) => states.remove(&handle), Err(_) => return -1
        };
        let Some(state) = state else { return -1; };
        let mut shared = match state.finish(slice::from_raw_parts(peer, 33)) { Ok(s) => s, Err(_) => return -1 };
        if shared.len() != 32 { shared.zeroize(); return -1; }
        std::ptr::copy_nonoverlapping(shared.as_ptr(), key, 32);
        shared.zeroize();
        0
    })).unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn ep_pake_free(handle: u64) {
    let _ = catch_unwind(|| { if let Ok(mut states) = STATES.get_or_init(|| Mutex::new(HashMap::new())).lock() { states.remove(&handle); } });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trip_consumes_handles_and_binds_context() {
        for same_context in [true, false] {
            let a_context = [7u8; 32];
            let b_context = [if same_context {7} else {8}; 32];
            let mut a = [0; 33]; let mut b = [0; 33];
            let mut ka = [0; 32]; let mut kb = [0; 32];
            unsafe {
                let ah = ep_pake_start(0, b"01234567".as_ptr(), a_context.as_ptr(), a.as_mut_ptr());
                let bh = ep_pake_start(1, b"01234567".as_ptr(), b_context.as_ptr(), b.as_mut_ptr());
                assert_ne!(ah, 0); assert_ne!(bh, 0);
                assert_eq!(ep_pake_finish(ah, b.as_ptr(), ka.as_mut_ptr()), 0);
                assert_eq!(ep_pake_finish(bh, a.as_ptr(), kb.as_mut_ptr()), 0);
                assert_eq!(ka == kb, same_context);
                assert_eq!(ep_pake_finish(ah, b.as_ptr(), ka.as_mut_ptr()), -1);
            }
        }
    }
}
