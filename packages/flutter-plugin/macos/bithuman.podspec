# bithuman — macOS native podspec (embody-only).
#
# The default avatar is the pure-Swift/CoreML Expression2Runtime and the only
# always-linked native binary is `libconverse.xcframework` (the on-device
# conversation brain — llama.cpp + Supertonic merged into one static .a) — the
# ONLY module-map xcframework. The essence (libessence) engine has been removed.
# The elevate engine is back as an OPTIONAL on-device avatar (essence2), but NOT
# as a second module-map xcframework: two vendored C-module xcframeworks break
# each other's Clang module resolution. Instead the prebuilt **static**
# `libessence2.a` (the be_essence2_* C ABI) is vendored by scripts/bootstrap.sh as
# a plain `s.vendored_libraries`, and its header (Engines/essence2/include/be_essence2.h)
# is folded into THIS pod's own auto-generated umbrella module via
# DEFINES_MODULE + public_header_files — so the pod's Swift calls be_essence2_*
# with no `import`, exactly as it calls bh_tryRun (BHObjCException.h). The spec
# sets the `ESSENCE2_AVAILABLE` Swift active-compilation-condition only when
# `Frameworks/libessence2.a` is present; absent it, the essence2 path compiles
# out and the build stays embody-only, byte-identical, and shippable.
#
# libconverse needs llama.cpp from Homebrew at link + runtime via @rpath:
#   brew install llama.cpp
#
# libconverse.xcframework lands in the plugin tree via scripts/bootstrap.sh
# (an embody Release vendor bundle, or a sibling bithuman-sdk checkout for
# SDK contributors). The per-agent embody CoreML models land in Assets/embody.
#
# Apache-2.0; (c) bitHuman.

Pod::Spec.new do |s|
  # The umbrella is an N-engine AGGREGATOR (design §2.2): each staged engine SDK
  # drops its adapter SOURCE under Engines/<engine>/Classes, its C ABI header
  # under Engines/<engine>/include, and its PLAIN STATIC lib under
  # Engines/<engine>/Vendor/*.a (bootstrap.sh stages all of it). The OPTIONAL
  # on-device Essence2 (essence2) engine is enabled only when its static lib has
  # been staged. Everything engine-native below (vendored_libraries, the
  # ESSENCE2_AVAILABLE Swift gate, the libessence2 resource bundles) is gated on a
  # staged engine .a existing, so the embody-only install is byte-identical.
  engine_libs = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.a'))
  essence2_lib = !engine_libs.empty?

  # INVARIANT #1 (design §0.2) — CI ASSERT: an engine's native core is a PLAIN
  # STATIC .a, NEVER a 2nd module-map (C-module) xcframework (two would break each
  # other's Clang module resolution — the clash 3b53fc0 fixed). The single
  # module-map xcframework slot is reserved for libconverse. Fail the pod build
  # loudly if any staged engine ever vendors an xcframework instead of a .a.
  engine_xcframeworks = Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*.xcframework'))
  raise "INVARIANT #1 violated: engine(s) vendored a module-map xcframework #{engine_xcframeworks.inspect} — every avatar engine must be a plain static .a" unless engine_xcframeworks.empty?

  s.name             = 'bithuman'
  s.version          = '0.0.1'
  s.summary          = 'bitHuman avatar Flutter plugin (macOS)'
  s.description      = 'Real-time avatar rendering + OpenAI Realtime chat'
  s.homepage         = 'https://bithuman.ai'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'bitHuman' => 'hello@bithuman.ai' }
  s.source           = { :http => 'https://github.com/bithuman-product/bithuman-models' }
  # Swift + the BHObjCException Obj-C @try/@catch shim (.h/.m). The shim lets
  # Swift recover from AVAudioEngine's uncatchable NSException raises during
  # device hot-swaps; public_header_files + DEFINES_MODULE=>YES make CocoaPods
  # auto-generate the umbrella + module map so the pod's Swift sees bh_tryRun
  # with no bridging header / no `import`. Header is pure Obj-C (.m, never .mm).
  # Engine-agnostic glue (Classes/**) PLUS every staged engine adapter source +
  # its C ABI header (Engines/**). The headers are folded into THIS pod's own
  # umbrella module (DEFINES_MODULE + public_header_files), so the staged engine
  # Swift calls be_essence2_* with no `import` — INVARIANT #1's mechanism, now
  # generalized from one optional engine to N.
  s.source_files        = 'Classes/**/*.{swift,h,m}', 'Engines/**/Classes/**/*.swift', 'Engines/**/include/**/*.h'
  s.public_header_files = 'Classes/**/*.h', 'Engines/**/include/**/*.h'
  # Assets/embody — the per-agent embody CoreML models (the A42 demo bundle).
  # Expression2Runtime probes Bundle subdirectory "embody". Populated by
  # scripts/bootstrap.sh (not committed).
  pod_resources = ['Assets/embody']
  # PLUS, when the optional on-device Essence2 (essence2) engine is vendored,
  # libessence2's runtime resource bundles: MLX's mlx-swift_Cmlx.bundle/
  # default.metallib (MLX FAILS engine-create without it) +
  # bithuman-expression-engine_Expression.bundle (idle.wav; first idle-audio
  # access fatalErrors without it). bootstrap.sh drops these into
  # Frameworks/libessence2-resources alongside libessence2.a. The glob is itself
  # safe-empty when the dir is absent, but gate it on essence2_lib for clarity so
  # the embody-only install lists zero extra resources.
  pod_resources << 'Engines/*/Vendor/*-resources/*.bundle' if essence2_lib
  # PLUS the shared a2x wav2vec2 frontend (a2x_w2v.fp32.onnx / .int8.onnx) — a
  # LOOSE file under the engine's *-resources dir, NOT a .bundle, so the glob
  # above misses it. DirectorRuntime.resolveA2XW2VPath() locates it in
  # Bundle.main.resourcePath at runtime; CocoaPods copies these straight into the
  # app Resources/. Gated on the file actually being present.
  if essence2_lib && !Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*-resources/a2x_w2v.*.onnx')).empty?
    pod_resources << 'Engines/*/Vendor/*-resources/a2x_w2v.*.onnx'
  end
  s.resources = pod_resources
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '13.0'
  s.swift_version    = '5.9'
  s.static_framework = true

  # Vendored binaries:
  #   - libconverse.xcframework  (the on-device brain) — the ONLY module-map
  #     xcframework. Its Headers/module.modulemap declares `module CConverse`.
  #   - libessence2.a  (OPTIONAL on-device Essence2 / essence2 avatar — the
  #     be_essence2_* C ABI used by Essence2Runtime.swift) is vendored as a plain
  #     STATIC LIBRARY (s.vendored_libraries), NOT a second module-map
  #     xcframework: two vendored C-module xcframeworks break each other's
  #     module resolution. Its header is served from THIS pod's own umbrella
  #     (Engines/essence2/include/be_essence2.h). libessence2 bundles MLX + its Metal
  #     kernels statically, so it needs the MLX system frameworks added below.
  #     Vendored by bootstrap.sh ONLY when an Essence2 vendor surface is present
  #     (essence2_lib); absent it the essence2 path compiles out (ESSENCE2_AVAILABLE
  #     unset) and none of the libessence2 bits below apply.
  # embody itself is pure Swift/CoreML and links no native engine.
  #
  # INVARIANT #1 (design §0.2) — CI ASSERT: EXACTLY ONE module-map (C-module)
  # xcframework per pod, reserved for libconverse. Every avatar engine's native
  # core is a PLAIN static .a (s.vendored_libraries below), NEVER a 2nd module-map
  # xcframework (two vendored C-module xcframeworks break each other's Clang module
  # resolution — the clash 3b53fc0 fixed). Fail the pod build loudly if a future
  # change ever adds a second vendored xcframework.
  module_map_xcframeworks = ['Frameworks/libconverse.xcframework']
  raise "INVARIANT #1 violated: expected exactly 1 module-map xcframework (libconverse), got #{module_map_xcframeworks.length}: #{module_map_xcframeworks.inspect}" unless module_map_xcframeworks.length == 1
  s.vendored_frameworks = module_map_xcframeworks
  # Each staged engine's native core = a plain static lib (NEVER a 2nd module-map
  # xcframework). Auto-picked from Engines/*/Vendor/*.a (design §2.2's Dir.glob).
  s.vendored_libraries  = engine_libs.map { |p| p.sub(__dir__ + '/', '') } if essence2_lib

  # CoreAudio/AudioUnit are for libconverse: it bundles miniaudio (Supertonic
  # resampler), whose single-object impl pulls device-IO code that links these.
  # Metal/MetalKit are for libconverse's ggml-metal (llama.cpp). CoreML/
  # Accelerate are for embody's CoreML graphs + vImage frame conversion.
  # MetalPerformanceShaders + MetalPerformanceShadersGraph are for libessence2's
  # statically-linked MLX (Expression actor + director); MLX/CoreML/Accelerate/
  # Metal/MetalKit are otherwise already present for libconverse + embody. Linking
  # these system frameworks unconditionally is harmless for the embody-only build
  # (no libessence2 symbols reference them, the linker just dead-strips).
  common_frameworks =
    '-lz -liconv -lc++ ' \
    '-framework Foundation -framework CoreML -framework CoreFoundation ' \
    '-framework Accelerate -framework VideoToolbox -framework AudioToolbox ' \
    '-framework CoreMedia -framework CoreVideo -framework AppKit ' \
    '-framework CoreAudio -framework AudioUnit ' \
    '-framework Metal -framework MetalKit ' \
    '-framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph ' \
    '-framework AVFoundation -framework CoreGraphics -framework QuartzCore'

  # Homebrew dylibs libconverse needs at link + runtime via @rpath:
  #   - llama.cpp: the local LLM brain (ggml/llama).
  #   - onnxruntime: Supertonic TTS (the converse voice).
  # The example app's xcconfig also wires runtime DYLD paths so they load at
  # launch.
  brew_libs =
    '-L/opt/homebrew/lib ' \
    '-L/opt/homebrew/opt/onnxruntime/lib ' \
    '-L/opt/homebrew/opt/llama.cpp/lib ' \
    '-lonnxruntime ' \
    '-lllama'

  pod_xcconfig = {
    'DEFINES_MODULE'              => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    # embody's per-frame Swift (Expression2Runtime: fp16->u8 RGB + context-ring shifts)
    # is ~5x slower unoptimized, so a DEBUG `flutter run` can't hit real-time
    # frame production (chunks take ~3.5 s vs ~0.65 s) and playback starves/chops.
    # Force -O for THIS pod only so debug builds still run smoothly; the app's
    # Runner target stays -Onone (debuggable).
    'SWIFT_OPTIMIZATION_LEVEL'    => '-O',
  }
  # Set the ESSENCE2_AVAILABLE Swift active-compilation-condition ONLY when the
  # static libessence2.a is vendored — this is the gate Essence2Runtime.swift +
  # BithumanAvatarPlugin.swift compile against (#if ... ESSENCE2_AVAILABLE). When
  # libessence2.a is absent, the condition stays unset, the essence2 path compiles
  # out, and the pod build is byte-identical to the embody-only build.
  pod_xcconfig['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) ESSENCE2_AVAILABLE' if essence2_lib
  s.pod_target_xcconfig = pod_xcconfig

  s.user_target_xcconfig = {
    # libconverse.a comes from the vendored xcframework (CocoaPods links it
    # automatically); the Runner target needs the Homebrew C++ deps + system
    # frameworks here.
    'OTHER_LDFLAGS' => "$(inherited) #{brew_libs} #{common_frameworks}",
    # Embed @rpath entries so the Homebrew dylibs resolve at run-time.
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) /opt/homebrew/lib /opt/homebrew/opt/onnxruntime/lib /opt/homebrew/opt/llama.cpp/lib',
  }
end
