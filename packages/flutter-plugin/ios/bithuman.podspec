# bithuman — iOS native podspec (embody-only).
#
# The default avatar is the pure-Swift/CoreML Expression2Runtime and the only
# always-linked module-map xcframework is `libconverse.xcframework` (the
# on-device conversation brain — llama.cpp + Supertonic merged into one static
# .a). The essence (libessence) engine has been removed; the elevate engine is
# back as an OPTIONAL on-device avatar (essence2), but NOT as a second module-map
# xcframework: two vendored C-module xcframeworks break each other's Clang module
# resolution. Instead the prebuilt **static** `libessence2.a` (the be_essence2_* C
# ABI) is vendored by scripts/bootstrap.sh as a plain `s.vendored_libraries`, and
# its header (Engines/essence2/include/be_essence2.h) is folded into THIS pod's own
# auto-generated umbrella module; the spec sets the `ESSENCE2_AVAILABLE` Swift
# compilation condition only when `Frameworks/libessence2.a` is present. (Embody
# render is macOS-only today; the essence2 runtime adapter is `#if os(macOS)`-
# gated, so on iOS its be_essence2 symbols dead-strip — the vendored lib just
# keeps the pod consistent across both slices.)
#
# libconverse.xcframework + the per-agent embody CoreML models land in the
# plugin tree via scripts/bootstrap.sh (an embody Release vendor bundle, or a
# sibling bithuman-sdk checkout for SDK contributors). Nothing is committed.
#
# Apache-2.0; (c) bitHuman.

Pod::Spec.new do |s|
  # The umbrella is an N-engine AGGREGATOR (design §2.2): each staged engine SDK
  # drops its adapter SOURCE under Engines/<engine>/Classes, its C ABI header
  # under Engines/<engine>/include, and its PLAIN STATIC lib under
  # Engines/<engine>/Vendor/*.a. The OPTIONAL on-device Essence2 (essence2) engine
  # is enabled only when its static lib has been staged. Everything engine-native
  # below (vendored_libraries, the ESSENCE2_AVAILABLE Swift gate, the libessence2
  # resource bundles) is gated on a staged engine .a existing, so the embody-only
  # install is byte-identical. (The essence2 runtime now compiles for iOS too —
  # gate `#if (os(macOS) || os(iOS)) && ESSENCE2_AVAILABLE` — linking the iOS
  # libessence2.a slice + the static non-SME2 onnxruntime.xcframework.)
  engine_libs = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.a'))
  essence2_lib = !engine_libs.empty?

  # INVARIANT #1 (design §0.2) — CI ASSERT: an engine's native core is a PLAIN
  # STATIC .a, NEVER a 2nd module-map (C-module) xcframework (two would break each
  # other's Clang module resolution — the clash 3b53fc0 fixed). The single
  # module-map xcframework slot is reserved for libconverse (onnxruntime below is a
  # plain binary framework, not a C-module one). Fail the pod build loudly if any
  # staged engine ever vendors an xcframework instead of a .a.
  engine_xcframeworks = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.xcframework'))
  raise "INVARIANT #1 violated: engine(s) vendored a module-map xcframework #{engine_xcframeworks.inspect} — every avatar engine must be a plain static .a" unless engine_xcframeworks.empty?

  s.name             = 'bithuman'
  s.version          = '0.0.1'
  s.summary          = 'bitHuman avatar Flutter plugin'
  s.description      = 'Real-time embody avatar + OpenAI Realtime / on-device converse chat'
  s.homepage         = 'https://bithuman.ai'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'bitHuman' => 'hello@bithuman.ai' }
  s.source           = { :http => 'https://github.com/bithuman-product/expression-2' }
  # Swift + the BHObjCException Obj-C @try/@catch shim (.h/.m). The shim lets
  # Swift recover from AVAudioEngine's uncatchable NSException raises during
  # device hot-swaps; public_header_files + DEFINES_MODULE=>YES make CocoaPods
  # auto-generate the umbrella + module map so the pod's Swift sees bh_tryRun
  # with no bridging header / no `import`. Header is pure Obj-C (.m, never .mm).
  # Engine-agnostic glue (Classes/**) PLUS every staged engine adapter source +
  # its C ABI header (Engines/**), folded into THIS pod's own umbrella module so
  # the staged engine Swift calls be_essence2_* with no `import` (INVARIANT #1's
  # mechanism, generalized to N engines).
  s.source_files        = 'Classes/**/*.{swift,h,m}', 'Engines/**/Classes/**/*.swift', 'Engines/**/include/**/*.h'
  s.public_header_files = 'Classes/**/*.h', 'Engines/**/include/**/*.h'
  # Assets/embody — the per-agent embody CoreML models (the A42 demo bundle).
  # Expression2Runtime probes Bundle subdirectory "embody". Populated by
  # scripts/bootstrap.sh (not committed).
  pod_resources = ['Assets/embody']
  # PLUS libessence2's iOS-DEVICE runtime resource bundles when essence2 is
  # vendored (the iOS metallib is per-platform — NOT the macOS one):
  # mlx-swift_Cmlx.bundle/default.metallib + the iOS Expression bundle. Gated on
  # essence2_lib so the embody-only install lists zero extra resources.
  pod_resources << 'Engines/*/Vendor/*-resources/*.bundle' if essence2_lib
  # PLUS the shared a2x wav2vec2 frontend (a2x_w2v.fp32.onnx / .int8.onnx) — a
  # LOOSE file under the engine's *-resources dir, NOT a .bundle, so the glob
  # above misses it. DirectorRuntime.resolveA2XW2VPath() locates it in
  # Bundle.main.resourcePath at runtime; CocoaPods copies these straight into the
  # app Resources/. Gated on the file actually being present.
  # (essence2 now runs on iOS too, so the a2x w2v frontend is live there.)
  if essence2_lib && !Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*-resources/a2x_w2v.*.onnx')).empty?
    pod_resources << 'Engines/*/Vendor/*-resources/a2x_w2v.*.onnx'
  end
  s.resources = pod_resources
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'
  # Static framework so unresolved libconverse symbols carry through to the app.
  s.static_framework = true

  # libconverse.xcframework — the on-device conversation brain (LOCAL mode:
  # llama.cpp + Supertonic merged into one static .a). Its
  # Headers/module.modulemap declares `module CConverse`. ggml-metal needs
  # Metal/MetalKit at the app link step (added to common_frameworks below) and
  # Supertonic's ORT symbols resolve from the onnxruntime.xcframework vendored
  # below. embody itself is pure Swift/CoreML and links no native engine.
  #
  # INVARIANT #1 (design §0.2) — CI ASSERT: EXACTLY ONE module-map (C-module)
  # xcframework per pod, reserved for libconverse. Every avatar engine's native
  # core is a PLAIN static .a (s.vendored_libraries below), NEVER a 2nd module-map
  # xcframework (two vendored C-module xcframeworks break each other's Clang module
  # resolution — the clash 3b53fc0 fixed). onnxruntime.xcframework is a PLAIN binary
  # framework (no Clang module map), so it does NOT occupy the module-map slot. Fail
  # the pod build loudly if a future change ever adds a second module-map xcframework.
  module_map_xcframeworks = ['Frameworks/libconverse.xcframework']
  raise "INVARIANT #1 violated: expected exactly 1 module-map xcframework (libconverse), got #{module_map_xcframeworks.length}: #{module_map_xcframeworks.inspect}" unless module_map_xcframeworks.length == 1
  s.vendored_frameworks = ['Frameworks/onnxruntime.xcframework'] + module_map_xcframeworks
  # Each staged engine's native core = a plain static lib (NEVER a 2nd module-map
  # xcframework). Auto-picked from Engines/*/Vendor/*.a (design §2.2's Dir.glob).
  # libessence2 (OPTIONAL on-device Essence2 / essence2 — the be_essence2_* C ABI
  # used by Essence2Runtime.swift) is vendored as a plain STATIC LIBRARY, NOT a
  # second module-map xcframework: two vendored C-module xcframeworks break each
  # other's module resolution. Its header is served from this pod's own umbrella
  # (Engines/essence2/include/be_essence2.h). Vendored by scripts/bootstrap.sh only when
  # an Essence2 vendor surface is present (essence2_lib). NOTE the essence2 runtime
  # adapter is `#if os(macOS)`-gated, so its be_essence2 symbols dead-strip on iOS
  # — the entry keeps the pod consistent across slices (as libconverse already is).
  s.vendored_libraries  = engine_libs.map { |p| p.sub(__dir__ + '/', '') } if essence2_lib

  # Metal/MetalKit: ggml-metal (libconverse LOCAL mode). CoreML/Accelerate:
  # embody's CoreML graphs + vImage frame conversion. AudioToolbox/CoreAudio:
  # libconverse's miniaudio (Supertonic resampler). MetalPerformanceShaders +
  # MetalPerformanceShadersGraph: libessence2's statically-linked MLX (harmless
  # for the embody-only / iOS-cloud build — unreferenced, the linker dead-strips).
  common_frameworks =
    '-lz -liconv -lc++ ' \
    '-framework Foundation -framework CoreML -framework CoreFoundation ' \
    '-framework Accelerate -framework VideoToolbox -framework AudioToolbox ' \
    '-framework CoreMedia -framework CoreVideo -framework UIKit ' \
    '-framework Metal -framework MetalKit ' \
    '-framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph ' \
    '-framework AVFoundation -framework CoreGraphics -framework QuartzCore'

  # Pod-target xcconfig: applies to the bithuman pod build itself.
  pod_xcconfig = {
    'DEFINES_MODULE'                       => 'YES',
    # onnxruntime.xcframework's sim slice is arm64-only on Apple Silicon hosts.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
    'CLANG_CXX_LANGUAGE_STANDARD'          => 'c++17',
    'CLANG_CXX_LIBRARY'                    => 'libc++',
    'ENABLE_BITCODE'                       => 'NO',
  }
  # Set the ESSENCE2_AVAILABLE Swift active-compilation-condition ONLY when the
  # static libessence2.a is vendored — the gate Essence2Engine.swift +
  # BithumanAvatarPlugin.swift compile against. (The essence2 adapter compiles for
  # BOTH macOS and iOS now — `#if (os(macOS) || os(iOS)) && ESSENCE2_AVAILABLE` —
  # so on iOS this flag is what turns the on-device a2x engine ON.)
  pod_xcconfig['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) ESSENCE2_AVAILABLE' if essence2_lib
  s.pod_target_xcconfig = pod_xcconfig

  # User-target xcconfig: applies to the consuming app (Runner) target so its
  # final link step pulls in the system frameworks libconverse needs.
  # libconverse.a + onnxruntime come from the vendored xcframeworks, which
  # CocoaPods links automatically.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => "$(inherited) #{common_frameworks}",
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
  }
end
