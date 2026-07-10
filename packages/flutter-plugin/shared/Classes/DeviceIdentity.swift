// DeviceIdentity — hardware-derived billing fingerprint + device-bound
// request-signing for the CLOUD runtime-token path (offline-token program
// Component 4).
//
// MOBILE = CLOUD-TOKEN PATH (owner decision 2026-07): phones do NOT get
// offline device-bound entitlements — authorization stays entirely
// SERVER-SIDE on the existing runtime-token heartbeat. This file provides:
//
//   1. `fingerprint32()` — a STABLE hardware-derived billing fingerprint
//      (macOS IOPlatformUUID / iOS identifierForVendor, hashed with the
//      engine's domain-separation seed). Fixes the audit's "billing
//      fingerprint not hardware-bound" gap: the archived plugin passed nil
//      and the engine fell back to a random per-process value.
//   2. A Secure Enclave P-256 device key (Keychain software-key fallback
//      on hardware without SE) that signs each runtime-token request via
//      the weak-linked `be_auth_set_request_signer` hook, so a stolen
//      api_secret cannot be replayed off-device once the server enforces
//      signatures per-account.
//
// STATUS IN THIS PLUGIN: DARK. The vendored engines (converse + optional
// essence2 ultra) export no auth hooks yet, so `registerRequestSigner()`
// is a no-op returning false, and nothing here is called from the render
// path. When an auth-bearing engine is vendored (Component 1/2's
// enforcement gate, owner-gated), the wiring below lights up unchanged.
//
// NOT-OFFERED: `offlineEntitlementOffered == false` — sealed offline usage
// packs (BHL v2 budget licenses) are an enterprise/kiosk SKU only; do not
// build phone UX that assumes offline entitlement storage.

import CryptoKit
import Foundation
import Security

#if os(iOS)
import UIKit
#endif
#if os(macOS)
import IOKit
#endif

// Plugin-local weak bridge (DeviceAuthShim.m). Always present in this pod,
// so the reference is strong; the ENGINE hook behind it is weak-linked.
@_silgen_name("bh_try_set_request_signer")
private func bh_try_set_request_signer(
  _ fn: DeviceIdentity.SignerFn?, _ user: UnsafeMutableRawPointer?) -> Int32

enum DeviceIdentity {
  /// Mobile-offline is NOT-OFFERED (owner decision 2026-07): phones stay on
  /// the online cloud-token path. Offline BHL v2 usage packs are an
  /// enterprise/kiosk SKU only.
  static let offlineEntitlementOffered = false

  // Same domain-separation seed as engine machine_id.cpp — on macOS the
  // 32-char billing fingerprint is a strict prefix of the engine's 64-char
  // node-lock fingerprint (both hash the platform UUID).
  private static let fingerprintSeed = "bh-node-fingerprint-v1|"

  /// Stable, hardware-derived 32-hex-char billing fingerprint, or nil when
  /// no platform identifier is available (callers then let the engine use
  /// its legacy process-stable random fallback).
  static func fingerprint32() -> String? {
    guard let raw = rawIdentifier(), !raw.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data((fingerprintSeed + raw).utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(32))
  }

  private static func rawIdentifier() -> String? {
    #if os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString
    #elseif os(macOS)
    // IOPlatformUUID from IOPlatformExpertDevice — same value the engine's
    // gethostuuid() source yields. Port 0 == default master port (avoids
    // the kIOMasterPortDefault/kIOMainPortDefault rename).
    let expert = IOServiceGetMatchingService(
      0, IOServiceMatching("IOPlatformExpertDevice"))
    guard expert != 0 else { return nil }
    defer { IOObjectRelease(expert) }
    guard let uuid = IORegistryEntryCreateCFProperty(
      expert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String else { return nil }
    return uuid
    #else
    return nil
    #endif
  }

  // MARK: - Device key (Secure Enclave preferred, Keychain fallback)

  private static let keyTag = "ai.bithuman.device-key.p256.v1"
  private static let keyLock = NSLock()
  private static var cachedKey: SecKey?

  private static func deviceKey() -> SecKey? {
    keyLock.lock(); defer { keyLock.unlock() }
    if let k = cachedKey { return k }
    if let k = loadKey() ?? createKey() { cachedKey = k; return k }
    return nil
  }

  private static func loadKey() -> SecKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: Data(keyTag.utf8),
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let some = item else { return nil }
    // swiftlint:disable:next force_cast
    return (some as! SecKey)
  }

  private static func createKey() -> SecKey? {
    // Secure Enclave first; permanent software Keychain key when SE is
    // unavailable (VM, missing entitlement, Intel without T2). Both are
    // non-exportable through the API.
    for useEnclave in [true, false] {
      var privAttrs: [String: Any] = [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: Data(keyTag.utf8),
      ]
      if useEnclave {
        var aclError: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(
          kCFAllocatorDefault,
          kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
          [.privateKeyUsage], &aclError) else { continue }
        privAttrs[kSecAttrAccessControl as String] = acl
      } else {
        privAttrs[kSecAttrAccessible as String] =
          kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      }
      var attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: privAttrs,
      ]
      if useEnclave {
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
      }
      var error: Unmanaged<CFError>?
      if let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) {
        return key
      }
    }
    return nil
  }

  fileprivate static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// ES256 over the raw message (ECDSA-X962-SHA256, DER signature) under
  /// the device key. Nil on any failure — callers degrade to unsigned.
  fileprivate static func sign(message: Data) -> (sigDER: Data, pubX963: Data)? {
    guard let key = deviceKey(),
          let pub = SecKeyCopyPublicKey(key) else { return nil }
    var error: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA256,
            message as CFData, &error) as Data?,
          let pubData = SecKeyCopyExternalRepresentation(pub, &error) as Data?
    else { return nil }
    return (sig, pubData)
  }

  // MARK: - Engine hook registration (weak-linked; DARK in this plugin today)

  typealias SignerFn = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<CChar>?, Int,
    UnsafeMutablePointer<CChar>?, Int,
    UnsafeMutablePointer<CChar>?, Int,
    UnsafeMutableRawPointer?) -> Int32

  private static var registered = false

  /// Register the Secure-Enclave request signer with whatever auth-bearing
  /// engine is linked. Returns false — silently, the dark path — when no
  /// engine exports `be_auth_set_request_signer` (this plugin today) or no
  /// device key can be created.
  @discardableResult
  static func registerRequestSigner() -> Bool {
    keyLock.lock()
    let already = registered
    keyLock.unlock()
    if already { return true }
    guard deviceKey() != nil else { return false }
    let signer: SignerFn = { toSign, sig, sigCap, pub, pubCap, alg, algCap, _ in
      guard let toSign, let sig, let pub, let alg,
            sigCap > 1, pubCap > 1, algCap > 6 else { return -1 }
      let message = Data(String(cString: toSign).utf8)
      guard let out = DeviceIdentity.sign(message: message) else { return -1 }
      let sigB64 = DeviceIdentity.base64url(out.sigDER)
      let pubB64 = DeviceIdentity.base64url(out.pubX963)
      guard sigB64.utf8.count < sigCap, pubB64.utf8.count < pubCap
      else { return -1 }
      _ = sigB64.withCString { strlcpy(sig, $0, sigCap) }
      _ = pubB64.withCString { strlcpy(pub, $0, pubCap) }
      _ = "ES256".withCString { strlcpy(alg, $0, algCap) }
      return 0
    }
    let rc = bh_try_set_request_signer(signer, nil)
    if rc == 0 {
      keyLock.lock()
      registered = true
      keyLock.unlock()
    }
    return rc == 0
  }
}
