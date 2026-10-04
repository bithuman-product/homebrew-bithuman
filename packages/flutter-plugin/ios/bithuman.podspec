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
# compilation condition only when `Frameworks/libessence2.a` is present.
#
# ★2026-08-28 THIS PARAGRAPH USED TO END "the essence2 runtime adapter is
# `#if os(macOS)`-gated, so on iOS its be_essence2 symbols dead-strip — the
# vendored lib just keeps the pod consistent across both slices." That was FALSE,
# and the SAME FILE contradicted it 20 lines down (and again at
# s.vendored_libraries). Ground truth, verified on bithuman-models main:
# essence-2/sdk/Classes/Essence2Engine.swift:26 gates on
# `#if (os(macOS) || os(iOS)) && ESSENCE2_AVAILABLE`; sdk/scripts/bootstrap.sh
# extracts the ios-arm64 slice to Vendor/libessence2-ios.a; this plugin's
# scripts/bootstrap.sh calls `stage_essence2_plat ios`; and the pinned release
# essence2-libessence2-v1.0-a2x really does carry ios-arm64 (232 MB) and
# ios-arm64-simulator slices. So on iOS the adapter COMPILES and the symbols are
# LINKED, not dead-stripped. Keep this sentence and Essence2Engine.swift's #if in
# the same commit — a reader acting on the stale half concludes essence-2 has no
# iOS leg at all. (What is genuinely unproven is a full-pipeline on-device iOS
# RENDER: no target in essence-2/engine/light/ane/Package.swift drives the C ABI
# on a device slice — only the Essence2 library enters the iOS xcframework.)
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
  # sherpa-onnx (OPTIONAL): the hybrid brain's own speech-to-text on iOS — a Silero VAD + an offline
  # recognizer (NeMo Parakeet TDT / Moonshine), SherpaAsr.swift. A PLAIN static .a built against THIS
  # pod's onnxruntime.xcframework by scripts/build-sherpa-ios.sh, its C API header served from this
  # pod's own umbrella (never a second module-map xcframework: INVARIANT #1). Decided by the staged
  # bytes, like every optional part: without it the app runs Apple's SpeechAnalyzer.
  sherpa_dir = File.join(__dir__, 'Vendor/sherpa-onnx')
  sherpa_lib = File.file?(File.join(sherpa_dir, 'libsherpa-onnx.a')) &&
               File.file?(File.join(sherpa_dir, 'include/sherpa_onnx_c_api.h'))
  essence2_lib = !engine_libs.empty?

  # DARK Component-4 auth hooks (shared/Classes/DeviceAuthShim.m) name two
  # ADDITIVE C symbols no vendored engine exports yet. A `weak_import` does NOT
  # let a STATIC link tolerate their absence — measured 2026-09-15: the product
  # app failed to link this pod against essence2-v1.2.0 on Xcode 26.3
  # ("Undefined symbols: _be_auth_set_request_signer,
  # _be_internal_sealed_store_register"). So the calls compile in ONLY when a
  # staged engine .a exports BOTH hooks; otherwise the shim's bh_try_* are -1
  # no-ops and nothing references the symbols. Decided by the staged bytes.
  auth_hook_syms = %w[_be_auth_set_request_signer _be_internal_sealed_store_register]
  auth_hooks = engine_libs.any? do |lib|
    auth_hook_syms.all? { |sym| system("nm -gU '#{lib}' 2>/dev/null | grep -q ' #{sym}$'") }
  end

  # Essence 2 SKIP-AHEAD (2.6.30): the presenter tells the engine where the voice is and stamps each
  # frame with the engine's own ordinal. essence2-apple v1.15.3 adds the three calls; an earlier staged
  # engine has none of them, and the adapter must still build against it — so, as with the auth hooks,
  # the staged BYTES decide: ESSENCE2_SKIP_AHEAD only when a staged engine lib exports all three.
  skip_ahead_syms = %w[_be_essence2_set_playout_position _be_essence2_last_frame_index _be_essence2_skipped_frames]
  skip_ahead = engine_libs.any? do |lib|
    skip_ahead_syms.all? { |sym| system("nm -gU '#{lib}' 2>/dev/null | grep -q ' #{sym}$'") }
  end

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
  s.source           = { :http => 'https://github.com/bithuman-product/bithuman-models' }
  # Swift + the BHObjCException Obj-C @try/@catch shim (.h/.m). The shim lets
  # Swift recover from AVAudioEngine's uncatchable NSException raises during
  # device hot-swaps; public_header_files + DEFINES_MODULE=>YES make CocoaPods
  # auto-generate the umbrella + module map so the pod's Swift sees bh_tryRun
  # with no bridging header / no `import`. Header is pure Obj-C (.m, never .mm).
  # Engine-agnostic glue (Classes/**) PLUS every staged engine adapter source +
  # its C ABI header (Engines/**), folded into THIS pod's own umbrella module so
  # the staged engine Swift calls be_essence2_* with no `import` (INVARIANT #1's
  # mechanism, generalized to N engines).
  sherpa_headers = sherpa_lib ? ['Vendor/sherpa-onnx/include/*.h'] : []
  s.source_files        = ['Classes/**/*.{swift,h,m}', 'Engines/**/include/**/*.h'] + sherpa_headers
  s.public_header_files = ['Classes/**/*.h', 'Engines/**/include/**/*.h'] + sherpa_headers
  # Assets/embody — the per-agent embody CoreML models (the A42 demo bundle).
  # Expression2Runtime probes Bundle subdirectory "embody". Populated by
  # scripts/bootstrap.sh (not committed) at <plugin>/ios/Assets/embody — this
  # pattern is resolved RELATIVE TO THIS PODSPEC, and bootstrap used to land the
  # members one level up at <plugin>/Assets/embody, where this glob could never see
  # them. An empty CocoaPods file pattern is not an error, so the app built green
  # and shipped no expression-2 graphs at all.
  pod_resources = ['Assets/embody']
  # PLUS libessence2's iOS-DEVICE runtime resource bundles when essence2 is
  # vendored (the iOS metallib is per-platform — NOT the macOS one):
  # mlx-swift_Cmlx.bundle/default.metallib + the iOS Expression bundle. Gated on
  # essence2_lib so the embody-only install lists zero extra resources.
  pod_resources << 'Engines/*/Vendor/*-resources/*.bundle' if essence2_lib
  # PLUS the shared audio frontend — LOOSE .onnx files under the engine's
  # *-resources dir, NOT a .bundle, so the glob above misses them. The engine
  # (Essence2Session.resolveA2XW2VPath) looks for the encoder by NAME in
  # Bundle.main.resourcePath — `w2v_ess_fp16_v1.onnx` since essence2-v1.5.x, the
  # `a2x_w2v.*.onnx` names before it — and le_a2x then wants the short-window pair
  # `audio_encoder_fp16_window_{trunk,head}.onnx` BESIDE it (legacy 8 s hop without
  # them). CocoaPods copies these straight into the app Resources/, flat, so the
  # three are siblings there. Every loose .onnx the release ships is taken: the
  # old `a2x_w2v.*.onnx` glob matched none of the current names, so the app
  # carried the .bundles and no encoder, and be_essence2_create returned -2
  # ("no shared audio frontend") on the first macOS run (2026-09-16). Gated on a
  # file actually being present.
  # (essence2 now runs on iOS too, so the a2x w2v frontend is live there.)
  if essence2_lib && !Dir.glob(File.join(__dir__, 'Engines/*/Vendor/*-resources/*.onnx')).empty?
    pod_resources << 'Engines/*/Vendor/*-resources/*.onnx'
  end
  s.resources = pod_resources
  # The plugin's privacy manifest (required-reason APIs: file timestamp C617.1, system boot
  # time 35F9.1), as its own bundle so the app's archive carries it under the plugin's name
  # (bithuman_privacy.bundle/PrivacyInfo.xcprivacy). Until 2.6.27 the file was in the repo
  # but in no file pattern, so no app ever shipped it.
  s.resource_bundles = {'bithuman_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
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
  # libconverse (the on-device conversation brain) is OPTIONAL, decided by the
  # STAGED BYTES exactly as essence2 is (essence2_lib → ESSENCE2_AVAILABLE). It is
  # SDK, not an avatar engine, and a clone that cannot reach it must still build a
  # working plugin: every CLOUD path, the avatar, the texture and both engines are
  # independent of it. Only localAudioStart/Stop/PushText need it, and they refuse
  # by name when it is absent (see CONVERSE_AVAILABLE below).
  converse_fw = File.directory?(File.join(__dir__, 'Frameworks/libconverse.xcframework'))
  module_map_xcframeworks = converse_fw ? ['Frameworks/libconverse.xcframework'] : []
  raise "INVARIANT #1 violated: at most 1 module-map xcframework (libconverse), got #{module_map_xcframeworks.length}: #{module_map_xcframeworks.inspect}" unless module_map_xcframeworks.length <= 1
  # ★THE EXPRESSION 2 ENGINE IS THE PUBLISHED BINARY (2.6.20). Three Swift binary frameworks — not
  # Clang module-map xcframeworks, so INVARIANT #1 (at most one of those: libconverse) is untouched:
  # Expression2, BithumanEngineProtocol and UnifiedModelHeader, exactly the Swift package's
  # `Expression2` product, staged by scripts/bootstrap.sh. UnifiedModelHeader also satisfies the
  # symbols libessence2.a references.
  x2_frameworks = %w[Expression2 BithumanEngineProtocol UnifiedModelHeader].map { |m| "Frameworks/#{m}.xcframework" }
  missing_x2 = x2_frameworks.reject { |f| File.directory?(File.join(__dir__, f)) }
  raise "run scripts/bootstrap.sh first: #{missing_x2.inspect} not staged" unless missing_x2.empty?
  s.vendored_frameworks = ['Frameworks/onnxruntime.xcframework'] + module_map_xcframeworks + x2_frameworks
  # Each staged engine's native core = a plain static lib (NEVER a 2nd module-map
  # xcframework). Auto-picked from Engines/*/Vendor/*.a (design §2.2's Dir.glob).
  # libessence2 (OPTIONAL on-device Essence2 / essence2 — the be_essence2_* C ABI
  # used by Essence2Runtime.swift) is vendored as a plain STATIC LIBRARY, NOT a
  # second module-map xcframework: two vendored C-module xcframeworks break each
  # other's module resolution. Its header is served from this pod's own umbrella
  # (Engines/essence2/include/be_essence2.h). Vendored by scripts/bootstrap.sh only when
  # an Essence2 vendor surface is present (essence2_lib). NOTE (corrected
  # 2026-08-28; this said the adapter is `#if os(macOS)`-gated and dead-strips on
  # iOS): the adapter is `#if (os(macOS) || os(iOS)) && ESSENCE2_AVAILABLE`, so on
  # iOS these symbols are LINKED, not dead-stripped — see the header block.
  vendored_libs = essence2_lib ? engine_libs.map { |p| p.sub(__dir__ + '/', '') } : []
  vendored_libs << 'Vendor/sherpa-onnx/libsherpa-onnx.a' if sherpa_lib
  s.vendored_libraries  = vendored_libs unless vendored_libs.empty?

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
  conds = ['$(inherited)']
  conds << 'ESSENCE2_AVAILABLE' if essence2_lib
  conds << 'ESSENCE2_SKIP_AHEAD' if essence2_lib && skip_ahead
  # Set from the staged bytes, never from intent: the local-brain code compiles
  # in ONLY when the framework it calls is actually present.
  conds << 'CONVERSE_AVAILABLE'  if converse_fw
  # libconverse >= 2.4.0 adds bc_session_push_text_ex (continuation merge of a
  # split utterance). Detected from the staged header so this pod still builds
  # against an older vendored brain (the split part is then its own turn).
  if converse_fw
    hdr = Dir.glob(File.join(__dir__, 'Frameworks/libconverse.xcframework/*/Headers/bithuman/libconverse.h')).first
    conds << 'CONVERSE_PUSH_EX' if hdr && File.read(hdr).include?('bc_session_push_text_ex')
    # libconverse >= 2.5.0 adds bc_session_create_with_llm: the brain can run
    # Apple's on-device model (Foundation Models) instead of llama.cpp.
    conds << 'CONVERSE_HOST_LLM' if hdr && File.read(hdr).include?('bc_session_create_with_llm')
  end
  conds << 'SHERPA_ASR_AVAILABLE' if sherpa_lib
  pod_xcconfig['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conds.join(' ')
  # Apple's on-device model (AppleFoundationLlm.swift) is iOS / macOS 26+: weak so
  # the plugin still loads on the older systems this pod supports.
  s.weak_frameworks = ['FoundationModels']
  pod_xcconfig['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) BH_ENGINE_AUTH_HOOKS=1' if auth_hooks
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
