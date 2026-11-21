package dev.capturekit.upload

import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.LocalDateTime
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * One zip per Scan Bundle (issue #10 stage 2, ADR 0034 / 0040). Pure JVM, no Android classes.
 *
 * Layout = tools/ckit/bundle/archive.py (the oracle, `verify_archive`): entries at the root with no folder prefix,
 * manifest.json first, then the manifest's files sorted; .jpg/.jpeg/.png/.zip STORED, everything else DEFLATED
 * (level 6); every entry dated 1980-01-01 00:00. Packing refuses an unsafe name, a listed file that is missing and a
 * file on disk the manifest does not list (`*.tmp` excepted). The archive is written as `<name>.zip.tmp`, verified
 * against the manifest, fsynced, renamed, and only then may the folder go ([packAndReplace]).
 * java.util.zip cannot set create_system / external_attr, so the bytes differ from Python's; names, order,
 * methods, timestamps and sha256/size match.
 */
object BundleArchive {
    const val MANIFEST = "manifest.json"
    private const val LEVEL = 6
    private val STORED_EXT = setOf("jpg", "jpeg", "png", "zip")
    private val EPOCH = LocalDateTime.of(1980, 1, 1, 0, 0, 0)

    /** Temp archives being written in this process: [cleanTmp] must not delete them. */
    private val inFlight: MutableSet<String> = ConcurrentHashMap.newKeySet()

    class ArchiveException(message: String) : IOException(message)

    data class Listed(val path: String, val size: Long?, val sha256: String?)

    // ---- names --------------------------------------------------------------------------------------------

    /** `<parent>/<dir name>.zip` beside the folder. */
    fun archiveFor(dir: File): File = File(dir.absoluteFile.parentFile, dir.name + ".zip")

    fun isArchive(f: File): Boolean = f.name.endsWith(".zip", ignoreCase = true) && f.isFile

    /** The folder-named key for a bundle given as folder or `<folder>.zip` (sibling files and work names use it). */
    fun dirOf(bundle: File): File =
        if (bundle.name.endsWith(".zip", ignoreCase = true)) File(bundle.absoluteFile.parentFile, bundle.name.dropLast(4)) else bundle

    /**
     * The bundles under [root] as the app lists them: every folder and every `*.zip`. A folder wins over a zip of the same
     * name, except a folder without manifest.json (a delete that was cut short after the zip verified): the zip wins then.
     */
    fun list(root: File): List<File> {
        val all = root.listFiles() ?: return emptyList()
        val zips = all.filter { isArchive(it) }
        val zipKeys = zips.map { dirOf(it).name }.toSet()
        val dirs = all.filter { it.isDirectory && (it.name !in zipKeys || File(it, MANIFEST).isFile) }
        val dirNames = dirs.map { it.name }.toSet()
        return dirs + zips.filter { dirOf(it).name !in dirNames }
    }

    /** True for a name that is not a plain relative path (same rule as archive.py `_unsafe`). */
    fun unsafe(name: String): Boolean {
        if (name.isEmpty() || name.contains('\\') || name.contains('\u0000') || name.startsWith("/")) return true
        return name.split("/").any { it.contains(':') || it == "" || it == "." || it == ".." }
    }

    // ---- manifest -----------------------------------------------------------------------------------------

    /** `manifest.files` of a manifest text (path, optional size, optional sha256), in manifest order. */
    fun listedFiles(manifestText: String): List<Listed> {
        val root = try { MiniJson(manifestText).parse() } catch (e: RuntimeException) { throw ArchiveException("manifest.json is not valid JSON: ${e.message}") }
        val files = (root as? Map<*, *>)?.get("files") as? List<*> ?: return emptyList()
        return files.mapNotNull { f ->
            val m = f as? Map<*, *> ?: return@mapNotNull null
            val path = m["path"] as? String ?: return@mapNotNull null
            Listed(path, (m["size"] as? Number)?.toLong(), m["sha256"] as? String)
        }
    }

    // ---- reading a bundle as folder or zip -----------------------------------------------------------------

    /** manifest.json text of a bundle folder or zip. */
    fun manifestText(bundle: File): String =
        if (bundle.isDirectory) File(bundle, MANIFEST).readText()
        else readEntry(bundle, MANIFEST)?.decodeToString() ?: throw ArchiveException("${bundle.name}: no $MANIFEST")

    /** One file of a bundle (folder or zip); null if it is not there. */
    fun readEntry(bundle: File, name: String): ByteArray? {
        if (unsafe(name)) return null
        if (bundle.isDirectory) return File(bundle, name).takeIf { it.isFile }?.readBytes()
        return try {
            ZipFile(bundle).use { z -> z.getEntry(name)?.let { e -> z.getInputStream(e).use { it.readBytes() } } }
        } catch (_: IOException) { null }
    }

    /** Names of the entries of a zip or the files of a folder (relative, '/'), sorted. */
    fun names(bundle: File): List<String> =
        if (bundle.isDirectory) bundle.walkTopDown().filter { it.isFile }.map { it.relativeTo(bundle).invariantSeparatorsPath }.sorted().toList()
        else try { ZipFile(bundle).use { z -> z.entries().asSequence().filter { !it.isDirectory }.map { it.name }.sorted().toList() } } catch (_: IOException) { emptyList() }

    /** Bytes the bundle takes on disk: the zip's length, or the sum of the folder's files. */
    fun sizeBytes(bundle: File): Long =
        if (bundle.isDirectory) bundle.walkTopDown().filter { it.isFile }.sumOf { it.length() } else bundle.length()

    // ---- verify -------------------------------------------------------------------------------------------

    /**
     * Problems in a zip (empty = sound). Entry names safe and unique, every file the manifest lists present with the
     * listed size and sha256, nothing else inside, CRCs good. Never throws on a damaged zip.
     */
    fun verify(zip: File): List<String> {
        val problems = mutableListOf<String>()
        val z = try { ZipFile(zip) } catch (e: IOException) { return listOf("not a readable zip: ${e.message}") }
        z.use {
            val names = z.entries().asSequence().map { it.name }.toList()
            if (names.map { it.lowercase() }.toSet().size != names.size) problems += "duplicate entry names"
            val bad = names.filter { unsafe(it) }
            if (bad.isNotEmpty()) return problems + "unsafe entry names: ${bad.take(3)}"
            val manifestEntry = z.getEntry(MANIFEST) ?: return problems + "$MANIFEST missing"
            val listed = try {
                val text = readChecked(z, manifestEntry).first.decodeToString()
                listedFiles(text)
            } catch (e: IOException) { return problems + "$MANIFEST unreadable: ${e.message}" }
            for (meta in listed) {
                val e = z.getEntry(meta.path)
                if (e == null) { problems += "listed file missing: ${meta.path}"; continue }
                try {
                    val (digest, size) = digestOf(z, e)
                    if (meta.size != null && size != meta.size) problems += "size mismatch: ${meta.path} ($size != ${meta.size})"
                    if (meta.sha256 != null && digest != meta.sha256) problems += "sha256 mismatch: ${meta.path}"
                } catch (ex: IOException) { problems += "unreadable entry ${meta.path}: ${ex.message}" }
            }
            val extra = (names.toSet() - listed.map { it.path }.toSet() - MANIFEST).sorted()
            if (extra.isNotEmpty()) problems += "entries not listed in the manifest: ${extra.take(5)}"
        }
        return problems
    }

    private fun readChecked(z: ZipFile, e: ZipEntry): Pair<ByteArray, Long> {
        val bytes = z.getInputStream(e).use { it.readBytes() }
        val crc = CRC32().apply { update(bytes) }.value
        if (e.crc >= 0 && e.crc != crc) throw IOException("CRC error in ${e.name}")
        return bytes to bytes.size.toLong()
    }

    /** (sha256 hex, size) of an entry; throws IOException on a damaged entry (bad CRC, corrupt deflate, truncation). */
    private fun digestOf(z: ZipFile, e: ZipEntry): Pair<String, Long> {
        val md = MessageDigest.getInstance("SHA-256")
        val crc = CRC32()
        var n = 0L
        z.getInputStream(e).use { s ->
            val buf = ByteArray(1 shl 16)
            while (true) { val r = s.read(buf); if (r < 0) break; md.update(buf, 0, r); crc.update(buf, 0, r); n += r }
        }
        if (e.crc >= 0 && e.crc != crc.value) throw IOException("CRC error in ${e.name}")
        return md.digest().joinToString("") { "%02x".format(it) } to n
    }

    // ---- pack ---------------------------------------------------------------------------------------------

    /** manifest.json first, then the files it lists, sorted. Throws if the folder disagrees with the manifest. */
    private fun entryNames(dir: File): List<String> {
        val text = try { File(dir, MANIFEST).readText() } catch (e: IOException) { throw ArchiveException("${dir.name}: cannot read $MANIFEST: ${e.message}") }
        val listed = listedFiles(text).map { it.path }.sorted()
        if (listed.map { it.lowercase() }.toSet().size != listed.size) throw ArchiveException("${dir.name}: manifest lists a path twice")
        for (n in listed) {
            if (unsafe(n)) throw ArchiveException("${dir.name}: manifest lists an unsafe path '$n'")
            if (!File(dir, n).isFile) throw ArchiveException("${dir.name}: listed file missing: $n")
        }
        val onDisk = dir.walkTopDown().filter { it.isFile && !it.name.endsWith(".tmp") }.map { it.relativeTo(dir).invariantSeparatorsPath }.toSet()
        val extra = (onDisk - listed.toSet() - MANIFEST).sorted()
        if (extra.isNotEmpty()) throw ArchiveException("${dir.name}: files not listed in the manifest: ${extra.take(5).joinToString(", ")}")
        return listOf(MANIFEST) + listed
    }

    private fun crcOf(f: File): Long {
        val crc = CRC32()
        f.inputStream().use { s -> val b = ByteArray(1 shl 16); while (true) { val r = s.read(b); if (r < 0) break; crc.update(b, 0, r) } }
        return crc.value
    }

    private fun stored(name: String) = name.substringAfterLast('/').substringAfterLast('.', "").lowercase() in STORED_EXT

    /**
     * Packs the bundle folder into `<name>.zip` beside it and returns it. Written to `<name>.zip.tmp`, verified against
     * the manifest, fsynced, then renamed: a failure never leaves a bad archive, and never touches the folder.
     * @throws ArchiveException (or IOException) when the folder is unsafe, incomplete, inconsistent or unwritable.
     */
    fun pack(dir: File): File {
        if (!dir.isDirectory) throw ArchiveException("${dir.name}: not a bundle folder")
        val out = archiveFor(dir)
        val tmp = File(out.parentFile, out.name + ".tmp")
        val names = entryNames(dir)
        inFlight += tmp.absolutePath
        try {
            tmp.delete()   // a stale temp from a crashed pack: start over
            ZipOutputStream(tmp.outputStream().buffered()).use { zos ->
                zos.setLevel(LEVEL)
                for (name in names) {
                    val f = File(dir, name)
                    val e = ZipEntry(name)
                    e.setTimeLocal(EPOCH)
                    if (stored(name)) {
                        e.method = ZipEntry.STORED; e.size = f.length(); e.compressedSize = f.length(); e.crc = crcOf(f)
                    } else e.method = ZipEntry.DEFLATED
                    zos.putNextEntry(e)
                    f.inputStream().use { it.copyTo(zos, 1 shl 16) }
                    zos.closeEntry()
                }
            }
            val problems = verify(tmp)
            if (problems.isNotEmpty()) throw ArchiveException("${out.name}: verification failed: ${problems.take(5).joinToString("; ")}")
            java.io.FileOutputStream(tmp, true).use { it.fd.sync() }   // on disk before the caller may delete the folder
            try {
                Files.move(tmp.toPath(), out.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(tmp.toPath(), out.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            tmp.delete()
            inFlight -= tmp.absolutePath
        }
        return out
    }

    /**
     * Packs, verifies the archive on disk, and only then deletes the folder (manifest.json first, so a crash in the
     * middle leaves a folder without a manifest next to a good zip). Returns the zip, or null with the folder untouched
     * on any failure ([onError] gets the reason).
     */
    fun packAndReplace(dir: File, onError: (Throwable) -> Unit = {}): File? {
        val zip = try { pack(dir) } catch (t: Exception) { onError(t); return null }
        val problems = verify(zip)   // pack verified the temp file; check what is actually on disk now
        if (problems.isNotEmpty()) { onError(ArchiveException("${zip.name}: ${problems.take(3).joinToString("; ")}")); return null }
        File(dir, MANIFEST).delete()
        dir.deleteRecursively()
        return zip
    }

    /** Deletes leftover `<name>.zip.tmp` files directly under [root] (a pack the process was killed in); skips ones being written now. */
    fun cleanTmp(root: File) {
        root.listFiles { f -> f.isFile && f.name.endsWith(".zip.tmp") }?.forEach { if (it.absolutePath !in inFlight) it.delete() }
    }

    // ---- tiny JSON reader (manifest only; no org.json so the module stays pure JVM) ---------------------------

    private class MiniJson(private val s: String) {
        private var i = 0

        fun parse(): Any? { val v = value(); ws(); if (i != s.length) fail("trailing data"); return v }

        private fun fail(m: String): Nothing = throw IllegalArgumentException("$m at $i")
        private fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
        private fun expect(c: Char) { ws(); if (i >= s.length || s[i] != c) fail("expected '$c'"); i++ }

        private fun value(): Any? {
            ws()
            if (i >= s.length) fail("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> if (c == '-' || c.isDigit()) num() else fail("unexpected '$c'")
            }
        }

        private fun lit(w: String, v: Any?): Any? { if (!s.startsWith(w, i)) fail("bad literal"); i += w.length; return v }

        private fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            expect('{'); ws()
            if (s[i] == '}') { i++; return m }
            while (true) {
                ws(); val k = str(); expect(':'); m[k] = value(); ws()
                if (i < s.length && s[i] == ',') { i++; continue }
                expect('}'); return m
            }
        }

        private fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            expect('['); ws()
            if (s[i] == ']') { i++; return l }
            while (true) {
                l += value(); ws()
                if (i < s.length && s[i] == ',') { i++; continue }
                expect(']'); return l
            }
        }

        private fun str(): String {
            if (i >= s.length || s[i] != '"') fail("expected string")
            i++
            val b = StringBuilder()
            while (true) {
                if (i >= s.length) fail("unterminated string")
                val c = s[i++]
                when (c) {
                    '"' -> return b.toString()
                    '\\' -> {
                        if (i >= s.length) fail("bad escape")
                        when (val e = s[i++]) {
                            '"', '\\', '/' -> b.append(e)
                            'b' -> b.append('\b')
                            'f' -> b.append('\u000c')
                            'n' -> b.append('\n')
                            'r' -> b.append('\r')
                            't' -> b.append('\t')
                            'u' -> { if (i + 4 > s.length) fail("bad \\u escape"); b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                            else -> fail("bad escape")
                        }
                    }
                    else -> b.append(c)
                }
            }
        }

        private fun num(): Number {
            val st = i
            while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
            val t = s.substring(st, i)
            return t.toLongOrNull() ?: t.toDoubleOrNull() ?: fail("bad number")
        }
    }
}
