// One phone app shown in one Mac window: its own virtual display, a hardware HEVC encoder fed by
// that display, input injected into it, and the app's task tracked so the Mac knows when it ends.
// Encoder setup and input injection adapted from scrcpy (Apache-2.0, Copyright (C) Genymobile).
package dev.nearside.helper.display

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Intent
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DisplaySession(
    val id: String,
    private val server: DisplayServer,
    open: DisplayWire.Open,
) {
    companion object {
        // PUBLIC | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | TRUSTED | OWN_DISPLAY_GROUP | ALWAYS_UNLOCKED |
        // TOUCH_FEEDBACK_DISABLED | OWN_FOCUS. OWN_CONTENT_ONLY matters: without it an empty display
        // mirrors the phone's own screen. No system decorations: on Android 17 they divert launches
        // into desktop "desks" (and fail while locked). See vault/phone-apps-plan.md, Gate A.
        const val FLAGS = (1 shl 0) or (1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 11) or (1 shl 12) or
            (1 shl 13) or (1 shl 14)
        private const val GRACE_MS = 30_000L
        private const val LAUNCH_TIMEOUT_MS = 10_000L
    }

    private var w = open.width
    private var h = open.height
    private var dpi = open.dpi
    private val fps = open.fps
    private val kbps = open.kbps
    private val target = open.target
    /** The phone window: our home screen, and whatever is opened from it, on one display. */
    val isHome = target == DisplayWire.HOME_TARGET
    @Volatile private var homeTask = -1
    @Volatile private var dock: List<String> = emptyList()

    private lateinit var display: VirtualDisplay
    val displayId get() = display.display.displayId
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var gen = 0
    @Volatile private var lastConfig: ByteArray? = null
    @Volatile private var closed = false
    @Volatile private var ctl: DisplayWire.Conn? = null
    @Volatile private var video: DisplayWire.Conn? = null
    private var taskId = -1
    private var taskGone = false
    private var hiddenPolls = 0
    private val openedAt = SystemClock.uptimeMillis()
    private val watcher = Executors.newSingleThreadScheduledExecutor { Thread(it, "display-$id-tasks") }
    private var awake: android.os.PowerManager.WakeLock? = null
    private var keyboard: Keyboard? = null
    /** This window's virtual device (null: a plain display, no Mac sound or locked clipboard). */
    private var device: PhoneDevice? = null
    private var touchscreen: Any? = null
    /** The window's sound (started with the display, if on the virtual device). */
    private val audio = AudioStreamer("display-$id")
    private var hasAudio = false

    /** The phone wouldn't make another video encoder (too many windows). */
    class EncoderBusy(cause: Throwable) : Exception(cause)

    fun start() {
        val surface = try { newEncoder() } catch (e: Exception) { throw EncoderBusy(e) }
        // On the virtual device (own clipboard and keyboard, works locked), else a plain display.
        device = PhoneDevice.create("Nearside ${id.take(8)}")
        display = device?.createDisplay("nearside-$id", w, h, dpi, surface, FLAGS)
            ?: run { device?.close(); device = null; null }
            ?: Hidden.displayManager.createVirtualDisplay("nearside-$id", w, h, dpi, surface, FLAGS)
        Log.d("display session $id: display $displayId ${w}x$h@$dpi for $target${device?.let { " (virtual device ${it.deviceId})" } ?: ""}")
        awake = Hidden.keepAwake(displayId, "Nearside:display-$id")
        keyboard = Keyboard(displayId, id, device).also { it.create() }
        touchscreen = device?.createTouchscreen("Nearside Touch ${id.take(8)}", displayId, w, h)
        // Before the launch, so the app's sound never starts on the phone's speaker.
        hasAudio = device?.let { audio.start(it, display) } ?: false
        if (device == null) audio.stop()
        Thread(::encodeLoop, "display-$id-video").start()
        launch()
        watcher.scheduleWithFixedDelay({ runCatching { watchTasks() } }, 300, 500, TimeUnit.MILLISECONDS)
        watcher.scheduleWithFixedDelay({ logStats() }, 5, 5, TimeUnit.SECONDS)
        watcher.scheduleWithFixedDelay({ runCatching { sleepWhenLongHidden() } }, 5, 5, TimeUnit.SECONDS)
    }

    // MARK: - Connections

    fun attachControl(conn: DisplayWire.Conn) {
        ctl?.close()
        ctl = conn
        Thread({ controlLoop(conn) }, "display-$id-ctl").start()
        if (Thermal.moderate) sendThermal()
        if (taskId != -1) sendTask()
    }

    fun attachVideo(conn: DisplayWire.Conn) {
        video?.close()
        video = conn
        catchingUp = false // a new stream: nothing in flight
        awaitingKey = true
        lastConfig?.let { conn.send(DisplayWire.CONFIG, it) }
        requestKeyframe()
    }

    fun attachAudio(conn: DisplayWire.Conn) {
        audio.attach(conn)
    }

    private fun controlLoop(conn: DisplayWire.Conn) {
        try {
            while (!closed) {
                val (type, body) = conn.read() ?: break
                handle(type, ByteBuffer.wrap(body))
            }
        } catch (e: Exception) {
            Log.d("display session $id: control ended ($e)")
        } finally {
            conn.close()
            if (ctl === conn && !closed) {
                ctl = null
                // The Mac may come back (Wi-Fi blip, sleep): keep the app where it is for a while.
                Log.d("display session $id: Mac gone; keeping it for ${GRACE_MS / 1000} s")
                watcher.schedule({ if (ctl == null && !closed) close(toPhone = true) }, GRACE_MS, TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun handle(type: Int, b: ByteBuffer) {
        when (type) {
            DisplayWire.TOUCH -> if (b.remaining() >= 14) {
                touch(b.get().toInt(), b.get().toInt(), b.int, b.float, b.float, if (b.remaining() >= 8) b.long else 0)
            }
            DisplayWire.SCROLL -> if (b.remaining() >= 20) scroll(b.int, b.float, b.float, b.float, b.float)
            DisplayWire.MOUSE -> if (b.remaining() >= 13) mouse(b.get().toInt(), b.int, b.float, b.float)
            DisplayWire.KEY -> if (b.remaining() >= 6) keyboard?.press(b.short.toInt() and 0xffff, b.int)
            DisplayWire.TEXT -> keyboard?.type(utf8(b))
            DisplayWire.LAYOUT -> keyboard?.setLayout(utf8(b))
            DisplayWire.PASTE -> keyboard?.paste(utf8(b).ifEmpty { null }, restore = false)
            DisplayWire.RESIZE -> if (b.remaining() >= 6) {
                resize(b.short.toInt() and 0xffff, b.short.toInt() and 0xffff, b.short.toInt() and 0xffff)
            }
            DisplayWire.NAV -> if (b.remaining() >= 1) nav(b.get().toInt())
            DisplayWire.RECENTS -> if (isHome) watcher.execute { runCatching { sendRecents() } }
            DisplayWire.TASK_FRONT -> if (isHome && b.remaining() >= 4) b.int.let { t -> if (onDisplay(t)) Hidden.taskToFront(t) }
            DisplayWire.TASK_REMOVE -> if (isHome && b.remaining() >= 4) b.int.let { t -> if (onDisplay(t) && t != homeTask) Hidden.removeTask(t) }
            DisplayWire.DOCK -> if (isHome) {
                dock = utf8(b).lines().filter { it.matches(Regex("[A-Za-z0-9_.]+")) }.take(6)
                // Shown now: update it (starting it again would bring it over an open app otherwise).
                if (Hidden.rootTasks().any { it.taskId == homeTask && it.visible }) launchHome(toFront = false)
            }
            DisplayWire.ACK -> if (b.remaining() >= 8) acked(b.long)
            DisplayWire.PING -> if (b.remaining() >= 8) {
                val t0 = b.long
                ctl?.send(DisplayWire.PONG, ByteBuffer.allocate(16).putLong(t0).putLong(System.nanoTime() / 1000).array())
            }
            DisplayWire.VISIBILITY -> if (b.remaining() >= 1) setVisibility(b.get().toInt())
            DisplayWire.SYNC -> requestKeyframe()
            // CLOSE: u8 1 = bring the app to the front on the phone ("Open on Phone").
            DisplayWire.CLOSE -> close(toPhone = true, onTop = b.remaining() >= 1 && b.get().toInt() == 1)
            DisplayWire.BLACK -> if (b.remaining() >= 1) black(b.get().toInt() == 1)
        }
    }

    private fun utf8(b: ByteBuffer) = String(b.array(), b.arrayOffset() + b.position(), b.remaining(), Charsets.UTF_8)

    // MARK: - App

    // MARK: - Phone window

    private fun onDisplay(task: Int) = Hidden.rootTasks().any { it.taskId == task && it.displayId == displayId }

    /**
     * Our home screen on this display: started (or brought to the front, with the current dock)
     * by the shell, which alone may start it. Its own task affinity keeps it — and the apps it
     * opens — here (Gate A).
     */
    private fun launchHome(toFront: Boolean) {
        val intent = Intent().setClassName("dev.nearside", "dev.nearside.phone.HomeActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("dock", dock.toTypedArray())
            .putExtra("toFront", toFront)
        val options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId).toBundle()
        if (!Hidden.startActivity(intent, options)) fail(DisplayWire.ERR_LAUNCH, "couldn't open the phone's home screen")
    }

    /** The display's apps (top first, without the home screen), then each one's snapshot. */
    private fun sendRecents() {
        val tasks = Hidden.rootTasks().filter { it.displayId == displayId && it.taskId != homeTask && it.packageName != null }
        val json = org.json.JSONArray()
        tasks.forEach { json.put(org.json.JSONObject().put("id", it.taskId).put("pkg", it.packageName)) }
        ctl?.send(DisplayWire.TASKS, json.toString().toByteArray())
        for (t in tasks) {
            val jpeg = Snapshots.jpeg(t.taskId, t.visible) ?: continue
            ctl?.send(DisplayWire.SNAPSHOT, ByteBuffer.allocate(4).putInt(t.taskId).array() + jpeg)
        }
    }

    /** The phone window: knows its home task; relaunches the home screen if it went. */
    private fun watchHome() {
        val home = Hidden.rootTasks().firstOrNull { it.displayId == displayId && it.packageName == "dev.nearside" }
        if (home != null) {
            val found = homeTask != home.taskId
            if (found) Log.d("display session $id: home task ${home.taskId}")
            homeTask = home.taskId
            if (found && dock.isNotEmpty() && home.visible) launchHome(toFront = false) // the dock came first
            if (taskId == -1) { taskId = home.taskId; sendTask() }
        } else if (homeTask != -1 || SystemClock.uptimeMillis() - openedAt > LAUNCH_TIMEOUT_MS) {
            Log.d("display session $id: home screen gone; starting it again")
            homeTask = -1
            launchHome(toFront = true)
        }
    }

    private fun launch() {
        if (isHome) Snapshots.warmUp()
        if (isHome) return launchHome(toFront = true)
        val component = if ('/' in target) ComponentName.unflattenFromString(target) else null
        val pkg = component?.packageName ?: target
        // A running app is moved over, keeping its state, rather than started again.
        val existing = Hidden.rootTasks().firstOrNull { it.packageName == pkg && it.displayId != displayId }
        if (existing != null && Hidden.moveTask(existing.taskId, displayId, onTop = true)) {
            Log.d("display session $id: moved task ${existing.taskId} ($pkg) here")
            return
        }
        val intent = (if (component != null) Intent(Intent.ACTION_MAIN).setComponent(component)
            .addCategory(Intent.CATEGORY_LAUNCHER) else FakeContext.instance.packageManager.getLaunchIntentForPackage(pkg))
            ?: return fail(DisplayWire.ERR_NOT_FOUND, "$pkg has nothing to open")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId).toBundle()
        if (!Hidden.startActivity(intent, options) && !shellStart(intent)) {
            fail(DisplayWire.ERR_LAUNCH, "couldn't open $pkg")
        }
    }

    private fun shellStart(intent: Intent): Boolean {
        val c = intent.component ?: return false
        return runCatching {
            Runtime.getRuntime().exec(arrayOf("am", "start", "--display", "$displayId", "-n", c.flattenToShortString()))
                .waitFor() == 0
        }.getOrDefault(false)
    }

    private fun fail(code: Int, message: String) {
        Log.d("display session $id: $message")
        ctl?.send(DisplayWire.ERROR, byteArrayOf(code.toByte()) + message.toByteArray())
    }

    // MARK: - Secure apps
    //
    // An app window with FLAG_SECURE (banking apps) is drawn black into our display. The Mac
    // notices a black picture and asks; only then is the window list read (`dumpsys window`
    // costs ~100 ms of system_server time, too much to poll), and again every 3 s while it stays
    // black, so the window can say why it's black (and that it's no longer).

    @Volatile private var secure = false
    private var blackCheck: java.util.concurrent.ScheduledFuture<*>? = null

    @Synchronized
    private fun black(isBlack: Boolean) {
        blackCheck?.cancel(false)
        blackCheck = null
        if (isBlack) {
            blackCheck = watcher.scheduleWithFixedDelay({ runCatching { checkSecure() } }, 0, 3, TimeUnit.SECONDS)
        } else if (secure) {
            secure = false
            ctl?.send(DisplayWire.SECURE, byteArrayOf(0))
        }
    }

    private fun checkSecure() {
        val p = Runtime.getRuntime().exec(arrayOf("dumpsys", "window", "windows"))
        val text = p.inputStream.bufferedReader().readText().also { p.waitFor() }
        // Per window: "mDisplayId=<id> …", "fl=… SECURE …", "isVisible=true".
        val found = text.split("  Window #").any { w ->
            w.contains("mDisplayId=$displayId ") && Regex("\\bfl=[^\\n]*\\bSECURE\\b").containsMatchIn(w) && w.contains("isVisible=true")
        }
        if (found == secure) return
        secure = found
        Log.d("display session $id: ${if (found) "an app window blocks capture (FLAG_SECURE)" else "no secure window"}")
        ctl?.send(DisplayWire.SECURE, byteArrayOf(if (found) 1 else 0))
    }

    fun owns(task: Int) = !closed && if (isHome) task != homeTask && onDisplay(task) else !taskGone && taskId == task

    /**
     * Something started this window's app again. Android brings an existing task to the front on
     * the display it's on — ours — so tapping its icon on the phone did nothing there. If the
     * phone is in use (screen on), that was the person on the phone: the app goes to the phone,
     * and the window says so (the task poller reports the move).
     */
    fun openedOnPhone(task: Int) {
        val power = FakeContext.instance.getSystemService(android.os.PowerManager::class.java)
        if (power?.isInteractive != true) return Log.d("display session $id: task $task restarted with the phone's screen off; staying")
        Log.d("display session $id: task $task opened on the phone; moving it there")
        matchPhone() // the phone window is phone-sized already: nothing to do there
        Hidden.moveTask(task, 0, onTop = true)
        if (!isHome) watcher.execute { runCatching { watchTasks() } } // tell the Mac now, not at the next poll
    }

    /**
     * Before an app goes back to the phone, give it the phone's size (in dp) here and let it lay
     * itself out. Apps that handle size changes themselves don't all undo a layout when moved:
     * YouTube, made wide in a window, kept its tablet layout on the phone until it was killed —
     * yet it does switch back when its window shrinks. After this the move changes nothing but
     * density, which they handle.
     */
    private fun matchPhone() = runCatching {
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        Hidden.displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY).getRealMetrics(metrics)
        val nw = (metrics.widthPixels.toLong() * dpi / metrics.densityDpi).toInt() and 1.inv()
        val nh = (metrics.heightPixels.toLong() * dpi / metrics.densityDpi).toInt() and 1.inv()
        if (nw == w && nh == h) return@runCatching
        display.resize(nw, nh, dpi)
        Log.d("display session $id: phone-sized (${nw}x$nh@$dpi) before going back")
        Thread.sleep(400) // the app's relayout
    }.onFailure { Log.d("display session $id: couldn't match the phone's size: $it") }

    /** Polled: which task is ours, and did it leave (closed, or moved to the phone)? */
    private fun watchTasks() {
        if (closed) return
        if (isHome) return watchHome()
        val tasks = Hidden.rootTasks()
        if (taskId == -1) {
            val mine = tasks.firstOrNull { it.displayId == displayId }
            if (mine != null) {
                taskId = mine.taskId
                Log.d("display session $id: task $taskId (${mine.packageName})")
                sendTask()
            } else if (SystemClock.uptimeMillis() - openedAt > LAUNCH_TIMEOUT_MS && !taskGone) {
                taskGone = true
                fail(DisplayWire.ERR_LAUNCH, "the app didn't open")
            }
            return
        }
        if (taskGone) return
        val task = tasks.firstOrNull { it.taskId == taskId }
        if (task?.displayId == displayId) {
            // Back on an app's first screen sends it to the background (Android 12+) instead of
            // closing it; on our display nothing is behind it, so the window would just go black.
            hiddenPolls = if (task.visible) 0 else hiddenPolls + 1
            if (hiddenPolls < 2) return
            taskGone = true
            Log.d("display session $id: task $taskId went to the background")
            ctl?.send(DisplayWire.TASK_GONE, byteArrayOf(DisplayWire.GONE_EXITED.toByte()))
            return
        }
        taskGone = true
        val reason = if (task != null) DisplayWire.GONE_MOVED else DisplayWire.GONE_EXITED
        Log.d("display session $id: task $taskId ${if (task != null) "moved to display ${task.displayId}" else "ended"}")
        ctl?.send(DisplayWire.TASK_GONE, byteArrayOf(reason.toByte()))
    }

    private fun sendTask() {
        val pkg = Hidden.rootTasks().firstOrNull { it.taskId == taskId }?.packageName ?: ""
        ctl?.send(DisplayWire.TASK, ByteBuffer.allocate(4).putInt(taskId).array() + pkg.toByteArray())
    }

    // MARK: - Video

    private fun newEncoder(): Surface {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, budgetKbps() * 1000)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 10f)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setFloat("max-fps-to-encoder", budgetFps().toFloat().also { encoderFps = it.toInt() })
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = c.createInputSurface()
        c.start()
        gen++
        codec = c
        return surface
    }

    private fun encodeLoop() {
        val info = MediaCodec.BufferInfo()
        while (!closed) {
            val c = codec ?: break
            val myGen = gen
            // A resize swaps the codec under us; the old one then throws, which is fine.
            val data = try {
                val index = c.dequeueOutputBuffer(info, 50_000)
                if (index < 0) continue
                val buf = c.getOutputBuffer(index) ?: continue
                ByteArray(info.size).also { buf.get(it); c.releaseOutputBuffer(index, false) }
            } catch (e: IllegalStateException) {
                continue
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                val config = ByteBuffer.allocate(8 + data.size).putInt(myGen).putShort(w.toShort())
                    .putShort(h.toShort()).put(data).array()
                lastConfig = config
                video?.send(DisplayWire.CONFIG, config)
                continue
            }
            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            // Catching up: nothing new goes out until the backlog has arrived; then the next
            // keyframe restarts the picture (frames after a gap can't be decoded without one).
            if (catchingUp && SystemClock.uptimeMillis() - catchStart > 2000) {
                catchingUp = false // the last ack never came (a dropped stream?): carry on
                requestKeyframe()
            }
            if (catchingUp) { awaitingKey = true; continue }
            if (awaitingKey && !key) continue
            awaitingKey = false
            val frame = ByteBuffer.allocate(21 + data.size).putInt(myGen).putLong(info.presentationTimeUs)
                .putLong(System.nanoTime() / 1000).put(if (key) 1 else 0).put(data).array()
            video?.let {
                lastSentPts = info.presentationTimeUs
                it.send(DisplayWire.FRAME, frame)
                framesSent++
                bytesSent += frame.size
            }
        }
    }

    @Volatile private var awaitingKey = false
    @Volatile private var framesSent = 0
    @Volatile private var bytesSent = 0L

    private fun logStats() {
        val frames = framesSent; val bytes = bytesSent
        framesSent = 0; bytesSent = 0
        if (frames == 0 && touchesOk == 0 && touchesFailed == 0) return
        Log.d("display session $id: $frames frames, ${bytes * 8 / 5000} kbps (budget ${budgetKbps()}), " +
            "lag max ${lagMax / 1000} ms, touches ok $touchesOk failed $touchesFailed, video ${if (video == null) "detached" else "attached"}")
        lagMax = 0
        touchesOk = 0; touchesFailed = 0
    }

    private fun requestKeyframe() {
        runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
    }

    // MARK: - Budget
    //
    // The phone has one hardware video encoder block shared by every window (and its camera), and
    // it heats up. Each window gets a share by how it's seen on the Mac: the one in use full rate,
    // others on screen a lower frame rate and bitrate, hidden ones nothing (the encoder suspends;
    // the app keeps running and isn't told).

    @Volatile private var visibility = DisplayWire.VIS_FOCUSED

    /** Warm phone (moderate): everything 30 % lower. */
    private val heat get() = if (Thermal.moderate) 0.7 else 1.0

    private fun budgetFps(): Int = when (visibility) {
        DisplayWire.VIS_FOCUSED -> (fps * heat).toInt()
        else -> minOf((minOf(fps, 30) * heat).toInt(), shareFps)
    }.coerceAtLeast(5)

    /** What the server's pixel budget leaves this window when it isn't the one in use. */
    @Volatile private var shareFps = 60

    /** For the server's budget. */
    val pixels get() = w.toLong() * h
    val isFocused get() = visibility == DisplayWire.VIS_FOCUSED
    val isEncoding get() = !closed && !suspended
    val focusedFps get() = (fps * heat).toInt()

    /** The server's share for this window (frames per second when not in use); applies it. */
    fun setShare(fpsShare: Int) {
        shareFps = fpsShare
        applyBudget()
    }

    /** The bitrate grows with the picture: 12 Mbps per 2.6 Mpx (a phone-sized window), 30 at most. */
    private val baseKbps get() = minOf(30_000, maxOf(kbps, (w.toLong() * h * 12_000 / 2_600_000).toInt()))

    private fun budgetKbps(): Int = (when (visibility) {
        DisplayWire.VIS_FOCUSED -> baseKbps
        else -> baseKbps * 6 / 10
    } * congestion * heat).toInt().coerceAtLeast(500)

    /** Not encoding: hidden, or a hot phone (severe) keeps only the window in use going. */
    private val suspended get() = visibility == DisplayWire.VIS_HIDDEN ||
        (Thermal.severe && visibility != DisplayWire.VIS_FOCUSED)

    fun thermalChanged() {
        if (!suspended) requestKeyframe() // may have been suspended until now
        sendThermal()
        Log.d("display session $id: phone ${if (Thermal.moderate) "warm" else "cool"} → " +
            if (suspended) "suspended" else "${budgetFps()} fps, ${budgetKbps()} kbps")
    }

    private fun sendThermal() = ctl?.send(DisplayWire.THERMAL, byteArrayOf(if (Thermal.moderate) 1 else 0))

    // MARK: Congestion
    //
    // The Mac acks every frame it receives; frame timestamps are on this phone's clock, so
    // now − pts of an acked frame is how far behind the window is (capture → Mac). The video
    // stream's adb window (2 MiB) would otherwise hide seconds of backlog from the sender.

    /** 0.1…1: the share of the budget's bitrate the network takes. */
    @Volatile private var congestion = 1.0
    @Volatile private var catchingUp = false
    @Volatile private var lastSentPts = 0L
    @Volatile private var lastCut = 0L
    @Volatile private var healthySince = 0L
    @Volatile private var lagMax = 0L
    @Volatile private var catchStart = 0L

    private fun acked(pts: Long) {
        val lag = System.nanoTime() / 1000 - pts
        val now = SystemClock.uptimeMillis()
        lagMax = maxOf(lagMax, lag)
        when {
            lag > 200_000 && !catchingUp -> {
                // Behind: stop sending until what's in flight has arrived, then start again from
                // a keyframe at a lower bitrate (drops the backlog instead of showing it late).
                catchingUp = true
                catchStart = now
                if (now - lastCut > 1000) {
                    congestion = maxOf(congestion * 0.7, 0.1)
                    lastCut = now
                    applyBudget()
                }
                healthySince = 0
                Log.d("display session $id: ${lag / 1000} ms behind; dropping frames, bitrate ${budgetKbps()} kbps")
            }
            catchingUp && pts >= lastSentPts -> {
                catchingUp = false // everything sent has arrived
                requestKeyframe()
                Log.d("display session $id: caught up")
            }
            lag < 80_000 && !catchingUp -> {
                if (healthySince == 0L) healthySince = now
                if (congestion < 1 && now - healthySince > 2000) {
                    congestion = minOf(congestion * 1.1, 1.0)
                    healthySince = now
                    applyBudget()
                }
            }
            else -> healthySince = 0
        }
    }

    /** The frame-rate cap the current encoder was made with. */
    @Volatile private var encoderFps = 0

    /**
     * Applies the budget. Bitrate and suspending change on the running encoder; the frame-rate cap
     * doesn't (Exynos HEVC ignored "max-fps-to-encoder" in setParameters: 300 frames per 5 s
     * either way), so a new cap means a new encoder, as a resize does (~0.1 s, one keyframe).
     */
    @Synchronized
    private fun applyBudget() {
        if (closed) return
        sleepWhenLongHidden()
        if (!suspended && budgetFps() != encoderFps) return replaceEncoder()
        runCatching {
            codec?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_SUSPEND, if (suspended) 1 else 0)
                putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, budgetKbps() * 1000)
            })
        }.onFailure { Log.d("display session $id: budget not applied: $it") }
    }

    // MARK: Sleeping when hidden
    //
    // The display's wake lock keeps it (and its app) running. A window hidden for a while and
    // silent lets its display sleep, as the phone's own screen would: the app is stopped like
    // any app behind a screen that's off. Shown again, the lock wakes it. Music keeps playing:
    // a display that made a sound in the last 30 s stays awake.

    private var suspendedSince = 0L
    private var asleep = false

    @Synchronized
    private fun sleepWhenLongHidden() {
        val now = SystemClock.uptimeMillis()
        if (!suspended) {
            suspendedSince = 0
            if (asleep) {
                asleep = false
                runCatching { awake?.acquire() } // ACQUIRE_CAUSES_WAKEUP: the display wakes
                requestKeyframe()
                Log.d("display session $id: awake again")
            }
            return
        }
        if (suspendedSince == 0L) suspendedSince = now
        if (asleep || now - suspendedSince < sleepAfterMs) return
        if (hasAudio && now - audio.lastSoundAt < 30_000) return
        asleep = true
        runCatching { awake?.release() }
        Log.d("display session $id: hidden ${(now - suspendedSince) / 1000} s and silent; letting the display sleep")
    }

    /** 2 minutes, or `debug.nearside.sleep_after_s` (tests). */
    private val sleepAfterMs: Long by lazy {
        runCatching {
            val p = Runtime.getRuntime().exec(arrayOf("getprop", "debug.nearside.sleep_after_s"))
            p.inputStream.bufferedReader().readText().trim().also { p.waitFor() }.toLong() * 1000
        }.getOrDefault(120_000L)
    }

    /** A new encoder for the display at the current size and budget. */
    @Synchronized
    private fun replaceEncoder() {
        val old = codec
        display.surface = newEncoder()
        old?.let { runCatching { it.stop() }; it.release() }
    }

    private fun setVisibility(level: Int) {
        if (level == visibility) return
        val wasSuspended = suspended
        visibility = level
        server.rebalance() // applies every window's budget, this one's too
        Log.d("display session $id: ${listOf("focused", "hidden", "visible").getOrElse(level) { "?" }} → ${if (suspended) "suspended" else "${budgetFps()} fps, ${budgetKbps()} kbps"}")
        if (wasSuspended && !suspended) requestKeyframe()
    }

    @Synchronized
    private fun resize(nw: Int, nh: Int, ndpi: Int) {
        if (closed || nw < 64 || nh < 64 || nw > 4096 || nh > 4096 || ndpi !in 72..640) return
        if (nw == w && nh == h && ndpi == dpi) return
        // Fingers and the pointer are in the old size's pixels: end them first.
        cancelFingers()
        endMouse(SystemClock.uptimeMillis())
        val old = codec
        w = nw and 1.inv(); h = nh and 1.inv(); dpi = ndpi
        val surface = newEncoder()
        display.resize(w, h, dpi)
        touchscreen?.let { // made for a size: a new one for the new size
            PhoneDevice.closeInput(it)
            touchscreen = device?.createTouchscreen("Nearside Touch ${id.take(8)}", displayId, w, h)
        }
        display.surface = surface
        old?.let { runCatching { it.stop() }; it.release() }
        Log.d("display session $id: resized to ${w}x$h@$dpi")
        watcher.execute { server.rebalance() } // more or fewer pixels (not under this lock: the server takes it)
    }

    // MARK: - Input
    //
    // Everything here runs on the control thread. Fingers are built as scrcpy builds them
    // (Controller.injectTouch): explicit pointer properties (TOOL_TYPE_FINGER), pressure 1 while
    // down and 0 when lifted, and a stream that stays consistent whatever arrives: Android 17's
    // input dispatcher rejects everything after an inconsistent event (a lost UP would wedge the
    // app). Pointer ids: 0 the mouse button, 1 the trackpad-scroll finger, 2–3 pinch/rotate.
    // Fingers and the mouse pointer share a device, so they never overlap: hovering ends before a
    // finger goes down, and the mouse is ignored while one is down.

    private class Finger(val id: Int, var x: Float, var y: Float)
    private val fingers = ArrayList<Finger>() // in DOWN order (= pointer index)
    private var downTime = 0L
    private var lastEventTime = 0L
    private var macBase = 0L
    private var phoneBase = 0L
    private var hovering = false
    private var secondaryDown = false
    private var mouseDownTime = 0L
    private var touchesOk = 0
    private var touchesFailed = 0

    private fun touch(action: Int, pointer: Int, touchGen: Int, x: Float, y: Float, macMicros: Long) {
        if (touchGen != gen || action !in 0..3 || pointer !in 0..9) return // a stale size, or junk
        // A scroll-drag finger may go past the edges (Android keeps delivering it to its window).
        val px = x.coerceIn(-2f, 3f) * w
        val py = y.coerceIn(-2f, 3f) * h
        val index = fingers.indexOfFirst { it.id == pointer }
        when (action) {
            0 -> { // DOWN
                if (fingers.isEmpty()) { macBase = macMicros; phoneBase = SystemClock.uptimeMillis() }
                val t = eventTime(macMicros)
                if (index >= 0) lift(index, t) // its UP got lost
                // Landing outside every window would be rejected (and wedge the stream).
                val finger = Finger(pointer, px.coerceIn(0f, w - 1f), py.coerceIn(0f, h - 1f))
                if (fingers.isEmpty()) {
                    endMouse(t)
                    downTime = t
                    fingers.add(finger)
                    injectFingers(MotionEvent.ACTION_DOWN, t)
                } else {
                    fingers.add(finger)
                    injectFingers(MotionEvent.ACTION_POINTER_DOWN or ((fingers.size - 1) shl 8), t)
                }
            }
            2 -> if (index >= 0) { // MOVE
                fingers[index].x = px; fingers[index].y = py
                injectFingers(MotionEvent.ACTION_MOVE, eventTime(macMicros))
            }
            1 -> if (index >= 0) { // UP
                fingers[index].x = px; fingers[index].y = py
                lift(index, eventTime(macMicros))
            }
            3 -> cancelFingers()
        }
    }

    private fun lift(index: Int, t: Long) {
        if (fingers.size == 1) injectFingers(MotionEvent.ACTION_UP, t, lifted = 0)
        else injectFingers(MotionEvent.ACTION_POINTER_UP or (index shl 8), t, lifted = index)
        fingers.removeAt(index)
    }

    private fun cancelFingers() {
        if (fingers.isEmpty()) return
        injectFingers(MotionEvent.ACTION_CANCEL, eventTime(0))
        fingers.clear()
    }

    /**
     * The Mac's event times, mapped onto ours, so a fling's speed is the hand's, not the network's
     * jitter. The mapping follows the fastest delivery seen in the gesture, so it's never in the
     * future, and times never go backwards.
     */
    private fun eventTime(macMicros: Long): Long {
        val now = SystemClock.uptimeMillis()
        var t = if (macMicros > 0 && macBase > 0) phoneBase + (macMicros - macBase) / 1000 else now
        if (t > now) { phoneBase -= t - now; t = now }
        t = maxOf(t, lastEventTime)
        lastEventTime = t
        return t
    }

    private fun injectFingers(action: Int, t: Long, lifted: Int = -1) {
        val n = fingers.size
        val props = Array(n) { i -> MotionEvent.PointerProperties().apply { id = fingers[i].id; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        val coords = Array(n) { i ->
            MotionEvent.PointerCoords().apply { x = fingers[i].x; y = fingers[i].y; size = 1f; pressure = if (i == lifted) 0f else 1f }
        }
        val event = MotionEvent.obtain(downTime, t, action, n, props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        val ok = runCatching { Hidden.inject(event, displayId) }.getOrDefault(false)
        event.recycle()
        if (ok) touchesOk++ else {
            touchesFailed++
            Log.d("display session $id: injecting touch action $action ($n pointer(s)) failed")
        }
    }

    // The mouse pointer itself: hover (web pages, tooltips) and the right button (context click).

    private fun mouse(kind: Int, mouseGen: Int, x: Float, y: Float) {
        if (mouseGen != gen || fingers.isNotEmpty()) return
        val px = x.coerceIn(0f, 1f) * (w - 1)
        val py = y.coerceIn(0f, 1f) * (h - 1)
        val now = SystemClock.uptimeMillis()
        when (kind) {
            DisplayWire.MOUSE_HOVER -> if (!secondaryDown) {
                injectMouse(MotionEvent.ACTION_HOVER_MOVE, now, now, px, py, 0)
                hovering = true
            }
            DisplayWire.MOUSE_EXIT -> endMouse(now)
            DisplayWire.MOUSE_SECONDARY_DOWN -> if (!secondaryDown) {
                endMouse(now)
                mouseDownTime = now
                secondaryDown = true
                injectMouse(MotionEvent.ACTION_DOWN, now, now, px, py, MotionEvent.BUTTON_SECONDARY)
                injectMouse(MotionEvent.ACTION_BUTTON_PRESS, now, now, px, py, MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_SECONDARY)
            }
            DisplayWire.MOUSE_SECONDARY_UP -> if (secondaryDown) releaseSecondary(now, px, py)
        }
        lastMouse = px to py
    }

    private var lastMouse = 0f to 0f

    private fun releaseSecondary(t: Long, px: Float, py: Float) {
        injectMouse(MotionEvent.ACTION_BUTTON_RELEASE, mouseDownTime, t, px, py, 0, MotionEvent.BUTTON_SECONDARY)
        injectMouse(MotionEvent.ACTION_UP, mouseDownTime, t, px, py, 0)
        secondaryDown = false
    }

    /** Ends hovering or a held right button, before a finger goes down. */
    private fun endMouse(t: Long) {
        val (px, py) = lastMouse
        if (secondaryDown) releaseSecondary(t, px, py)
        if (hovering) injectMouse(MotionEvent.ACTION_HOVER_EXIT, t, t, px, py, 0)
        hovering = false
    }

    /** A mouse wheel; h/v in notches (+ = right/up). */
    private fun scroll(scrollGen: Int, x: Float, y: Float, hScroll: Float, vScroll: Float) {
        if (scrollGen != gen || fingers.isNotEmpty() || secondaryDown) return
        if (!hScroll.isFinite() || !vScroll.isFinite()) return
        val now = SystemClock.uptimeMillis()
        val px = x.coerceIn(0f, 1f) * (w - 1)
        val py = y.coerceIn(0f, 1f) * (h - 1)
        injectMouse(MotionEvent.ACTION_SCROLL, now, now, px, py, 0, axes = hScroll.coerceIn(-50f, 50f) to vScroll.coerceIn(-50f, 50f))
        lastMouse = px to py
    }

    private val mouseProps = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE })

    private fun injectMouse(action: Int, down: Long, t: Long, px: Float, py: Float, buttons: Int, actionButton: Int = 0,
                            axes: Pair<Float, Float>? = null) {
        val coords = arrayOf(MotionEvent.PointerCoords().apply {
            x = px; y = py
            pressure = if (buttons != 0) 1f else 0f
            axes?.let { setAxisValue(MotionEvent.AXIS_HSCROLL, it.first); setAxisValue(MotionEvent.AXIS_VSCROLL, it.second) }
        })
        val event = MotionEvent.obtain(down, t, action, 1, mouseProps, coords, 0, buttons, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
        if (actionButton != 0 && !Hidden.setActionButton(event, actionButton)) { event.recycle(); return }
        val ok = runCatching { Hidden.inject(event, displayId) }.getOrDefault(false)
        event.recycle()
        if (!ok) Log.d("display session $id: injecting mouse action $action failed")
    }

    private fun nav(which: Int) {
        if (which == DisplayWire.NAV_HOME) { if (isHome) launchHome(toFront = true); return }
        val code = when (which) {
            DisplayWire.NAV_BACK -> KeyEvent.KEYCODE_BACK
            else -> return
        }
        val now = SystemClock.uptimeMillis()
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            Hidden.inject(KeyEvent(now, now, action, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                InputDevice.SOURCE_KEYBOARD), displayId)
        }
    }

    // MARK: - Closing

    /**
     * Ends the session. With [toPhone], the app moves back to the phone *under* whatever is showing
     * there, so it waits in Recents instead of popping up (releasing the display alone would put it
     * on top). Then the display and encoder go.
     */
    @Synchronized
    fun close(toPhone: Boolean, onTop: Boolean = false) {
        if (closed) return
        closed = true
        val onOurs = Hidden.rootTasks().filter { it.displayId == displayId }
        // Pause what's playing first: once the capture stops, the rest would come out of the
        // phone's speaker (measured: 0.6 s of it), and an app going back to the phone shouldn't
        // start making noise there.
        if (hasAudio && Media.pause(onOurs.mapNotNull { it.packageName }.toSet())) Thread.sleep(150)
        audio.stop()
        // The phone window's home screen ends with it (releasing the display would otherwise move
        // it onto the phone); its apps go back like any window's.
        if (isHome) onOurs.filter { it.taskId == homeTask || it.packageName == "dev.nearside" }.forEach { Hidden.removeTask(it.taskId) }
        val apps = if (isHome) onOurs.filter { it.taskId != homeTask && it.packageName != "dev.nearside" } else onOurs
        if (toPhone && apps.isNotEmpty()) matchPhone()
        if (toPhone) apps.forEach { Hidden.moveTask(it.taskId, 0, onTop = onTop) }
        runCatching { awake?.release() }
        runCatching { keyboard?.close() }
        touchscreen?.let { PhoneDevice.closeInput(it) }
        runCatching { display.release() }
        device?.close()
        codec?.let { runCatching { it.stop() }; it.release() }
        watcher.shutdownNow()
        ctl?.close()
        video?.close()
        server.ended(this)
        Log.d("display session $id: closed (${apps.size} app(s) back to the phone)")
    }

    val isClosed get() = closed
}
