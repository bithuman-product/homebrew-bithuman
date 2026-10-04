/* Empty on purpose: libbhhybrid.so is the hybrid brain's one built native target. AGP packages an
 * IMPORTED shared library (libsherpa-onnx-jni.so, built by CMakeLists.txt's ExternalProject) only
 * through a built target that links it — this one. Nothing loads it. */
int bh_hybrid_build_marker(void) { return 1; }
