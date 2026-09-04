# Android — adding the bitHuman SDKs to a Gradle build

Three coordinates are published to **Maven Central**. All three ship
`arm64-v8a` only (no `armeabi-v7a`, no `x86_64`) and carry **no model
weights** — models are fetched at runtime.

| model | coordinate | latest |
|---|---|---|
| essence-1 | `ai.bithuman:sdk` | 2.3.6 |
| essence-2 | `ai.bithuman:essence2-android` | 0.2.0 |
| expression-2 | `ai.bithuman:expression2-android` | 0.3.0 |

`essence-2-max` and `expression-1` are GPU-only and have no Android
coordinate; `dream-1` is unruled. (`tools/model_scope.py` is the authority.)

## ★ expression-2 needs `google()` — Maven Central alone is NOT enough

`expression2-android` depends on `com.google.ai.edge.litert:litert:2.2.0`,
which is published on Google's Maven and **not on Maven Central**. With
`mavenCentral()` alone the build fails:

```
Could not find com.google.ai.edge.litert:litert:2.2.0.
```

essence-1 and essence-2 resolve from Central alone (kotlin-stdlib only).

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()        // ★REQUIRED for expression-2 (litert lives here)
        mavenCentral()
    }
}
```

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("ai.bithuman:sdk:2.3.6")                   // essence-1
    implementation("ai.bithuman:essence2-android:0.2.0")      // essence-2
    implementation("ai.bithuman:expression2-android:0.3.0")   // expression-2
}
```

## ★ Verify the graph, not the exit code

A resolution can return **rc=0 with `litert` absent from the graph** — that
happened here on 2026-09-04 and is the reason this page exists. Gradle
reports a missing transitive edge as an `UnresolvedDependencyResult`; code
that walks only `ResolvedDependencyResult` filters it out silently and the
build looks green.

Assert the dependency is actually there:

```bash
./gradlew app:dependencies --configuration releaseRuntimeClasspath | grep litert
```

Measured 2026-09-04 from a clean consumer (empty `GRADLE_USER_HOME`,
Gradle 8.13, JDK 17):

| coordinate | `mavenCentral()` only | `+ google()` |
|---|---|---|
| `ai.bithuman:sdk:2.3.6` | rc=0, 4 components, 0 unresolved | — |
| `ai.bithuman:essence2-android:0.2.0` | rc=0, 4 components, 0 unresolved | — |
| `ai.bithuman:expression2-android:0.3.0` | **rc=1, litert UNRESOLVED** | rc=0, 5 components |

## The essence-2 borrow is on the public API

★Teeth are BORROWED from the audio-driven teacher, never synthesized.
The Android surface exposes the borrow so you can assert it:
`attachTesseraBorrow`, `renderDriveBorrow`, `tesseraState`,
`getTesseraComposed` / `getTesseraPassthrough`.

Gate on the borrow state, not on the frame count — a render that
synthesized every mouth produces exactly as many frames as one that
borrowed them.
