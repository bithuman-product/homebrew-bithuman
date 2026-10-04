// BHDeploymentFloor.h — the app's deployment target against the floor of the engines this pod links
// (2.6.36, security).
//
// The pod declares the floor of the engines scripts/bootstrap.sh staged (`s.platform`, read from the
// vendored binaries' LC_BUILD_VERSION minos). A FRESH `pod install` below that floor fails. But an app
// whose Podfile.lock already resolves this pod gets only a CocoaPods warning ("may not be compatible
// with `bithuman` which has a minimum requirement of iOS 26.0"), and then builds for its own, lower
// target while linking an engine built for 26: measured 2026-10-03 on Xcode 26.3, a Runner at iOS 16.0
// built and linked with no error, and such an app cannot start below iOS 18.4 / macOS 15.4
// (bithuman-models #1826).
//
// This header is in the pod's umbrella module, so the app's `@import bithuman` (Flutter's
// GeneratedPluginRegistrant.m on iOS) compiles it with the APP's deployment target. The pod defines
// BITHUMAN_IOS_FLOOR / BITHUMAN_MACOS_FLOOR (Availability.h format: 26.0 = 260000) in the APP target's
// preprocessor definitions (user_target_xcconfig), and only while the staged floor is above the base
// (iOS 16.0 / macOS 13.0); the pod's own target never defines them. An app below the floor fails its
// build here, by name, instead of shipping a binary that crashes at launch.
//
// The definitions reach the app through `$(inherited)`: an app target that sets
// GCC_PREPROCESSOR_DEFINITIONS without `$(inherited)` drops them and this check does nothing (the
// README says so). `pod install` below the floor still fails, and the linker still warns "built for
// newer 'iOS' version".
//
// Pure preprocessor: nothing here is compiled into the pod.

#pragma once

#include <Availability.h>
#include <TargetConditionals.h>

#if TARGET_OS_IOS && defined(BITHUMAN_IOS_FLOOR) && defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
#if __IPHONE_OS_VERSION_MIN_REQUIRED < BITHUMAN_IOS_FLOOR
#error "bithuman: the engines scripts/bootstrap.sh staged need a newer iOS than this app's deployment target, and an app linking them cannot start below iOS 18.4. Raise the app to the floor `pod install` printed (platform :ios in ios/Podfile and IPHONEOS_DEPLOYMENT_TARGET on the Runner target), or for iOS 16 bootstrap with BITHUMAN_SKIP_ESSENCE2=1 (Expression 2 only) and run pod install again."
#endif
#endif

#if TARGET_OS_OSX && defined(BITHUMAN_MACOS_FLOOR) && defined(__MAC_OS_X_VERSION_MIN_REQUIRED)
#if __MAC_OS_X_VERSION_MIN_REQUIRED < BITHUMAN_MACOS_FLOOR
#error "bithuman: the engines scripts/bootstrap.sh staged need a newer macOS than this app's deployment target, and an app linking them cannot start on older macOS. Raise the app to the floor `pod install` printed (platform :osx in macos/Podfile and MACOSX_DEPLOYMENT_TARGET on the Runner target; macOS 26.0 with today's engines) and run pod install again."
#endif
#endif
