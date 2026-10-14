package io.beamlisp.android

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BlRuntimeTest {
    private val app = "otp/lib/beam_lisp-0.1.0/ebin/beam_lisp.app"
    private fun archive(vararg entries: Pair<String, String>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, text) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
    private fun install(root: java.io.File, bytes: ByteArray) =
        BlRuntime.install(root, digest(bytes)) { ByteArrayInputStream(bytes) }
    private fun fails(action: () -> Unit) {
        try { action(); fail("Expected installation failure") } catch (_: IllegalArgumentException) {
        } catch (_: IllegalStateException) { }
    }
    @Test fun freshInstallAndFastRelaunch() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            val bytes = archive(app to "runtime", "otp/pocket/boot.beam" to "app")
            install(root, bytes)
            assertEquals("app", root.resolve("otp/pocket/boot.beam").readText())
            BlRuntime.install(root, digest(bytes)) { error("Already installed: must not open ZIP") }
        } finally { root.deleteRecursively() }
    }
    @Test fun upgradePreservesSettingsAndRemovesOldCode() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            install(root, archive(app to "v1", "otp/old.beam" to "old"))
            root.resolve("pocket-origin").writeText("https://host.tail.ts.net")
            install(root, archive(app to "v2", "otp/new.beam" to "new"))
            assertFalse(root.resolve("otp/old.beam").exists())
            assertEquals("v2", root.resolve(app).readText())
            assertEquals("https://host.tail.ts.net", root.resolve("pocket-origin").readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun checksumFailureKeepsPreviousRuntime() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            install(root, archive(app to "good"))
            val bytes = archive(app to "bad")
            fails { BlRuntime.install(root, "0".repeat(64)) { ByteArrayInputStream(bytes) } }
            assertEquals("good", root.resolve(app).readText())
            assertFalse(root.resolve(".bl-runtime-install").exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun incompleteBundleKeepsPreviousRuntime() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            install(root, archive(app to "good"))
            fails { install(root, archive("otp/incomplete" to "bad")) }
            assertEquals("good", root.resolve(app).readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun rejectsEscapingEntries() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            fails { install(root, archive("otp/../../escaped" to "bad", app to "bad")) }
            assertFalse(root.resolve("otp").exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun rejectsAliasedEntries() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            fails { install(root, archive(app to "one", "otp/./lib/beam_lisp-0.1.0/ebin/beam_lisp.app" to "two")) }
            assertFalse(root.resolve("otp").exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun recoversInterruptedInstall() {
        val root = Files.createTempDirectory("runtime-test").toFile()
        try {
            root.resolve(".bl-runtime-install").mkdirs()
            root.resolve(".bl-runtime-install/partial").writeText("interrupted")
            root.resolve(".bl-runtime-previous").mkdirs()
            install(root, archive(app to "complete"))
            assertEquals("complete", root.resolve(app).readText())
            assertFalse(root.resolve(".bl-runtime-previous").exists())
        } finally { root.deleteRecursively() }
    }
}
