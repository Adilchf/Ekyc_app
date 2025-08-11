# Conserver toutes les classes utilisées par ML Kit Text Recognition
-keep class com.google.mlkit.vision.text.** { *; }
-dontwarn com.google.mlkit.vision.text.**

# Conserver les classes Flutter
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# Garde toutes les classes de reconnaissance optique
-keep class com.google.mlkit.vision.** { *; }
-dontwarn com.google.mlkit.vision.**
