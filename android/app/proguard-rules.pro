# ProGuard / R8 rules for release (minified + shrunk) builds.
#
# Only the rules required by flutter_local_notifications 17.2.4 are retained
# here. The plugin serialises its scheduled-notification metadata to disk with
# GSON via reflection; without these rules R8 renames/strips the model classes
# and their generic TypeAdapters, and scheduled notifications fail to
# (de)serialise after shrinking — breaking reboot restoration in particular.
#
# Source: flutter_local_notifications 17.2.4 documented ProGuard requirements
# (README "Release build configuration for Android" / the plugin's bundled
# example/android/app/proguard-rules.pro for that version). Each rule below is
# copied from that documented set — no unrelated example-app rules are included.

# --- GSON (used by flutter_local_notifications to persist scheduled notifications) ---
# Keep generic signatures and annotations so GSON's TypeToken reflection works.
-keepattributes Signature
-keepattributes *Annotation*

# Gson specific classes
-dontwarn sun.misc.**

# Prevent R8 from stripping the TypeAdapter / TypeAdapterFactory / generic
# machinery GSON relies on at runtime.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type

# --- flutter_local_notifications 17.2.4 ---
# Keep the plugin's classes (its serialised notification-detail models are
# accessed reflectively by GSON).
-keep class com.dexterous.** { *; }
