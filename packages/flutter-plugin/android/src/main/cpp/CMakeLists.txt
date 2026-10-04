# The Android on-device brain's native half, all built FROM SOURCE at pinned revisions —
# nothing prebuilt is vendored:
#
#   libbhbrain.so          llama.cpp (the reply) behind a small JNI (bh_llm_jni.cpp)
#   libsherpa-onnx-jni.so  sherpa-onnx v1.13.8 (speech in: silero VAD + Moonshine; speech out:
#                          Supertonic) with ONNX Runtime linked in statically, and WITHOUT
#                          espeak-ng: sherpa-onnx's TTS switch drags in espeak-ng (GPL-3.0) for
#                          voices this brain never uses, so its two CMake modules are replaced by
#                          the no-op stand-ins in no-espeak/ (see its README). Static ONNX Runtime
#                          because essence2-android already ships a libonnxruntime.so of another
#                          version under the same name.
#
# Offline builds / bisects: BH_LLAMA_CPP_DIR, BH_SHERPA_ONNX_DIR (a v1.13.8 checkout) and
# BH_ORT_STATIC_DIR (an unpacked onnxruntime-android-arm64-v8a-static_lib-1.28.2) stand in for
# the downloads (android/build.gradle forwards them).
#
# ISA: the llama.cpp baseline is armv8.2-a + dotprod + fp16 — every arm64 phone core since
# Cortex-A55/A75. i8mm is NOT assumed (a device without it would SIGILL); on a Galaxy S25+ an
# armv8.7-a build is no faster (prefill 251 vs 237 tok/s, generation 66 vs 69).
cmake_minimum_required(VERSION 3.22.1)
project(bhbrain CXX C)

include(FetchContent)
include(ExternalProject)

# ------------------------------------------------------------------ llama.cpp -> libbhbrain.so
set(BH_LLAMA_CPP_COMMIT "237958db339300bdd8028608cc08b2ba2685ec33")   # b8110
if(BH_LLAMA_CPP_DIR)
  set(FETCHCONTENT_SOURCE_DIR_LLAMA_CPP ${BH_LLAMA_CPP_DIR})
endif()
FetchContent_Declare(llama_cpp
    URL https://github.com/ggml-org/llama.cpp/archive/${BH_LLAMA_CPP_COMMIT}.tar.gz
    URL_HASH SHA256=38b215a5ef82cd46756787ad724de328761d2ffc333763d80ae5d904ad8da0f3)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
FetchContent_MakeAvailable(llama_cpp)

add_library(bhbrain SHARED bh_llm_jni.cpp)
target_compile_features(bhbrain PRIVATE cxx_std_17)
target_link_libraries(bhbrain PRIVATE llama ggml android log)
# Keep only the JNI entry points exported; llama/ggml stay internal to this .so.
target_link_options(bhbrain PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,--gc-sections")

# ------------------------------------------------------------------ sherpa-onnx -> libsherpa-onnx-jni.so
set(BH_SHERPA_ONNX_VERSION "1.13.8")   # android/src/main/kotlin/com/k2fsa/... is this release's Kotlin API
set(BH_ORT_VERSION "1.28.2")
if(BH_ORT_STATIC_DIR)
  set(ORT_DIR ${BH_ORT_STATIC_DIR})
else()
  set(ORT_NAME onnxruntime-android-arm64-v8a-static_lib-${BH_ORT_VERSION})
  set(ORT_DIR ${CMAKE_BINARY_DIR}/${ORT_NAME})
  if(NOT EXISTS ${ORT_DIR}/lib/libonnxruntime.a)
    file(DOWNLOAD https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${BH_ORT_VERSION}/${ORT_NAME}.zip
         ${CMAKE_BINARY_DIR}/${ORT_NAME}.zip
         EXPECTED_HASH SHA256=bc68410f35f13df82c260830bf476ee5565f5efd0ec7622297829a929613c6c0 SHOW_PROGRESS)
    file(ARCHIVE_EXTRACT INPUT ${CMAKE_BINARY_DIR}/${ORT_NAME}.zip DESTINATION ${CMAKE_BINARY_DIR})
  endif()
endif()

if(BH_SHERPA_ONNX_DIR)
  set(SHERPA_SRC SOURCE_DIR ${BH_SHERPA_ONNX_DIR})
else()
  set(SHERPA_SRC
      URL https://github.com/k2-fsa/sherpa-onnx/archive/refs/tags/v${BH_SHERPA_ONNX_VERSION}.tar.gz
      URL_HASH SHA256=b0374cc56dbc186d442ae73d5de743bb092470b640c4c50ce7b029044c0c4fa8)
endif()
set(SHERPA_BIN ${CMAKE_BINARY_DIR}/sherpa-onnx-build)
set(SHERPA_SO ${SHERPA_BIN}/lib/libsherpa-onnx-jni.so)
ExternalProject_Add(sherpa_onnx_ep
    ${SHERPA_SRC}
    BINARY_DIR ${SHERPA_BIN}
    # sherpa-onnx finds ONNX Runtime through these two environment variables.
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env
        SHERPA_ONNXRUNTIME_LIB_DIR=${ORT_DIR}/lib/ SHERPA_ONNXRUNTIME_INCLUDE_DIR=${ORT_DIR}/include/
        ${CMAKE_COMMAND} -G ${CMAKE_GENERATOR} -S <SOURCE_DIR> -B <BINARY_DIR>
        -DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_NDK=${ANDROID_NDK}
        # android-21 like sherpa-onnx's own release: it keeps the NNAPI provider (absent from
        # the static ONNX Runtime) compiled out. The app's minSdk (29) is what devices see.
        -DANDROID_PLATFORM=android-21
        -DANDROID_STL=c++_static
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_MODULE_PATH=${CMAKE_CURRENT_SOURCE_DIR}/no-espeak
        -DBUILD_SHARED_LIBS=OFF
        -DSHERPA_ONNX_ENABLE_TTS=ON
        -DSHERPA_ONNX_ENABLE_JNI=ON
        -DSHERPA_ONNX_ENABLE_C_API=OFF
        -DSHERPA_ONNX_ENABLE_BINARY=OFF
        -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF
        -DSHERPA_ONNX_ENABLE_PYTHON=OFF
        -DSHERPA_ONNX_ENABLE_TESTS=OFF
        -DSHERPA_ONNX_ENABLE_CHECK=OFF
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
        -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
        -DSHERPA_ONNX_ENABLE_RKNN=OFF
        -DSHERPA_ONNX_ENABLE_QNN=OFF
        -DSHERPA_ONNX_LINK_LIBSTDCPP_STATICALLY=OFF
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target sherpa-onnx-jni
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${SHERPA_SO})

# An IMPORTED shared library that a built target links is packaged into the AAR by AGP.
add_library(sherpa_onnx_jni SHARED IMPORTED GLOBAL)
set_target_properties(sherpa_onnx_jni PROPERTIES IMPORTED_LOCATION ${SHERPA_SO})
add_dependencies(sherpa_onnx_jni sherpa_onnx_ep)
target_link_libraries(bhbrain PRIVATE sherpa_onnx_jni)
