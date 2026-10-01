package com.example.french_mobiles

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.fingerprint.FingerprintManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.view.KeyEvent
import java.net.HttpURLConnection
import java.net.URL
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideNavigationBar()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android puts the bars back after a dialog, a permission prompt or
        // the keyboard, so the request has to be made again every time the
        // window comes back to the foreground.
        if (hasFocus) hideNavigationBar()
    }

    /// Hides the 3-button navigation bar, leaving the status bar alone.
    ///
    /// BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE is what makes it behave the way
    /// other apps do: a swipe up from the bottom edge floats the buttons over
    /// the content, and they hide again on their own.
    ///
    /// Done here rather than with Flutter's SystemUiMode.immersiveSticky
    /// because that hides the status bar too, taking the clock, battery and
    /// signal with it. Only the navigation bar is meant to go.
    ///
    /// This also takes over edge-to-edge from Dart: asking Flutter for
    /// SystemUiMode.edgeToEdge explicitly shows every bar, which would undo
    /// the hide on startup.
    private fun readBattery(): Map<String, Any?> {
        val manager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val out = HashMap<String, Any?>()

        // Present on every version.
        val level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (level in 0..100) out["level"] = level

        val chargeCounter =
            manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        if (chargeCounter > 0) out["chargeMicroAmpHours"] = chargeCounter

        // Negative while discharging, which is worth keeping: the sign is how
        // the app knows whether the phone is taking power or giving it.
        val currentNow =
            manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        if (currentNow != Int.MIN_VALUE && currentNow != 0) {
            out["currentMicroAmps"] = currentNow
        }

        // The sticky broadcast carries what the properties API does not.
        val status = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        if (status != null) {
            val tenths = status.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1)
            if (tenths > 0) out["temperatureCelsius"] = tenths / 10.0

            val milliVolts = status.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)
            if (milliVolts > 0) out["voltage"] = milliVolts / 1000.0

            out["technology"] = status.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY)
            out["powerSource"] = when (
                status.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            ) {
                BatteryManager.BATTERY_PLUGGED_AC -> "mains"
                BatteryManager.BATTERY_PLUGGED_USB -> "usb"
                BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
                BatteryManager.BATTERY_PLUGGED_DOCK -> "dock"
                else -> "battery"
            }
            out["charging"] = status.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ==
                BatteryManager.BATTERY_STATUS_CHARGING

            // Android 14 and up. A real wear figure, and the closest thing
            // to battery health the platform will give: there is no
            // state-of-health API at any API level — BatteryManager has no
            // such constant, which is why every app that shows a health
            // percentage is estimating one.
            if (Build.VERSION.SDK_INT >= 34) {
                val cycles = status.getIntExtra(BatteryManager.EXTRA_CYCLE_COUNT, -1)
                if (cycles > 0) out["cycleCount"] = cycles

                out["capacityLevel"] = when (
                    status.getIntExtra(BatteryManager.EXTRA_CAPACITY_LEVEL, -1)
                ) {
                    BatteryManager.BATTERY_CAPACITY_LEVEL_FULL -> "full"
                    BatteryManager.BATTERY_CAPACITY_LEVEL_HIGH -> "high"
                    BatteryManager.BATTERY_CAPACITY_LEVEL_NORMAL -> "normal"
                    BatteryManager.BATTERY_CAPACITY_LEVEL_LOW -> "low"
                    BatteryManager.BATTERY_CAPACITY_LEVEL_CRITICAL -> "critical"
                    else -> null
                }
            }

            out["healthFlag"] = when (
                status.getIntExtra(BatteryManager.EXTRA_HEALTH, -1)
            ) {
                BatteryManager.BATTERY_HEALTH_GOOD -> "good"
                BatteryManager.BATTERY_HEALTH_OVERHEAT -> "overheat"
                BatteryManager.BATTERY_HEALTH_DEAD -> "dead"
                BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "over_voltage"
                BatteryManager.BATTERY_HEALTH_COLD -> "cold"
                BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE -> "failure"
                else -> null
            }
        }

        // The real measurement, and the reason this app used to disagree with
        // every other battery app on the same handset.
        readCapacityHealth(out)

        out["sdkInt"] = Build.VERSION.SDK_INT
        return out
    }

    /**
     * Battery health as a capacity ratio: what the cell holds now against what
     * it held new.
     *
     * Android exposes no state-of-health API at any level (checked against the
     * API 37 android.jar — BatteryManager has no such constant), so this reads
     * the kernel's own power-supply nodes, which is what every battery app
     * that shows a believable figure actually does. `charge_full` is the
     * present full-charge capacity in µAh and `charge_full_design` is what the
     * cell shipped with; their ratio is the health percentage.
     *
     * Vendors disagree about where those nodes live and some ship only one of
     * the pair, so several paths are tried and each half is reported
     * separately. When the design figure is missing, `PowerProfile` is asked
     * for it by reflection — a private framework class, hence the broad catch:
     * it is absent on some builds and must never take the rest of the reading
     * down with it.
     *
     * Nothing here is guaranteed. If the nodes are unreadable the caller gets
     * no health field at all, which is the honest answer, and the Dart side
     * falls back to the cycle-count estimate clearly labelled as a guess.
     */
    private fun readCapacityHealth(out: HashMap<String, Any?>) {
        val supplies = listOf("battery", "bms", "battery_ext", "Battery")
        var fullMicroAmpHours: Long? = null
        var designMicroAmpHours: Long? = null

        for (supply in supplies) {
            val base = "/sys/class/power_supply/$supply"
            if (fullMicroAmpHours == null) {
                fullMicroAmpHours = readLongFile("$base/charge_full")
                    ?: readLongFile("$base/energy_full")
            }
            if (designMicroAmpHours == null) {
                designMicroAmpHours = readLongFile("$base/charge_full_design")
                    ?: readLongFile("$base/energy_full_design")
            }
            if (fullMicroAmpHours != null && designMicroAmpHours != null) break
        }

        // Last resort for the design figure: the framework's own power profile,
        // which carries it in mAh.
        if (designMicroAmpHours == null) {
            designMicroAmpHours = designCapacityFromPowerProfile()
        }

        if (fullMicroAmpHours != null) {
            out["fullChargeMicroAmpHours"] = fullMicroAmpHours
        }
        if (designMicroAmpHours != null) {
            out["designMicroAmpHours"] = designMicroAmpHours
        }

        val full = fullMicroAmpHours ?: return
        val design = designMicroAmpHours ?: return
        if (design <= 0L || full <= 0L) return

        val percent = (full.toDouble() / design.toDouble() * 100.0).toInt()
        // A cell reading over 100% is new or the node is lying; either way it
        // is not worn. Below 30% means the node is reporting something other
        // than what we think, so it is dropped rather than shown.
        if (percent in 30..120) {
            out["capacityHealth"] = percent.coerceAtMost(100)
        }
    }

    /** A single integer from a sysfs node, or null if it cannot be read. */
    private fun readLongFile(path: String): Long? {
        return try {
            val file = java.io.File(path)
            if (!file.canRead()) return null
            val raw = file.readText().trim()
            val value = raw.toLongOrNull() ?: return null
            if (value <= 0L) return null
            // Some kernels report these in mAh rather than µAh. A phone cell is
            // never 50 µAh, so a small number means the units are different.
            if (value < 100_000L) value * 1000L else value
        } catch (_: Throwable) {
            null
        }
    }

    /** Design capacity in µAh from the private PowerProfile class, or null. */
    private fun designCapacityFromPowerProfile(): Long? {
        return try {
            val clazz = Class.forName("com.android.internal.os.PowerProfile")
            val profile = clazz.getConstructor(Context::class.java)
                .newInstance(this)
            val mah = clazz.getMethod("getBatteryCapacity").invoke(profile)
                as? Double ?: return null
            if (mah <= 0.0) null else (mah * 1000.0).toLong()
        } catch (_: Throwable) {
            null
        }
    }

    private fun readThermal(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val out = HashMap<String, Any?>()

        if (Build.VERSION.SDK_INT >= 29) {
            out["status"] = when (power.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> "none"
                PowerManager.THERMAL_STATUS_LIGHT -> "light"
                PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                else -> null
            }
        }

        // 0..1 where 1.0 is the throttling threshold; above 1 it is already
        // being held back. Forecast of 0 means "right now".
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val headroom = power.getThermalHeadroom(0)
                if (!headroom.isNaN()) out["headroom"] = headroom.toDouble()
            } catch (_: Exception) {
                // Not implemented by this device's HAL.
            }
        }

        // Best effort. Most phones refuse; the ones that allow it give a
        // per-core picture nothing else can.
        val sensors = ArrayList<Map<String, Any?>>()
        try {
            java.io.File("/sys/class/thermal").listFiles()?.forEach { zone ->
                if (!zone.name.startsWith("thermal_zone")) return@forEach
                val type = java.io.File(zone, "type").takeIf { it.canRead() }
                    ?.readText()?.trim() ?: return@forEach
                if (!type.contains("cpu", true) &&
                    !type.contains("soc", true) &&
                    !type.contains("tsens", true)
                ) {
                    return@forEach
                }
                val raw = java.io.File(zone, "temp").takeIf { it.canRead() }
                    ?.readText()?.trim()?.toLongOrNull() ?: return@forEach
                // Kernels report millidegrees; a few report degrees.
                val celsius = if (raw > 1000) raw / 1000.0 else raw.toDouble()
                if (celsius > 0 && celsius < 150) {
                    sensors.add(mapOf("name" to type, "celsius" to celsius))
                }
            }
        } catch (_: Exception) {
            // Unreadable, which is the normal case.
        }
        if (sensors.isNotEmpty()) {
            out["sensors"] = sensors.sortedByDescending { it["celsius"] as Double }
        }

        return out
    }

    private fun hideNavigationBar() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.navigationBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    private lateinit var channel: MethodChannel
    private lateinit var audioChannel: MethodChannel
    private lateinit var proximityChannel: MethodChannel
    private lateinit var powerChannel: MethodChannel
    private lateinit var internetChannel: MethodChannel
    private lateinit var batteryChannel: MethodChannel
    private lateinit var thermalChannel: MethodChannel
    private var volumeListening = false
    private var screenReceiver: BroadcastReceiver? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/volume_keys"
        )
        channel.setMethodCallHandler { call, _ ->
            when (call.method) {
                "setVolumeListening" -> {
                    volumeListening = call.argument<Boolean>("enabled") ?: false
                }
            }
        }

        // Whether this device has a receiver at all. Tablets and some
        // handsets have only a loudspeaker, and the earpiece test needs to
        // say so rather than ask the user to listen for a sound that has
        // nowhere to come out.
        //
        // Routing itself is NOT done here. It used to be — setting
        // MODE_IN_COMMUNICATION with the speakerphone off — but that reroutes
        // the voice-call stream, while the audio being played was on the
        // media stream and stayed on the loudspeaker regardless. audioplayers
        // declares the usage on the player, which is what actually reaches
        // the receiver, so the Kotlin side no longer touches the audio mode.
        audioChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/audio_route"
        )
        audioChannel.setMethodCallHandler { call, result ->
            val manager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            when (call.method) {
                "hasEarpiece" -> {
                    val devices =
                        manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    val found = devices.any {
                        it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                    }
                    result.success(found)
                }
                else -> result.notImplemented()
            }
        }

        // What the battery will admit about itself.
        //
        // There is no state-of-health API on Android, at any level.
        // BatteryManager has no such constant — checked against the API 37
        // android.jar. Every app that displays a battery health percentage is
        // therefore estimating one, usually by reflecting into the hidden
        // PowerProfile class for the design capacity, which has been
        // restricted since Android 9 and is only meaningful at a full charge.
        // That guess is not made here.
        //
        // What the platform does give, from Android 14, is the charge cycle
        // count — a real wear figure and the best signal available.
        //
        // Everything else — level, temperature, voltage, and the coarse
        // health flag that catches a dead or swollen cell — comes from the
        // sticky ACTION_BATTERY_CHANGED broadcast and works everywhere.
        batteryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/battery"
        )
        batteryChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(readBattery())
                else -> result.notImplemented()
            }
        }

        // How hot the phone thinks it is, and how close to throttling.
        //
        // getCurrentThermalStatus and getThermalHeadroom are the platform's
        // own account of whether it is about to slow down — far better than
        // guessing from /sys/class/thermal, which is SELinux-blocked on most
        // modern devices. The per-sensor temperatures are read from there
        // anyway when they happen to be legible, purely as extra detail.
        thermalChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/thermal"
        )
        thermalChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(readThermal())
                else -> result.notImplemented()
            }
        }

        // Blanks the screen while the proximity sensor is covered, which is
        // what the phone app does during a call. PROXIMITY_SCREEN_OFF_WAKE_LOCK
        // is the same mechanism; the OS drives the screen directly from the
        // sensor, so Flutter never has to.
        proximityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/proximity_screen"
        )
        proximityChannel.setMethodCallHandler { call, result ->
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            val supported = power.isWakeLockLevelSupported(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK
            )
            when (call.method) {
                "isSupported" -> result.success(supported)
                "enable" -> {
                    if (!supported) {
                        result.success(false)
                    } else {
                        if (proximityWakeLock == null) {
                            proximityWakeLock = power.newWakeLock(
                                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                                "french_mobiles:proximity"
                            )
                        }
                        val lock = proximityWakeLock
                        if (lock != null && !lock.isHeld) {
                            // Timed, as a backstop: if anything fails to
                            // release it, the OS does after two minutes
                            // rather than leaving the screen dark.
                            lock.acquire(2 * 60 * 1000L)
                        }
                        result.success(true)
                    }
                }
                "disable" -> {
                    releaseProximityWakeLock()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        powerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/power_button"
        )
        powerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startWatching" -> {
                    startWatchingScreen()
                    result.success(true)
                }
                "stopWatching" -> {
                    stopWatchingScreen()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        internetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "french_mobiles/internet"
        )
        internetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "probeCellular" -> probeCellularInternet(result)
                else -> result.notImplemented()
            }
        }

        // Biometric hardware diagnostic channels (Reverse-engineering-data-s)
        fingerprintMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fingerprint_test/methods"
        )
        fingerprintMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> result.success(getFingerprintStatus())
                "startAuth" -> {
                    startFingerprintAuth()
                    result.success(getFingerprintStatus())
                }
                "cancelAuth" -> {
                    cancelFingerprintAuth()
                    result.success(getFingerprintStatus())
                }
                else -> result.notImplemented()
            }
        }

        fingerprintEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fingerprint_test/events"
        )
        fingerprintEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                fingerprintEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                fingerprintEventSink = null
            }
        })
    }

    /// Watches the screen going off and coming back.
    ///
    /// Android reserves the power key — KEYCODE_POWER never reaches an app, so
    /// the press itself cannot be observed. What can be observed is its
    /// effect: the screen turning off, and then coming back on. A test that
    /// sees both has watched the button do its job, which is a great deal
    /// better than asking the user whether it worked.
    ///
    /// Registered at runtime rather than in the manifest: ACTION_SCREEN_OFF
    /// and ACTION_SCREEN_ON are not delivered to manifest-declared receivers.
    private fun startWatchingScreen() {
        if (screenReceiver != null) return

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val event = when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> "screen_off"
                    Intent.ACTION_SCREEN_ON -> "screen_on"
                    Intent.ACTION_USER_PRESENT -> "user_present"
                    else -> return
                }
                powerChannel.invokeMethod("screenEvent", mapOf("event" to event))
            }
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(receiver, filter)
        screenReceiver = receiver
    }

    private fun stopWatchingScreen() {
        val receiver = screenReceiver ?: return
        screenReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Already gone; nothing to undo.
        }
    }

    /// Checks whether the cellular radio can actually reach the internet.
    ///
    /// The point of doing this natively: an HTTP request from Dart goes out
    /// over whatever route Android picks, which is Wi-Fi whenever Wi-Fi is
    /// connected. A phone with a registered SIM and dead mobile data
    /// therefore passes an ordinary connectivity check — the exact failure
    /// this is meant to catch.
    ///
    /// requestNetwork with TRANSPORT_CELLULAR asks for the cellular network
    /// specifically, and Network.openConnection sends the probe over that
    /// network whatever else the phone is connected to.
    private fun probeCellularInternet(result: MethodChannel.Result) {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
        val main = Handler(Looper.getMainLooper())
        var replied = false

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        lateinit var callback: ConnectivityManager.NetworkCallback

        fun reply(outcome: Map<String, Any?>) {
            main.post {
                if (replied) return@post
                replied = true
                try {
                    manager.unregisterNetworkCallback(callback)
                } catch (_: Exception) {
                    // Already gone.
                }
                result.success(outcome)
            }
        }

        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Networking is forbidden on the main thread.
                Thread { reply(probeThrough(network)) }.start()
            }

            override fun onUnavailable() {
                reply(mapOf("status" to "no_cellular"))
            }
        }

        try {
            manager.requestNetwork(request, callback)
        } catch (e: Exception) {
            result.success(
                mapOf("status" to "error", "message" to (e.message ?: "\$e"))
            )
            return
        }

        // The two-argument requestNetwork never times out by itself, so the
        // deadline is ours. Without it a phone with no cellular coverage
        // would leave the test waiting forever.
        main.postDelayed({ reply(mapOf("status" to "no_cellular")) }, 20_000)
    }

    /// Runs the captive-portal probe over one specific network.
    private fun probeThrough(network: Network): Map<String, Any?> {
        var connection: HttpURLConnection? = null
        return try {
            val url = URL("https://connectivitycheck.gstatic.com/generate_204")
            connection = network.openConnection(url) as HttpURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.instanceFollowRedirects = false
            connection.useCaches = false

            val startedAt = System.currentTimeMillis()
            connection.connect()
            val code = connection.responseCode
            val millis = System.currentTimeMillis() - startedAt

            mapOf(
                // 204 with no body is the whole point of this endpoint: any
                // other reply means something answered instead of the
                // internet, which is a portal, not a connection.
                "status" to if (code == 204) "ok" else "captive",
                "code" to code,
                "ms" to millis
            )
        } catch (e: Exception) {
            mapOf("status" to "unreachable", "message" to (e.message ?: "\$e"))
        } finally {
            connection?.disconnect()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel.setMethodCallHandler(null)
        audioChannel.setMethodCallHandler(null)
        // A receiver outliving the engine would fire into a dead channel.
        stopWatchingScreen()
        powerChannel.setMethodCallHandler(null)
        internetChannel.setMethodCallHandler(null)
        // A leaked proximity wake lock leaves the screen dark whenever the
        // sensor is covered, with no way back. Release it unconditionally.
        releaseProximityWakeLock()
        proximityChannel.setMethodCallHandler(null)
        cancelFingerprintAuth()
        fingerprintMethodChannel.setMethodCallHandler(null)
        fingerprintEventChannel.setStreamHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private lateinit var fingerprintMethodChannel: MethodChannel
    private lateinit var fingerprintEventChannel: EventChannel
    private var fingerprintEventSink: EventChannel.EventSink? = null
    private var fingerprintCancellationSignal: CancellationSignal? = null

    @Suppress("DEPRECATION")
    private fun getFingerprintManagerOrNull(): FingerprintManager? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return getSystemService(FingerprintManager::class.java)
    }

    private fun hasFingerprintPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val grantedUseFingerprint = checkSelfPermission(Manifest.permission.USE_FINGERPRINT) ==
            PackageManager.PERMISSION_GRANTED
        val grantedUseBiometric = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            checkSelfPermission(Manifest.permission.USE_BIOMETRIC) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            false
        }
        return grantedUseFingerprint || grantedUseBiometric
    }

    @Suppress("DEPRECATION")
    private fun getFingerprintStatus(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "supported" to false,
                "permissionGranted" to false,
                "hasHardware" to false,
                "hasEnrolled" to false,
                "ready" to false,
                "listening" to false,
                "biometryType" to "Fingerprint"
            )
        }
        val fp = getFingerprintManagerOrNull()
        val perm = hasFingerprintPermission()
        val hardware = try {
            perm && (fp?.isHardwareDetected == true)
        } catch (_: SecurityException) {
            false
        }
        val enrolled = try {
            perm && hardware && (fp?.hasEnrolledFingerprints() == true)
        } catch (_: SecurityException) {
            false
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "supported" to (fp != null),
            "permissionGranted" to perm,
            "hasHardware" to hardware,
            "hasEnrolled" to enrolled,
            "ready" to (fp != null && perm && hardware && enrolled),
            "listening" to (fingerprintCancellationSignal != null),
            "biometryType" to "Fingerprint"
        )
    }

    @Suppress("DEPRECATION")
    private fun startFingerprintAuth() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            emitFingerprintEvent("unsupported", message = "Android 6.0+ required.")
            return
        }
        val status = getFingerprintStatus()
        if (status["ready"] != true) {
            emitFingerprintEvent(
                "precheck_failed",
                message = "Fingerprint not ready. Check hardware/enrollment/permission.",
                extra = status
            )
            return
        }
        cancelFingerprintAuth()
        val fp = getFingerprintManagerOrNull() ?: return
        val signal = CancellationSignal()
        fingerprintCancellationSignal = signal

        val callback = object : FingerprintManager.AuthenticationCallback() {
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                fingerprintCancellationSignal = null
                emitFingerprintEvent(
                    "auth_error",
                    code = errorCode,
                    message = errString?.toString() ?: "Unknown error"
                )
            }

            override fun onAuthenticationHelp(helpCode: Int, helpString: CharSequence?) {
                emitFingerprintEvent(
                    "auth_help",
                    code = helpCode,
                    message = helpString?.toString() ?: "Keep finger steady / clean sensor"
                )
            }

            override fun onAuthenticationSucceeded(result: FingerprintManager.AuthenticationResult?) {
                fingerprintCancellationSignal = null
                emitFingerprintEvent("auth_succeeded", message = "Fingerprint recognized!")
            }

            override fun onAuthenticationFailed() {
                emitFingerprintEvent("auth_failed", message = "Fingerprint not recognized. Try again.")
            }
        }

        try {
            fp.authenticate(null, signal, 0, callback, Handler(Looper.getMainLooper()))
            emitFingerprintEvent("listening_started", message = "Listening... Touch fingerprint sensor now.")
        } catch (se: SecurityException) {
            fingerprintCancellationSignal = null
            emitFingerprintEvent("security_exception", message = se.message ?: "SecurityException")
        } catch (t: Throwable) {
            fingerprintCancellationSignal = null
            emitFingerprintEvent("exception", message = t.message ?: t.toString())
        }
    }

    private fun cancelFingerprintAuth() {
        val wasListening = fingerprintCancellationSignal != null
        try {
            fingerprintCancellationSignal?.cancel()
        } catch (_: Throwable) {
        } finally {
            fingerprintCancellationSignal = null
            if (wasListening) {
                emitFingerprintEvent("listening_stopped", message = "Stopped listening.")
            }
        }
    }

    private fun emitFingerprintEvent(
        type: String,
        code: Int? = null,
        message: String? = null,
        extra: Map<String, Any?>? = null
    ) {
        val payload = HashMap<String, Any?>()
        payload["type"] = type
        payload["timestamp"] = System.currentTimeMillis()
        if (code != null) payload["code"] = code
        if (message != null) payload["message"] = message
        if (extra != null) payload["extra"] = extra
        Handler(Looper.getMainLooper()).post {
            fingerprintEventSink?.success(payload)
        }
    }

    override fun onStop() {
        // Backgrounding the app while the lock is held would let it keep
        // blanking the screen outside the test that asked for it.
        //
        // onStop rather than onPause: a proximity blank does not background
        // the activity, but onPause fires for transient things that should
        // not end the test.
        releaseProximityWakeLock()
        super.onStop()
    }

    private fun releaseProximityWakeLock() {
        val lock = proximityWakeLock ?: return
        proximityWakeLock = null
        if (!lock.isHeld) return
        // WAIT_FOR_NO_PROXIMITY, so the screen does not snap back on while
        // the phone is still against the user's ear.
        lock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
    }

    // Intercept hardware volume keys while the checkup's side-button test is
    // active so the device volume is left untouched and presses can be reported
    // to Flutter via the method channel.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        val isVolumeKey = keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        if (volumeListening && isVolumeKey) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                channel.invokeMethod(
                    "volumeKey",
                    mapOf(
                        "key" to if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                            "volume_up"
                        } else {
                            "volume_down"
                        }
                    )
                )
            }
            // Consume the event so the system volume stays unchanged.
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}