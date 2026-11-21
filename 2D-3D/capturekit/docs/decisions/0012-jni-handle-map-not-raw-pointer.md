# 0012 — JNI Handle Map Instead of Raw Pointer Cast

ARM64 MTE/TBI (Top-Byte Ignore) tags the upper byte of heap pointers on devices like
OnePlus (Android 14+). `reinterpret_cast<jlong>(ptr)` can produce a negative value,
defeating the Kotlin `handle <= 0 → error` check. Replaced with a `std::unordered_map`
assigning small positive integer handles; the map also guards against use-after-free.
Mutex-protected; contention is negligible (one create/destroy per session).
