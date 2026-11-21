package dev.capturekit.upload

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.time.LocalDateTime
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

class BundleArchiveTest {
    private val root: File = Files.createTempDirectory("bundlearchive").toFile()

    @After fun cleanup() { root.deleteRecursively() }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** A bundle folder `<root>/<name>` whose manifest lists [files] with their real size and sha256 (a [wrongSha] path gets a bad one). */
    private fun bundle(name: String = "scan_test", files: Map<String, ByteArray>, wrongSha: String? = null, listed: Collection<String> = files.keys): File {
        val dir = File(root, name).apply { mkdirs() }
        for ((p, d) in files) File(dir, p).apply { parentFile!!.mkdirs() }.writeBytes(d)
        val entries = listed.joinToString(",") { p ->
            val d = files[p] ?: ByteArray(1)
            """{"path":"$p","size":${d.size},"sha256":"${if (p == wrongSha) "0".repeat(64) else sha(d)}","role":"x"}"""
        }
        File(dir, "manifest.json").writeText("""{"schema_version":"1.4.0","bundle_id":"bid-1","files":[$entries]}""")
        return dir
    }

    private val sample = mapOf(
        "streams.mcap" to ByteArray(4000) { (it % 7).toByte() },
        "camera.json" to "{\"w\":1}".toByteArray(),
        "keyframes/000001.jpg" to ByteArray(300) { it.toByte() },
        "keyframes/000000.jpg" to ByteArray(200) { (it * 3).toByte() },
        "guidance_log.json" to "[]".toByteArray(),
    )

    private fun assertLayout(zip: File, manifestPaths: Collection<String>) {
        ZipFile(zip).use { z ->
            val entries = z.entries().toList()
            assertEquals(listOf("manifest.json") + manifestPaths.sorted(), entries.map { it.name })
            for (e in entries) {
                val stored = e.name.substringAfterLast('.') in setOf("jpg", "jpeg", "png", "zip")
                assertEquals(e.name, if (stored) ZipEntry.STORED else ZipEntry.DEFLATED, e.method)
                assertEquals(e.name, LocalDateTime.of(1980, 1, 1, 0, 0, 0), e.timeLocal)
            }
        }
    }

    @Test fun packsATempBundleInTheDocumentedLayout() {
        val dir = bundle(files = sample)
        val zip = BundleArchive.pack(dir)
        assertEquals(File(root, "scan_test.zip"), zip)
        assertLayout(zip, sample.keys)
        assertEquals(emptyList<String>(), BundleArchive.verify(zip))
        assertTrue("folder is untouched by pack", dir.isDirectory)
        assertFalse(File(root, "scan_test.zip.tmp").exists())
        // sha256 and size of every entry against the manifest
        val listed = BundleArchive.listedFiles(BundleArchive.manifestText(zip))
        assertEquals(sample.size, listed.size)
        for (l in listed) {
            val bytes = BundleArchive.readEntry(zip, l.path)!!
            assertEquals(l.sha256, sha(bytes)); assertEquals(l.size, bytes.size.toLong())
        }
    }

    @Test fun packsTheFrozenExample() {
        val src = File("../../spec/scanbundle/examples/frozen-1.0.0")
        assumeTrue("frozen example not present", File(src, "manifest.json").isFile)
        // the example folder also holds README.md / SHA256SUMS, which its manifest does not list: copy only what it lists
        val dir = File(root, "scan_frozen").apply { mkdirs() }
        val manifest = File(src, "manifest.json").readText()
        val paths = BundleArchive.listedFiles(manifest).map { it.path }
        for (p in paths) File(src, p).copyTo(File(dir, p).apply { parentFile!!.mkdirs() })
        File(dir, "manifest.json").writeText(manifest)
        val zip = BundleArchive.pack(dir)
        assertLayout(zip, paths)
        assertEquals(emptyList<String>(), BundleArchive.verify(zip))
        assertTrue(ZipFile(zip).use { z -> z.entries().toList().any { it.name.endsWith(".jpg") && it.method == ZipEntry.STORED } })
        // the folder as it is in the repo (unlisted README.md etc.) must be refused, like archive.py does
        assertRefused(File(root, "plain").also { src.copyRecursively(it) })
    }

    private fun assertRefused(dir: File) {
        try { BundleArchive.pack(dir); fail("expected the pack of ${dir.name} to be refused") } catch (_: BundleArchive.ArchiveException) { }
        assertFalse(BundleArchive.archiveFor(dir).exists())
        assertFalse(File(dir.parentFile, dir.name + ".zip.tmp").exists())
        assertTrue("folder untouched", File(dir, "manifest.json").isFile)
    }

    @Test fun refusesAnUnlistedExtraFile() {
        val dir = bundle(files = sample)
        File(dir, "notes.txt").writeText("not in the manifest")
        assertRefused(dir)
    }

    @Test fun refusesAnUnsafePath() {
        for (bad in listOf("../evil.bin", "a\\b.bin", "/abs.bin", "c:/x.bin", "a//b.bin")) {
            val dir = File(root, "scan_unsafe").apply { deleteRecursively(); mkdirs() }
            File(dir, "camera.json").writeText("{}")
            File(dir, "manifest.json").writeText("""{"files":[{"path":"camera.json","size":2,"sha256":"${sha("{}".toByteArray())}"},{"path":${org(bad)},"size":1,"sha256":"00"}]}""")
            assertRefused(dir)
        }
    }

    private fun org(s: String) = "\"" + s.replace("\\", "\\\\") + "\""

    @Test fun refusesAMissingListedFile() {
        val dir = bundle(files = sample)
        File(dir, "camera.json").delete()
        assertRefused(dir)
    }

    @Test fun staleTempArchiveIsReplacedAndTmpFilesInTheFolderAreNotPacked() {
        val dir = bundle(files = sample)
        File(root, "scan_test.zip.tmp").writeText("garbage from a killed pack")
        File(dir, "keyframes/000009.jpg.tmp").writeText("half written")   // *.tmp is never packed and never an extra
        val zip = BundleArchive.pack(dir)
        assertFalse(File(root, "scan_test.zip.tmp").exists())
        assertLayout(zip, sample.keys)
        assertEquals(emptyList<String>(), BundleArchive.verify(zip))
    }

    @Test fun verifyReportsDamage() {
        val dir = bundle(files = sample)
        val good = BundleArchive.pack(dir)
        // an entry the manifest does not list, and a missing one
        val bad = File(root, "bad.zip")
        ZipFile(good).use { z ->
            ZipOutputStream(bad.outputStream()).use { out ->
                for (e in z.entries()) {
                    if (e.name == "camera.json") continue
                    out.putNextEntry(ZipEntry(e.name)); z.getInputStream(e).use { it.copyTo(out) }; out.closeEntry()
                }
                out.putNextEntry(ZipEntry("extra.txt")); out.write(1); out.closeEntry()
            }
        }
        val p = BundleArchive.verify(bad)
        assertTrue(p.toString(), p.any { it.startsWith("listed file missing: camera.json") })
        assertTrue(p.toString(), p.any { it.startsWith("entries not listed") })
        // a changed byte: sha256 mismatch
        val tampered = File(root, "tampered.zip")
        ZipFile(good).use { z ->
            ZipOutputStream(tampered.outputStream()).use { out ->
                for (e in z.entries()) {
                    out.putNextEntry(ZipEntry(e.name))
                    val b = z.getInputStream(e).use { it.readBytes() }
                    if (e.name == "streams.mcap") b[10] = (b[10] + 1).toByte()
                    out.write(b); out.closeEntry()
                }
            }
        }
        assertTrue(BundleArchive.verify(tampered).any { it.startsWith("sha256 mismatch: streams.mcap") })
        // not a zip at all / unsafe names
        File(root, "junk.zip").writeText("not a zip")
        assertTrue(BundleArchive.verify(File(root, "junk.zip")).single().startsWith("not a readable zip"))
        val evil = File(root, "evil.zip")
        ZipOutputStream(evil.outputStream()).use { out -> out.putNextEntry(ZipEntry("../x")); out.write(1); out.closeEntry() }
        assertTrue(BundleArchive.verify(evil).single().startsWith("unsafe entry names"))
    }

    @Test fun packAndReplaceDeletesTheFolderOnlyAfterTheZipVerified() {
        val dir = bundle(files = sample)
        val zip = BundleArchive.packAndReplace(dir)
        assertNotNull(zip)
        assertFalse("folder gone", dir.exists())
        assertEquals(emptyList<String>(), BundleArchive.verify(zip!!))
    }

    @Test fun packAndReplaceKeepsTheFolderWhenVerifyFails() {
        val dir = bundle(files = sample, wrongSha = "streams.mcap")   // the manifest does not match the file: verify rejects the archive
        val errors = mutableListOf<Throwable>()
        assertNull(BundleArchive.packAndReplace(dir) { errors += it })
        assertEquals(1, errors.size)
        assertTrue(errors[0].message, errors[0].message!!.contains("sha256 mismatch"))
        assertTrue("folder kept", File(dir, "streams.mcap").isFile && File(dir, "manifest.json").isFile)
        assertFalse(File(root, "scan_test.zip").exists())
        assertFalse(File(root, "scan_test.zip.tmp").exists())
    }

    @Test fun packAndReplaceKeepsTheFolderWhenThereIsAnExtraFile() {
        val dir = bundle(files = sample)
        File(dir, "extra.bin").writeText("x")
        assertNull(BundleArchive.packAndReplace(dir))
        assertTrue(File(dir, "extra.bin").isFile && File(dir, "manifest.json").isFile)
    }

    @Test fun readsAFolderAndItsZipTheSameWay() {
        val dir = bundle(files = sample)
        val manifest = BundleArchive.manifestText(dir)
        val zip = BundleArchive.pack(dir)
        assertEquals(manifest, BundleArchive.manifestText(zip))
        assertEquals("bid-1", UploadPlan.bundleId(BundleArchive.manifestText(zip)))
        assertTrue(BundleArchive.readEntry(dir, "keyframes/000000.jpg")!!.contentEquals(BundleArchive.readEntry(zip, "keyframes/000000.jpg")!!))
        assertNull(BundleArchive.readEntry(zip, "nope.bin"))
        assertNull(BundleArchive.readEntry(zip, "../manifest.json"))
        assertEquals(BundleArchive.names(dir), BundleArchive.names(zip))
        assertEquals(zip.length(), BundleArchive.sizeBytes(zip))
        assertEquals(sample.values.sumOf { it.size } + File(dir, "manifest.json").length(), BundleArchive.sizeBytes(dir))
    }

    @Test fun listShowsFoldersAndZipsWithTheFolderFirst() {
        val both = bundle("scan_both", sample); BundleArchive.pack(both)
        bundle("scan_dir", sample)
        BundleArchive.packAndReplace(bundle("scan_zip", sample))
        val half = bundle("scan_half", sample); BundleArchive.pack(half); File(half, "manifest.json").delete()   // cut-short delete: zip wins
        File(root, "scan_both.zip.tmp").writeText("x")
        File(root, "scan_both.research.json").writeText("{}")
        val names = BundleArchive.list(root).map { it.name }.sorted()
        assertEquals(listOf("scan_both", "scan_dir", "scan_half.zip", "scan_zip.zip"), names)
    }

    @Test fun namesAndTmpCleanup() {
        val dir = File(root, "scan_x")
        assertEquals(File(root, "scan_x.zip"), BundleArchive.archiveFor(dir))
        assertEquals(dir, BundleArchive.dirOf(File(root, "scan_x.zip")))
        assertEquals(dir, BundleArchive.dirOf(dir))
        val stale = File(root, "scan_old.zip.tmp").apply { writeText("x") }
        val keep = File(root, "scan_ok.zip").apply { writeText("x") }
        BundleArchive.cleanTmp(root)
        assertFalse(stale.exists()); assertTrue(keep.exists())
    }

    @Test fun manifestParserHandlesEscapesAndOtherKeys() {
        val m = """{"a":{"files":[{"path":"nope"}]},"files":[{"path":"a\"b\\c\u00e9.bin","size":12,"sha256":"ab","x":[1,2.5,null,true]}],"b":-1e3}"""
        val l = BundleArchive.listedFiles(m)
        assertEquals(listOf(BundleArchive.Listed("a\"b\\c\u00e9.bin", 12L, "ab")), l)
        assertEquals(emptyList<BundleArchive.Listed>(), BundleArchive.listedFiles("""{"x":1}"""))
        try { BundleArchive.listedFiles("{not json"); fail() } catch (_: BundleArchive.ArchiveException) { }
    }
}
