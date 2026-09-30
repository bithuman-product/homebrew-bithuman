#!/usr/bin/env bash
# Plain-JVM unit tests of the plugin's Android half (android/src/test/kotlin), e.g.
# EngineUsersTest: dispose closes an engine only after the threads that use it returned.
#
# The plugin has no Gradle wrapper of its own; Flutter includes it as the `:bithuman` project of
# any app that depends on it, so the tests run through that app's Gradle:
#
#   scripts/test_android_unit.sh <flutter app dir>      # an app whose pubspec depends on this plugin
#
# The app must have been built for Android once (android/gradlew and the plugin resolved).
set -euo pipefail
APP=${1:?usage: $0 <flutter app dir that depends on this plugin>}
cd "$APP/android"
[ -x ./gradlew ] || { echo "no $APP/android/gradlew: run 'flutter build apk' in the app once" >&2; exit 2; }
./gradlew --console=plain :bithuman:testDebugUnitTest --tests 'ai.bithuman.flutter.*'
# One line per test class from the JUnit XML (Gradle prints nothing for a pass).
find .. -path '*bithuman*' -name 'TEST-ai.bithuman.flutter.*.xml' -newer ./gradlew -print0 2>/dev/null |
  xargs -0 -I{} sh -c "grep -o '<testsuite [^>]*' '{}' | sed -E 's/.*name=\"([^\"]+)\".*tests=\"([0-9]+)\".*failures=\"([0-9]+)\".*errors=\"([0-9]+)\".*/\1: tests=\2 failures=\3 errors=\4/'"
