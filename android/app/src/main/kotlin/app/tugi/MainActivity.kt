package app.tugi

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The only native code in the app. Two jobs, both about handing a file to the
 * system:
 *
 *  * "open this file" -- let whichever app owns the type show it: the gallery
 *    for a photo, a player for a video, a music player for audio. Android 7+
 *    requires a content:// URI from our FileProvider; a file:// URI crashes
 *    with FileUriExposedException.
 *  * "save this file wherever the user wants".
 *
 * The gallery cannot hold audio, and `gal` only speaks images and videos, so an
 * exported MP3/FLAC/WAV needs the system's own save dialog
 * (ACTION_CREATE_DOCUMENT). That is also the only way to write into Music/ or
 * Downloads/ on Android 10+ without asking for a storage permission, which
 * keeps this app permission-free.
 *
 * `startActivityForResult` rather than `registerForActivityResult`: the latter
 * is not resolvable from this Activity's base class in this project, and the
 * classic API does the same job for one dialog. The deprecated marker is
 * acceptable here precisely because there is exactly one call site.
 *
 * The bytes are read HERE rather than passed across the channel: a 50 MB audio
 * file would otherwise be copied twice and marshalled through JNI.
 */
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveAs" -> saveAs(
                        call.argument<String>("path"),
                        call.argument<String>("fileName"),
                        result,
                    )
                    "open" -> open(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Ask the system to view [path]. Returns false (not an error) when no app
     * claims the type, so the caller can offer "share" instead.
     */
    private fun open(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("bad_path", "path is empty", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("missing", "file does not exist: $path", null)
            return
        }
        try {
            val uri: Uri =
                FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeTypeOf(file.name))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    /** The extension is a good enough hint; the system refines it from the data. */
    private fun mimeTypeOf(name: String): String =
        when (name.substringAfterLast('.', "").lowercase()) {
            "gif" -> "image/gif"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "apng" -> "image/apng"
            "bmp" -> "image/bmp"
            "tif", "tiff" -> "image/tiff"
            "avif" -> "image/avif"
            "heic" -> "image/heic"
            "mp4", "m4v" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mov" -> "video/quicktime"
            "avi" -> "video/x-msvideo"
            "mp3" -> "audio/mpeg"
            "m4a", "aac" -> "audio/mp4"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "ogg", "opus" -> "audio/ogg"
            else -> "*/*"
        }

    /** Copy the file at [path] to a location the user picks in the system dialog. */
    private fun saveAs(
        path: String?,
        suggestedName: String?,
        result: MethodChannel.Result,
    ) {
        if (path.isNullOrEmpty()) {
            result.error("bad_path", "path is empty", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("missing", "file does not exist: $path", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "a save dialog is already open", null)
            return
        }

        val bytes =
            try {
                file.readBytes()
            } catch (e: Exception) {
                result.error("read_failed", e.message, null)
                return
            }

        pendingResult = result
        pendingBytes = bytes
        // A readable name beats audio_1792597974237.m4a in the save dialog.
        val displayName =
            suggestedName?.takeIf { it.isNotBlank() } ?: file.name
        val intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_TITLE, displayName)
            }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, SAVE_REQUEST)
        } catch (e: Exception) {
            pendingResult = null
            pendingBytes = null
            result.error("launch_failed", e.message, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        val bytes = pendingBytes
        pendingResult = null
        pendingBytes = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || bytes == null) {
            // Backing out of the picker is not an error.
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes) }
            result.success(true)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    private companion object {
        const val CHANNEL = "tugi/export"
        const val SAVE_REQUEST = 4711
    }
}
