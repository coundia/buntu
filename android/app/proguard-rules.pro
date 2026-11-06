# Keep JNA & UniFFI generated bindings for Rust cnd-core FFI
-keep class com.sun.jna.** { *; }
-keep class * extends com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

-keep class com.pcoundia.buntu.core.engine.ffi.** { *; }
-keep interface com.pcoundia.buntu.core.engine.ffi.** { *; }

# Keep Kotlin Serialization generated serializers
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.pcoundia.buntu.**$$serializer { *; }

