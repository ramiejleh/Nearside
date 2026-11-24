// The phone's camera for the Mac (a webcam): one "camera" stream on the display socket, with the
// same single-use tickets and proofs as a window's streams. The camera is open exactly as long as
// the stream is; Android shows its camera-in-use indicator meanwhile.
//   Mac → CAMERA_OPEN: u8 facing (0 back, 1 front), u16 width, u16 height, u8 fps
//   us  → CAMERA_INFO: u16 rotation (degrees clockwise to turn the picture upright, for how the
//         phone is held now: sent again when that changes), u8 facing; then CONFIG / FRAME as a
//         window's video (HEVC)
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@SuppressLint("MissingPermission") // the shell holds CAMERA
object CameraStream {
    private const val KBPS = 8_000

    private val open = HashSet<DisplayWire.Conn>() // under its own lock
    /** The camera turned on (true) or off: the phone's in-use notification says so. Set by Main. */
    var onChanged: (Boolean) -> Unit = {}
    val isOn get() = synchronized(open) { open.isNotEmpty() }

    /** [canStart]: the phone can show that the camera is in use (the app is linked). */
    /** After the phone's Stop, no camera for a while, whatever a Mac asks (uptime ms). */
    @Volatile private var refusedUntil = 0L

    fun attach(conn: DisplayWire.Conn, canStart: Boolean) {
        if (!canStart) { Log.d("camera: refused, the phone app isn't running to show it"); return conn.close() }
        // Checked and registered together (Stop takes the same lock), so a Stop racing this still wins.
        val first = synchronized(open) {
            if (android.os.SystemClock.uptimeMillis() < refusedUntil) null else { open.add(conn); open.size == 1 }
        } ?: run { Log.d("camera: refused, stopped on the phone"); return conn.close() }
        if (first) onChanged(true)
        Thread({
            try { run(conn) } catch (e: Exception) { Log.d("camera: failed: $e"); conn.close() } finally {
                val last = synchronized(open) { open.remove(conn); open.isEmpty() }
                if (last) onChanged(false)
            }
        }, "camera").start()
    }

    /** The Mac that opened it went, or another took the phone: the camera turns off. */
    fun stopAll() = synchronized(open) { open.toList() }.forEach { it.close() }

    /** The phone's Stop: off, and refused for 30 s (the Mac waits for the app to start it anew). */
    fun stoppedOnPhone() = synchronized(open) {
        refusedUntil = android.os.SystemClock.uptimeMillis() + 30_000
        open.toList()
    }.forEach { it.close() }

    private val manager: CameraManager by lazy {
        CameraManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
            .newInstance(FakeContext.instance)
    }

    private fun run(conn: DisplayWire.Conn) {
        conn.setTimeout(5000)
        val (type, body) = conn.read(64) ?: return conn.close()
        if (type != DisplayWire.CAMERA_OPEN || body.size < 6) return conn.close()
        val b = ByteBuffer.wrap(body)
        val front = b.get().toInt() == 1
        val wantW = b.short.toInt() and 0xffff
        val wantH = b.short.toInt() and 0xffff
        val fps = (b.get().toInt() and 0xff).coerceIn(5, 60)
        conn.setTimeout(0)

        val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
            ?: return conn.close().also { Log.d("camera: no ${if (front) "front" else "back"} camera") }
        val chars = manager.getCameraCharacteristics(id)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        val size = pickSize(map.getOutputSizes(MediaCodec::class.java)?.toList().orEmpty(), wantW, wantH)
        val range = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES).orEmpty()
            .filter { it.upper == fps }.minByOrNull { it.lower } ?: Range(fps, fps)
        val sensor = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        codec.configure(MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, KBPS * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 2f) // a webcam has no "catch up": regular keyframes
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 1)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
        }, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        val thread = HandlerThread("camera-callbacks").apply { start() }
        val handler = Handler(thread.looper)
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var tilt: Tilt? = null
        try {
            device = open(id, handler) ?: return Log.d("camera: $id didn't open")
            session = capture(device, surface, range, handler) ?: return Log.d("camera: $id session failed")
            tilt = Tilt(handler) { held ->
                // Android's rule for turning a camera picture upright (as for a photo's EXIF).
                val rotation = if (front) (sensor - held + 360) % 360 else (sensor + held) % 360
                conn.send(DisplayWire.CAMERA_INFO, ByteBuffer.allocate(3).putShort(rotation.toShort()).put(if (front) 1 else 0).array())
                Log.d("camera: held at $held°, picture turned $rotation°")
            }
            tilt?.start()
            Log.d("camera: $id (${if (front) "front" else "back"}) ${size.width}x${size.height} @ $range fps, sensor at $sensor°")
            // The Mac pings every 5 s: 15 s of silence means it vanished (asleep, off the network),
            // and the camera turns off rather than waiting for the link to notice.
            conn.setTimeout(15_000)
            Thread({ while (!conn.isClosed && conn.read(1024) != null) {}; conn.close() }, "camera-reader").start()
            encode(conn, codec, size)
        } finally {
            tilt?.stop()
            runCatching { session?.close() }
            runCatching { device?.close() }
            runCatching { codec.stop() }; codec.release()
            surface.release()
            thread.quitSafely()
            conn.close()
            Log.d("camera: closed")
        }
    }

    /** The largest size the encoder takes that fits in the request, in its shape first. */
    private fun pickSize(sizes: List<Size>, w: Int, h: Int): Size {
        val fits = sizes.filter { it.width <= w && it.height <= h }
        return fits.filter { it.width.toLong() * h == it.height.toLong() * w }.maxByOrNull { it.width * it.height }
            ?: fits.maxByOrNull { it.width * it.height } ?: sizes.minByOrNull { it.width * it.height }!!
    }

    private fun open(id: String, handler: Handler): CameraDevice? {
        val latch = CountDownLatch(1)
        var opened: CameraDevice? = null
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) { opened = camera; latch.countDown() }
            override fun onDisconnected(camera: CameraDevice) { camera.close(); latch.countDown() }
            override fun onError(camera: CameraDevice, error: Int) { Log.d("camera: error $error"); camera.close(); latch.countDown() }
        }, handler)
        latch.await(5, TimeUnit.SECONDS)
        return opened
    }

    @Suppress("DEPRECATION") // the SessionConfiguration form needs an executor and changes nothing here
    private fun capture(device: CameraDevice, surface: Surface, fps: Range<Int>, handler: Handler): CameraCaptureSession? {
        val latch = CountDownLatch(1)
        var configured: CameraCaptureSession? = null
        device.createCaptureSession(listOf(surface), object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) { configured = s; latch.countDown() }
            override fun onConfigureFailed(s: CameraCaptureSession) { latch.countDown() }
        }, handler)
        latch.await(5, TimeUnit.SECONDS)
        val s = configured ?: return null
        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
            addTarget(surface)
            set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fps)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        }.build()
        s.setRepeatingRequest(request, null, handler)
        return s
    }

    private fun encode(conn: DisplayWire.Conn, codec: MediaCodec, size: Size) {
        val info = MediaCodec.BufferInfo()
        val header = ByteBuffer.allocate(21)
        var data = ByteArray(0)
        while (!conn.isClosed) {
            val index = codec.dequeueOutputBuffer(info, 100_000)
            if (index < 0) continue
            val n = try {
                val buf = codec.getOutputBuffer(index) ?: continue
                buf.position(info.offset).limit(info.offset + info.size)
                if (data.size < buf.remaining()) data = ByteArray(buf.remaining() * 5 / 4)
                buf.remaining().also { buf.get(data, 0, it) }
            } finally {
                codec.releaseOutputBuffer(index, false)
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                conn.send(DisplayWire.CONFIG, ByteBuffer.allocate(8 + n).putInt(1).putShort(size.width.toShort())
                    .putShort(size.height.toShort()).put(data, 0, n).array())
                continue
            }
            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            header.clear()
            header.putInt(1).putLong(info.presentationTimeUs).putLong(System.nanoTime() / 1000).put(if (key) 1 else 0)
            conn.sendFrame(DisplayWire.FRAME, header.array(), data, n)
        }
    }
}

/**
 * How the phone is held, from its accelerometer, in OrientationEventListener's degrees (0 upright,
 * 90 turned clockwise, …), snapped to quarters with some leeway so it doesn't flicker between
 * them. Only while the camera is on.
 */
private class Tilt(private val handler: android.os.Handler, private val onChange: (Int) -> Unit) :
    android.hardware.SensorEventListener {
    private val sensors = FakeContext.instance.getSystemService(android.hardware.SensorManager::class.java)
    private var held = -1

    fun start() {
        val accelerometer = sensors?.getDefaultSensor(android.hardware.Sensor.TYPE_ACCELEROMETER)
        if (accelerometer == null) { Log.d("camera: no accelerometer; assuming landscape"); onChange(270); return }
        onChange(0) // until the first reading
        held = 0
        sensors.registerListener(this, accelerometer, android.hardware.SensorManager.SENSOR_DELAY_UI, handler)
    }

    fun stop() {
        runCatching { sensors?.unregisterListener(this) }
    }

    override fun onSensorChanged(event: android.hardware.SensorEvent) {
        val x = -event.values[0]
        val y = -event.values[1]
        val z = event.values[2]
        if (x * x + y * y < z * z / 3) return // lying flat: keep what we had
        val angle = Math.toDegrees(kotlin.math.atan2(-y.toDouble(), x.toDouble()))
        val degrees = ((90 - Math.round(angle).toInt()) % 360 + 360) % 360
        val quarter = ((degrees + 45) / 90 % 4) * 90
        // Leeway: only once clearly there (within 30° of it), so it doesn't flicker in between.
        val apart = kotlin.math.abs(degrees - quarter).let { minOf(it, 360 - it) }
        if (quarter != held && apart <= 30) {
            held = quarter
            onChange(quarter)
        }
    }

    override fun onAccuracyChanged(sensor: android.hardware.Sensor?, accuracy: Int) {}
}
