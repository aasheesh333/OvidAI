# Flutter / Firebase keep rules (R8 full mode).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.google.firebase.**
# Keep generated plugin registrant
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Security Hardening & Anti-Reverse Engineering
# Strip debugging information and line numbers
-renamesourcefileattribute SourceFile
-keepattributes SourceFile,LineNumberTable
-repackageclasses ''
-allowaccessmodification

# Obfuscate dictionary and aggressive class renaming
-dontusemixedcaseclassnames

# Strip logging and debugging calls in release builds
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}

# Protect sensitive security check classes
-keep class com.dhanuk.ovidai.SecurityCheck { *; }
-keep class com.dhanuk.ovidai.MainActivity { *; }
-keep class com.dhanuk.ovidai.OvidAccessibilityService { *; }
