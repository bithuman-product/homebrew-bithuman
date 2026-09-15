// DeviceAuthShim — bridges to OPTIONAL engine auth hooks, compiled in only
// when the staged engine exports them.
//
// Offline-token program Component 4 (mobile = CLOUD-token path). This plugin
// currently vendors NO auth-bearing engine (libessence was removed; the
// embody/elevate ultras carry no baked heartbeat yet — their enforcement
// gate is Component 1/2, shipped DARK). Every bh_try_* call below is therefore
// a no-op returning -1 today.
//
// The moment an auth-bearing engine is vendored (one exporting the ADDITIVE
// `be_auth_set_request_signer` / `be_internal_sealed_store_register` C ABI
// from bithuman-models models/essence-1/engine/essence), the podspec's
// `nm` probe finds both symbols in the staged .a, defines
// BH_ENGINE_AUTH_HOOKS=1, and the same shim starts registering the
// Secure-Enclave request signer and the Keychain sealed-counter store with no
// further code changes.
//
// ★Why a preprocessor gate and not `weak_import` (2026-09-15): this file used
// to declare the two hooks `__attribute__((weak_import))` and null-check them.
// That does NOT make a STATIC link tolerate their absence — the product app
// linking this pod against the vendored libessence2 (essence2-v1.2.0, which
// exports neither symbol) failed on Xcode 26.3 with
//   Undefined symbols for architecture arm64: _be_auth_set_request_signer,
//   _be_internal_sealed_store_register, referenced from DeviceAuthShim.o
// so every consumer of the plugin since the shim landed could compile and
// could not link. weak_import only defers resolution for symbols that live in
// a dynamic library; nothing here does. The gate below is decided by the
// bytes actually staged, never by a declaration.

#include <stdint.h>
#include <stddef.h>

// --- runtime-token request signer (be_auth_set_request_signer) --------------
typedef int32_t (*bh_signer_fn)(const char* string_to_sign,
                                char* sig_b64u, size_t sig_cap,
                                char* pub_b64u, size_t pub_cap,
                                char* alg,      size_t alg_cap,
                                void* user);
/// Returns 0 when registered, -1 when the linked engine set lacks the hook
/// (the DARK default in this plugin today).
#if BH_ENGINE_AUTH_HOOKS
extern int32_t be_auth_set_request_signer(bh_signer_fn fn, void* user);
int32_t bh_try_set_request_signer(bh_signer_fn fn, void* user) {
    return be_auth_set_request_signer(fn, user);
}
#else
int32_t bh_try_set_request_signer(bh_signer_fn fn, void* user) {
    (void)fn; (void)user;
    return -1;
}
#endif

// --- sealed usage-counter store (be_internal_sealed_store_register) ---------
typedef int32_t (*bh_sealed_put_fn)(const char* name, const uint8_t* blob,
                                    size_t len, void* user);
typedef int32_t (*bh_sealed_get_fn)(const char* name, uint8_t* blob,
                                    size_t* len, void* user);
typedef int32_t (*bh_sealed_erase_fn)(const char* name, void* user);
/// Returns 0 when registered, -1 when the linked engine set lacks the hook.
#if BH_ENGINE_AUTH_HOOKS
extern int32_t be_internal_sealed_store_register(bh_sealed_put_fn put,
                                                 bh_sealed_get_fn get,
                                                 bh_sealed_erase_fn erase,
                                                 void* user);
int32_t bh_try_register_sealed_store(bh_sealed_put_fn put, bh_sealed_get_fn get,
                                     bh_sealed_erase_fn erase, void* user) {
    return be_internal_sealed_store_register(put, get, erase, user);
}
#else
int32_t bh_try_register_sealed_store(bh_sealed_put_fn put, bh_sealed_get_fn get,
                                     bh_sealed_erase_fn erase, void* user) {
    (void)put; (void)get; (void)erase; (void)user;
    return -1;
}
#endif
