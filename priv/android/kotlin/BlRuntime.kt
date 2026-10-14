package io.beamlisp.android

import java.io.File
import java.io.InputStream
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Install the signed APK's runtime before ERTS starts, preserving application data.
 * No Android dependencies: the same installer is exercised by JVM tests.
 */
object BlRuntime {
    @Synchronized
    fun install(filesDir: File, expectedDigest: String, openArchive: () -> InputStream) {
        require(expectedDigest.matches(Regex("[a-f0-9]{64}"))) { "Invalid runtime digest" }
        val runtime = File(filesDir, "otp")
        val marker = File(filesDir, ".bl-runtime")
        val required = "lib/beam_lisp-0.1.0/ebin/beam_lisp.app"
        if (marker.isFile && marker.readText().trim() == expectedDigest &&
            File(runtime, required).isFile) return

        val stage = File(filesDir, ".bl-runtime-install")
        val backup = File(filesDir, ".bl-runtime-previous")
        stage.deleteRecursively()
        check(stage.mkdirs()) { "Cannot create runtime staging directory" }
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            openArchive().use { raw ->
                val checked = DigestInputStream(raw, digest)
                val zip = ZipInputStream(checked)
                val seen = HashSet<String>()
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(entry.name.startsWith("otp/")) { "Runtime entry outside otp/" }
                    val target = File(stage, entry.name)
                    require(target.canonicalPath.startsWith(stage.canonicalPath + File.separator)) {
                        "Runtime entry escapes staging directory"
                    }
                    require(seen.add(target.canonicalPath)) { "Duplicate runtime entry" }
                    if (entry.isDirectory) {
                        check(target.isDirectory || target.mkdirs()) { "Cannot create runtime directory" }
                    } else {
                        check(target.parentFile.isDirectory || target.parentFile.mkdirs())
                        target.outputStream().use { zip.copyTo(it) }
                    }
                    zip.closeEntry()
                }
                // ZIP's central directory may remain unread by ZipInputStream.
                val remainder = ByteArray(8192)
                while (checked.read(remainder) != -1) { }
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                check(actual == expectedDigest) { "Runtime checksum mismatch" }
            }
            val candidate = File(stage, "otp")
            check(File(candidate, required).isFile) { "Incomplete runtime bundle" }
            backup.deleteRecursively()
            if (runtime.exists()) check(runtime.renameTo(backup)) { "Cannot retain previous runtime" }
            if (!candidate.renameTo(runtime)) {
                if (backup.exists()) backup.renameTo(runtime)
                error("Cannot install runtime")
            }
            val pendingMarker = File(filesDir, ".bl-runtime-next")
            pendingMarker.writeText(expectedDigest)
            check(pendingMarker.renameTo(marker)) { "Cannot commit runtime version" }
            backup.deleteRecursively()
        } finally {
            stage.deleteRecursively()
        }
    }
}
