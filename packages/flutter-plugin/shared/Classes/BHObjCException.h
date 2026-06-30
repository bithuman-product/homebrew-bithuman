// BHObjCException.h — minimal Obj-C @try/@catch bridge.
//
// AVAudioEngine's installTap / connect / disconnectNodeInput / removeTap /
// attach / start raise Obj-C NSExceptions ("required condition is false: ...")
// that Swift's do/catch CANNOT catch — they unwind straight to abort()
// (SIGABRT). This shim runs a Swift closure inside an Obj-C @try and returns
// the NSException (nil on success) so the Swift caller can convert it into a
// recoverable Swift error and route it into the bounded device-swap retry.
//
// MUST stay pure Obj-C (.m, never .mm) so it imports cleanly into the pod's
// Swift-Clang module via the CocoaPods auto-generated umbrella header.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`; if it raises an Obj-C NSException, catches and returns it.
/// Returns nil on normal completion. The block is non-escaping (it runs
/// synchronously inside the @try), so Swift may capture `self` without an
/// escape/retain-cycle penalty.
NSException * _Nullable bh_tryRun(__attribute__((noescape)) void (^block)(void));

NS_ASSUME_NONNULL_END
