// DeviceAuthShim — weak-linked bridges to OPTIONAL engine auth hooks.
//
// Offline-token program Component 4 (mobile = CLOUD-token path). This plugin
// currently vendors NO auth-bearing engine (libessence was removed; the
// embody/elevate ultras carry no baked heartbeat yet — their enforcement
// gate is Component 1/2, shipped DARK). The hooks below therefore resolve
// to NULL today and every bh_try_* call is a no-op returning -1.
//
// The moment an auth-bearing engine is vendored (one exporting the ADDITIVE
// `be_auth_set_request_signer` / `be_internal_sealed_store_register` C ABI
// from bithuman-models models/essence-1/engine/essence), the same plugin
// binary starts registering the Secure-Enclave request signer and the
// Keychain sealed-counter store with zero further code changes.
//
// weak_import (not dlsym): libessence exports are compiled with hidden
// visibility, so dlsym can never see them in a statically linked image;
// a weak external reference is resolved (or NULLed) by the linker/dyld
// regardless of visibility.

#include <stdint.h>
#include <stddef.h>

// --- runtime-token request signer (be_auth_set_request_signer) --------------
typedef int32_t (*bh_signer_fn)(const char* string_to_sign,
                                char* sig_b64u, size_t sig_cap,
                                char* pub_b64u, size_t pub_cap,
                                char* alg,      size_t alg_cap,
                                void* user);
extern int32_t be_auth_set_request_signer(bh_signer_fn fn, void* user)
    __attribute__((weak_import));

/// Returns 0 when registered, -1 when the linked engine set lacks the hook
/// (the DARK default in this plugin today).
int32_t bh_try_set_request_signer(bh_signer_fn fn, void* user) {
    if (&be_auth_set_request_signer == NULL) return -1;
    return be_auth_set_request_signer(fn, user);
}

// --- sealed usage-counter store (be_internal_sealed_store_register) ---------
typedef int32_t (*bh_sealed_put_fn)(const char* name, const uint8_t* blob,
                                    size_t len, void* user);
typedef int32_t (*bh_sealed_get_fn)(const char* name, uint8_t* blob,
                                    size_t* len, void* user);
typedef int32_t (*bh_sealed_erase_fn)(const char* name, void* user);
extern int32_t be_internal_sealed_store_register(bh_sealed_put_fn put,
                                                 bh_sealed_get_fn get,
                                                 bh_sealed_erase_fn erase,
                                                 void* user)
    __attribute__((weak_import));

/// Returns 0 when registered, -1 when the linked engine set lacks the hook.
int32_t bh_try_register_sealed_store(bh_sealed_put_fn put, bh_sealed_get_fn get,
                                     bh_sealed_erase_fn erase, void* user) {
    if (&be_internal_sealed_store_register == NULL) return -1;
    return be_internal_sealed_store_register(put, get, erase, user);
}
