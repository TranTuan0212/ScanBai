package com.cardlink.service

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.cardlink.MainActivity
import com.cardlink.R
import com.cardlink.camera.CameraXManager
import com.cardlink.ml.CardSlowMoSlicer
import com.cardlink.network.HeartbeatRequest
import com.cardlink.network.RetrofitClient
import com.cardlink.network.SocketManager
import com.cardlink.utils.SharedPrefs
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Pure Live Broadcaster Service with Slow-Motion Card Deal Slicer
 * 1. Streams low-latency live camera video to viewers (live_frame)
 * 2. CardSlowMoSlicer: Tracks white card presence, buffers deal clips, extracts #1 sharpest frame
 * 3. Round-Robin Deal Counter: Counts N tụ x 3 cards and auto-cycles rounds
 */
@AndroidEntryPoint
class LiveForegroundService : LifecycleService() {

    @Inject lateinit var sharedPrefs: SharedPrefs
    @Inject lateinit var socketManager: SocketManager

    private var cameraXManager: CameraXManager? = null
    private var cardSlicer: CardSlowMoSlicer? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private var heartbeatJob: Job? = null
    private var currentSessionId: String? = null
    private var latestBitmap: Bitmap? = null
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): LiveForegroundService = this@LiveForegroundService
    }

    override fun onBind(intent: Intent): IBinder {
        super.onBind(intent)
        return binder
    }

    override fun onCreate() {
        super.onCreate()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        val action = intent?.action
        val sessionId = intent?.getStringExtra(EXTRA_SESSION_ID)
        val rounds = intent?.getIntExtra(EXTRA_ROUNDS, 3) ?: 3

        if (action == ACTION_START_LIVE && sessionId != null) {
            currentSessionId = sessionId
            startForeground(NOTIFICATION_ID, buildNotification())
            initPipeline(sessionId, rounds)
            startHeartbeat(sessionId)
        } else if (action == ACTION_STOP_LIVE) {
            stopLiveSession()
        }

        return START_NOT_STICKY
    }

    private fun initPipeline(sessionId: String, rounds: Int) {
        // Initialize Socket.IO connection
        socketManager.connect()
        socketManager.joinRoom(sessionId)

        // Initialize Capcut-style Slow-Motion Card Slicer
        cardSlicer = CardSlowMoSlicer(totalRounds = rounds) { slotNumber, roundIdx, cardIdx, isRoundComplete, imageBase64 ->
            Log.d("LiveService", "🎬 [CARD EXTRACTED] Slot #$slotNumber (Tụ $roundIdx - Lá $cardIdx) | RoundComplete=$isRoundComplete")
            socketManager.sendCardDetected(sessionId, "Lá $slotNumber", imageBase64)
        }

        // Initialize CameraX bound to THIS Service LifecycleOwner
        cameraXManager = CameraXManager(this).apply {
            initialize(this@LiveForegroundService) { bitmap ->
                latestBitmap = bitmap

                currentSessionId?.let { sId ->
                    streamLiveFrameIfDue(bitmap, sId)
                }

                // Process continuous frames through slow-motion card slicer
                cardSlicer?.processFrame(bitmap)
            }
        }
    }

    private var lastLiveFrameStreamTime = 0L

    private fun streamLiveFrameIfDue(bitmap: Bitmap, sessionId: String) {
        val now = System.currentTimeMillis()
        if (now - lastLiveFrameStreamTime >= 120L) { // ~8-9 FPS
            lastLiveFrameStreamTime = now
            try {
                val scaled = Bitmap.createScaledBitmap(bitmap, 320, 240, true)
                val out = java.io.ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 55, out)
                val base64 = android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
                val dataUri = "data:image/jpeg;base64,$base64"
                socketManager.sendLiveFrame(sessionId, dataUri)
            } catch (e: Exception) {
                Log.w("LiveService", "Failed to stream live frame: ${e.message}")
            }
        }
    }

    fun getCameraXManager(): CameraXManager? = cameraXManager

    fun switchCamera() {
        cameraXManager?.switchCamera()
    }

    fun toggleTorch(): Boolean {
        return cameraXManager?.toggleTorch() ?: false
    }

    /**
     * Instantly capture the real camera frame and send as next dealt card photo
     */
    fun captureCurrentFrameAsCard() {
        val bmp = latestBitmap ?: return
        cardSlicer?.manualCapture(bmp)
    }

    private fun startHeartbeat(sessionId: String) {
        heartbeatJob?.cancel()
        heartbeatJob = lifecycleScope.launch {
            val apiService = RetrofitClient.create(sharedPrefs)
            while (isActive) {
                delay(5000L)
                try {
                    val response = apiService.heartbeat(HeartbeatRequest(sessionId))
                    if (!response.isSuccessful) {
                        Log.e("LiveService", "Heartbeat failed with code: ${response.code()}")
                        if (response.code() == 403 || response.code() == 404) {
                            Log.w("LiveService", "Account expired or session ended -> Stopping live service")
                            stopLiveSession()
                            break
                        }
                    } else {
                        Log.d("LiveService", "Heartbeat renewed successfully for session: $sessionId")
                    }
                } catch (e: Exception) {
                    Log.e("LiveService", "Heartbeat network error", e)
                }
            }
        }
    }

    fun stopLiveSession() {
        heartbeatJob?.cancel()
        currentSessionId?.let { sessionId ->
            socketManager.leaveRoom(sessionId)
        }
        cameraXManager?.shutdown()
        cardSlicer?.reset()

        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = powerManager?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CardLink:LiveWakeLock")
            wakeLock?.acquire(4 * 60 * 60 * 1000L) // 4 hours max

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifiManager?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "CardLink:LiveWifiLock")
            wifiLock?.acquire()
        } catch (e: Exception) {
            Log.e("LiveService", "Error acquiring locks", e)
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (e: Exception) {
            Log.e("LiveService", "Error releasing locks", e)
        }
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, "cardlink_live_channel")
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(getString(R.string.notification_text))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopLiveSession()
    }

    companion object {
        const val ACTION_START_LIVE = "com.cardlink.action.START_LIVE"
        const val ACTION_STOP_LIVE = "com.cardlink.action.STOP_LIVE"
        const val EXTRA_SESSION_ID = "extra_session_id"
        const val EXTRA_ROUNDS = "extra_rounds"
        private const val NOTIFICATION_ID = 1001
    }
}
