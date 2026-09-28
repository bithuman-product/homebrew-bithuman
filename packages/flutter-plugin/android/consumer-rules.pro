# LOCAL mode (the on-device brain). Both native libraries find Kotlin members BY NAME:
# sherpa-onnx's JNI reads its config data classes field by field, and libbhbrain.so calls
# PieceSink.onPiece. An app whose R8 renamed them would crash at the first model load.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class ai.bithuman.flutter.brain.LlamaBrain { *; }
-keep interface ai.bithuman.flutter.brain.LlamaBrain$PieceSink { *; }
-keep class * implements ai.bithuman.flutter.brain.LlamaBrain$PieceSink { *; }
