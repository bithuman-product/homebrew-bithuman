// Vendored UNCHANGED from k2-fsa/sherpa-onnx v1.13.8, sherpa-onnx/kotlin-api/FeatureConfig.kt (Apache-2.0).
// It must match the JNI in libsherpa-onnx-jni.so of the same release byte for byte: the JNI
// reads these classes' fields by name. Update both together (android/build.gradle pins the release).
package com.k2fsa.sherpa.onnx

data class FeatureConfig(
    var sampleRate: Int = 16000,
    var featureDim: Int = 80,
    var dither: Float = 0.0f
)

fun getFeatureConfig(sampleRate: Int, featureDim: Int): FeatureConfig {
    return FeatureConfig(sampleRate = sampleRate, featureDim = featureDim)
}
