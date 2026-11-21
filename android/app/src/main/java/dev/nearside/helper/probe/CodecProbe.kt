// Probe (throwaway): which display sizes the HEVC encoder takes, at what frame rate.
//   app_process / dev.nearside.helper.probe.CodecProbe
package dev.nearside.helper.probe

import android.media.MediaCodecList
import android.media.MediaFormat

object CodecProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .first { it.isEncoder && it.name.contains("exynos") && it.supportedTypes.contains(MediaFormat.MIMETYPE_VIDEO_HEVC) }
        val v = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC).videoCapabilities
        println("${info.name}: widths ${v.supportedWidths} heights ${v.supportedHeights} align ${v.widthAlignment}x${v.heightAlignment}")
        for ((w, h) in listOf(1280 to 2856, 2370 to 2460, 3840 to 2400, 3840 to 2160, 3600 to 2250, 2856 to 1280)) {
            val ok = v.isSizeSupported(w, h)
            val fps = runCatching { v.getSupportedFrameRatesFor(w, h).upper }.getOrNull()
            val achievable = runCatching { v.getAchievableFrameRatesFor(w, h)?.upper }.getOrNull()
            println("${w}x$h: supported $ok, up to ${fps?.toInt()} fps (achievable ${achievable?.toInt()})")
        }
    }
}
