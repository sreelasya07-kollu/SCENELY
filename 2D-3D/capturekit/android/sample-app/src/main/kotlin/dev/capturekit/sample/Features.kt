package dev.capturekit.sample

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.util.Log
import dev.capturekit.capture.FeatureFlags

/**
 * The app's feature switches (ADR 0032), shared by every screen. Precedence (FeatureFlags.resolve): debug property >
 * user setting (SharedPreferences "capturekit", keys `ck.*`, written by [SettingsActivity]) > [FeatureFlags.Flags.DEFAULTS].
 * Release builds read no property. Debuggable builds: all `debug.capturekit.*` properties from ONE argument-less `getprop`
 * call, parsed by [FeatureFlags.parseGetprop], lazily on first use (force-stop the app after `adb shell setprop`).
 * The result is cached for the process; [invalidate] drops it after a setting changed.
 */
object Features {
    private const val TAG = "CKFeatures"
    const val PREFS = "capturekit"
    @Volatile private var cached: FeatureFlags.Flags? = null
    @Volatile private var props: Map<String, String>? = null

    fun get(ctx: Context): FeatureFlags.Flags = cached ?: synchronized(this) {
        cached ?: run {
            val debuggable = ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            val p = props ?: (if (debuggable) FeatureFlags.parseGetprop(getpropAll()) else emptyMap<String, String>()).also { props = it }
            val prefs = prefs(ctx)
            FeatureFlags.resolve({ p[it] }, { k -> if (prefs.contains(k)) prefs.getBoolean(k, false) else null }).also {
                cached = it
                Log.i(TAG, "features $it")
            }
        }
    }

    fun prefs(ctx: Context): SharedPreferences = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Forget the resolved flags (properties stay cached): the next [get] re-reads the user settings. */
    fun invalidate() { cached = null }

    /** Warm the cache on a background thread (called from the launcher) so the capture screen's onCreate rarely waits on getprop. */
    fun prefetch(ctx: Context) {
        if (cached != null) return
        val app = ctx.applicationContext
        Thread({ get(app) }, "ck-features").start()
    }

    /** One `getprop` child process listing every property; streams closed, process destroyed; "" on any failure. */
    private fun getpropAll(): String {
        var p: Process? = null
        return try {
            p = Runtime.getRuntime().exec(arrayOf("getprop"))
            p.inputStream.bufferedReader().use { it.readText() }
        } catch (t: Throwable) { "" } finally { p?.destroy() }
    }
}
