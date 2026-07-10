// SealedCounterStore — Keychain-backed sealed-blob storage STUB for the
// BHL v2 offline usage meter (offline-token program Component 2 wiring
// point; design §3.3 rows "iOS"/"macOS").
//
// STATUS: STUB / DARK. The engine-side meter does not exist in the vendored
// engines yet; `registerWithEngine()` goes through the weak-linked
// `be_internal_sealed_store_register` hook and is a no-op returning false
// today. Zero callers, zero behavior impact — this is the platform half
// Component 2 wires up when the metered kiosk engine lands.
//
// MOBILE-OFFLINE IS NOT-OFFERED (owner decision 2026-07, see
// DeviceIdentity.offlineEntitlementOffered): phones stay on the online
// cloud-token path. This store exists ONLY for the enterprise/kiosk SKU
// (macOS kiosk hardware running a metered offline pack). Honest limit per
// the design: Keychain protects at the OS-account boundary, not against a
// root/admin snapshot-restore between reconciles — which is why kiosk-tier
// packs carry a mandatory reconcile interval.
//
// Storage: Keychain generic-password items, ThisDeviceOnly + AfterFirstUnlock
// (never synced/migrated). Fail-closed contract for the future meter:
// missing / undecodable blob == pack EXHAUSTED, never a fresh pack.

import Foundation
import Security

@_silgen_name("bh_try_register_sealed_store")
private func bh_try_register_sealed_store(
  _ put: SealedCounterStore.PutFn?,
  _ get: SealedCounterStore.GetFn?,
  _ erase: SealedCounterStore.EraseFn?,
  _ user: UnsafeMutableRawPointer?) -> Int32

enum SealedCounterStore {
  /// Mirror of the NOT-OFFERED marker for discoverability.
  static let offeredOnMobile = false

  private static let service = "ai.bithuman.sealed-counter.v1"

  // Return codes mirror engine sealed_counter_store.h (SealedStoreRc).
  static let rcOk: Int32 = 0
  static let rcNotFound: Int32 = 1
  static let rcIoError: Int32 = -2
  static let rcBadArg: Int32 = -3

  // MARK: - Keychain blob store

  private static func nameOk(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64 else { return false }
    return name.allSatisfy {
      $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
    }
  }

  private static func baseQuery(_ name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
  }

  static func put(_ name: String, blob: Data) -> Int32 {
    guard nameOk(name) else { return rcBadArg }
    var add = baseQuery(name)
    add[kSecValueData as String] = blob
    add[kSecAttrAccessible as String] =
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(
        baseQuery(name) as CFDictionary,
        [kSecValueData as String: blob] as CFDictionary)
    }
    return status == errSecSuccess ? rcOk : rcIoError
  }

  static func get(_ name: String) -> (rc: Int32, blob: Data?) {
    guard nameOk(name) else { return (rcBadArg, nil) }
    var query = baseQuery(name)
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return (rcNotFound, nil) }
    guard status == errSecSuccess, let data = item as? Data else {
      return (rcIoError, nil)  // undecodable == tampered == fail closed upstream
    }
    return (rcOk, data)
  }

  static func erase(_ name: String) -> Int32 {
    guard nameOk(name) else { return rcBadArg }
    let status = SecItemDelete(baseQuery(name) as CFDictionary)
    if status == errSecItemNotFound { return rcNotFound }
    return status == errSecSuccess ? rcOk : rcIoError
  }

  // MARK: - Engine registration (weak-linked; DARK today)

  typealias PutFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int,
    UnsafeMutableRawPointer?) -> Int32
  typealias GetFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?,
    UnsafeMutablePointer<Int>?, UnsafeMutableRawPointer?) -> Int32
  typealias EraseFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32

  /// Register the Keychain store with an engine exposing the sealed-store
  /// hook. Returns false when no vendored engine exports it (today's DARK
  /// default in this plugin). Component 2 calls this from the kiosk
  /// enforcement bring-up.
  @discardableResult
  static func registerWithEngine() -> Bool {
    let put: PutFn = { name, blob, len, _ in
      guard let name else { return SealedCounterStore.rcBadArg }
      let data = (blob != nil && len > 0)
        ? Data(bytes: blob!, count: len) : Data()
      return SealedCounterStore.put(String(cString: name), blob: data)
    }
    let get: GetFn = { name, blob, len, _ in
      guard let name, let blob, let len else { return SealedCounterStore.rcBadArg }
      let (rc, data) = SealedCounterStore.get(String(cString: name))
      guard rc == SealedCounterStore.rcOk, let data else { return rc }
      guard data.count <= len.pointee else { return SealedCounterStore.rcIoError }
      data.withUnsafeBytes { raw in
        _ = memcpy(blob, raw.baseAddress, data.count)
      }
      len.pointee = data.count
      return SealedCounterStore.rcOk
    }
    let erase: EraseFn = { name, _ in
      guard let name else { return SealedCounterStore.rcBadArg }
      return SealedCounterStore.erase(String(cString: name))
    }
    return bh_try_register_sealed_store(put, get, erase, nil) == 0
  }
}
