package ai.bithuman.flutter

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.io.File

/**
 * The identity's idle clip — the generated loop the agent plays when it is not
 * speaking, the same `idle.mp4` the cloud service and the web viewer play.
 *
 * ★ This fetch exists because the Android SDK cannot give it to us. `idle.mp4` is a
 * REQUIRED member of the published `.avatar` container, but it is not in the Android
 * manifest `Expression2ModelStore` reads and there is no idle entry point on the
 * Android API, so the store never downloads it and nothing can play it. Filed as
 * bithuman-models#622. A customer would have to write this same file. When the SDK
 * exposes the loop, delete this and use it.
 *
 * The clip is authored seamless and forward-loopable by the trainer, so it is played
 * forward with a wrap and never ping-ponged — reversed playback reads as uncanny, and
 * every player of it rejects that for the same reason.
 */
object IdleClip {

    /** Frames to hold in memory. The Apple SDK caps its own idle loop at 48. */
    private const val MAX_FRAMES = 40

    /**
     * Blocking. Returns an empty list if the clip cannot be had, which the player
     * treats as "no idle" rather than failing the session.
     */
    fun load(context: Context, agentCode: String): List<Bitmap> {
        val file = File(context.cacheDir, "idle-$agentCode.mp4")
        try {
            if (!file.exists() || file.length() < 1000) download(agentCode, file)
        } catch (t: Throwable) {
            Log.w("bhav", "idle clip unavailable: ${t.message}")
            return emptyList()
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return emptyList()
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(file.absolutePath)
            val total = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                ?.toIntOrNull() ?: 0
            if (total <= 0) return emptyList()
            val want = minOf(total, MAX_FRAMES)
            val frames = r.getFramesAtIndex(0, want)
            Log.i("bhav", "idle clip: $want of $total frames")
            frames
        } catch (t: Throwable) {
            Log.w("bhav", "idle clip decode failed: ${t.message}")
            emptyList()
        } finally {
            runCatching { r.release() }
        }
    }

    private fun download(agentCode: String, into: File) {
        val url = "https://api.bithuman.ai/v1/agent/$agentCode/model/download" +
            "?member=idle.mp4&model=expression-2"
        // The platform's own client: a plugin carries no HTTP library for one GET.
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15_000; c.readTimeout = 60_000
            if (c.responseCode !in 200..299) throw IllegalStateException("idle.mp4 HTTP ${c.responseCode}")
            into.outputStream().use { out -> c.inputStream.use { it.copyTo(out) } }
        } finally { c.disconnect() }
    }
}
