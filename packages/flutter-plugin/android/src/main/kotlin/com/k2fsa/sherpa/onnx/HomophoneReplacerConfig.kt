// Vendored UNCHANGED from k2-fsa/sherpa-onnx v1.13.8, sherpa-onnx/kotlin-api/HomophoneReplacerConfig.kt (Apache-2.0).
// It must match the JNI in libsherpa-onnx-jni.so of the same release byte for byte: the JNI
// reads these classes' fields by name. Update both together (android/build.gradle pins the release).
package com.k2fsa.sherpa.onnx

data class HomophoneReplacerConfig(
    var dictDir: String = "", // unused
    var lexicon: String = "",
    var ruleFsts: String = "",
)
