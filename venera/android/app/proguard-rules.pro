# Flutter engine references android.window.BackEvent on Android 13+.
# R8 reports it as missing unless suppressed (the class is loaded only on
# API 33+, the reference itself is guarded by the Flutter engine).
-dontwarn android.window.BackEvent