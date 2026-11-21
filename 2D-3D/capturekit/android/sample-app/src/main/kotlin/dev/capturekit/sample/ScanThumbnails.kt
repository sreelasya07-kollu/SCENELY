package dev.capturekit.sample

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import dev.capturekit.upload.BundleArchive
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Scan thumbnails shared by "My scans" and the Home "Recent scans" strip: the middle keyframe of a bundle, decoded
 * small once and cached for the process. [load] reads disk, so call it from a worker thread; [cached] is safe anywhere.
 */
object ScanThumbnails {
    private const val TARGET_PX = 240
    private val cache = ConcurrentHashMap<String, Bitmap>()

    fun cached(dir: File): Bitmap? = cache[BundleArchive.dirOf(dir).absolutePath]

    fun load(dir: File): Bitmap? {
        val key = BundleArchive.dirOf(dir).absolutePath
        cache[key]?.let { return it }
        return try {
            // dir is a bundle folder or its zip; the keyframe bytes come from either (file or zip entry)
            val jpgs = BundleArchive.names(dir).filter { it.startsWith("keyframes/") && (it.endsWith(".jpg", true) || it.endsWith(".jpeg", true)) }
            val name = jpgs.getOrNull(jpgs.size / 2) ?: return null
            val bytes = BundleArchive.readEntry(dir, name) ?: return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= TARGET_PX && bounds.outHeight / (sample * 2) >= TARGET_PX) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.also { cache[key] = it }
        } catch (t: Throwable) { null }
    }
}
