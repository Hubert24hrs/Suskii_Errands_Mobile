# R8 rules for the release build. Flutter and every plugin ship their own consumer rules; these
# cover only what R8 reports as missing when it shrinks this app.

# Flutter's deferred-components support references Play Core, which this app does not ship.
-dontwarn com.google.android.play.core.**

# Tink (behind flutter_secure_storage) references annotations that exist only at compile time.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# Keep line numbers so Sentry can symbolicate Java/Kotlin frames; the mapping file is uploaded
# by the release workflow, the source file names are not shipped.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
