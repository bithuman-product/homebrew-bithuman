// BHObjCException.m — see BHObjCException.h.
//
// Pure Obj-C (.m, NOT .mm): keeps the header importable into the Swift-Clang
// module without dragging C++ into the umbrella.

#import "BHObjCException.h"

NSException * _Nullable bh_tryRun(__attribute__((noescape)) void (^block)(void)) {
  @try {
    block();
    return nil;
  }
  @catch (NSException *e) {
    return e;
  }
}
