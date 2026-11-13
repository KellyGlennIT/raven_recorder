# RAVEN ProGuard/R8 rules (release builds: isMinifyEnabled = true).

# Flutter's embedding classes are kept by the Flutter Gradle plugin itself.
-dontwarn io.flutter.**

# Secure storage uses platform channels and reflection-free JNI bindings.
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# share_plus / file_picker use method channels only; nothing to keep.

# Keep the recording foreground service and the MainActivity method channels
# referenced from the manifest / invoked by class name from Dart.
-keep class com.raven.raven.** { *; }

# just_audio_background — AudioService and MediaButtonReceiver are referenced
# by name in AndroidManifest.xml but not imported in Kotlin source, so R8
# would strip or rename them without this rule, breaking background playback
# and lock-screen/headset media controls in release builds.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audiosession.** { *; }

# FFmpegKit rules for release builds (isMinifyEnabled = true).
# Without these, R8 obfuscates/strips JNI methods, causing native crashes on Android.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**

