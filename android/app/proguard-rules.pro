# RAVEN ProGuard/R8 rules (release builds: isMinifyEnabled = true).

# Flutter's embedding classes are kept by the Flutter Gradle plugin itself.
-dontwarn io.flutter.**

# Secure storage uses platform channels and reflection-free JNI bindings.
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# share_plus / file_picker use method channels only; nothing to keep.

# Keep the recording foreground service referenced from the manifest.
-keep class com.raven.raven.** { *; }
