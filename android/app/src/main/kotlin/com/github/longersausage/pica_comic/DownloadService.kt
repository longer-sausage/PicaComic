package com.github.longersausage.pica_comic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/** Protects the existing Dart download workers; never restarts without them. */
class DownloadService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var ready = false
    private var title = "下载中"
    private var content = "Pica Comic"
    private var progress = 0L
    private var total = 0L
    private var progressScheduled = false
    private var timeoutPending = false

    private val renewWakeLock = object : Runnable {
        override fun run() {
            // The timeout is a safeguard; keep renewing it for long downloads.
            wakeLock?.acquire(WAKE_LOCK_TIMEOUT)
            handler.postDelayed(this, WAKE_LOCK_TIMEOUT / 2)
        }
    }
    private val publishProgress = Runnable {
        progressScheduled = false
        if (ready) {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification())
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "下载漫画", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        title = intent?.getStringExtra("title") ?: title
        content = intent?.getStringExtra("content") ?: content
        try {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
            )
            if (!ready) acquireLocks()
            ready = true
            finishStarts(null)
        } catch (e: RuntimeException) {
            Log.e(TAG, "Unable to protect background downloads", e)
            finishStarts(e)
            releaseLocks()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:downloads")
            .apply { setReferenceCounted(false) }
        renewWakeLock.run()
        // HIGH_PERF also works with the screen off on older Android versions.
        // Android 14+ maps it to LOW_LATENCY and controls when it is effective.
        // The foreground service and CPU lock remain necessary on those devices.
        try {
            wifiLock = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$packageName:downloads")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        } catch (e: RuntimeException) {
            Log.w(TAG, "Wi-Fi performance lock unavailable", e)
        }
    }

    private fun releaseLocks() {
        ready = false
        handler.removeCallbacksAndMessages(null)
        progressScheduled = false
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun notification(): Notification {
        val openApp = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openApp, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.notification)
            .setContentTitle(title)
            .setContentText(content)
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setProgress(1000, if (total > 0) (progress.toDouble() / total * 1000)
                .toInt().coerceIn(0, 1000) else 0, total <= 0)
            .build()
    }

    private fun update(title: String, content: String, progress: Long, total: Long) {
        this.title = title
        this.content = content
        this.progress = progress
        this.total = total
        // Coalesce page completions instead of flooding the system and Dart UI.
        if (!progressScheduled) {
            progressScheduled = true
            handler.postDelayed(publishProgress, 1000)
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15+ limits background dataSync services. Stop promptly and let
        // Dart persist/pause the queue until the user returns to the app.
        timeoutPending = true
        handler.postDelayed({ stopTimedOutService() }, 1000)
        val expired = onExpired
        if (expired == null) stopTimedOutService()
        else expired { stopTimedOutService() }
    }

    private fun stopTimedOutService() {
        if (!timeoutPending) return
        timeoutPending = false
        releaseLocks()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        timeoutPending = false
        releaseLocks()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        instance = null
        finishStarts(IllegalStateException("Download service stopped before starting"))
        val callbacks = stopCallbacks.toList()
        stopCallbacks.clear()
        callbacks.forEach { it() }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "PicaComicDownloads"
        private const val CHANNEL_ID = "download"
        private const val NOTIFICATION_ID = 72382
        private const val WAKE_LOCK_TIMEOUT = 10 * 60 * 1000L
        private var instance: DownloadService? = null
        private val startCallbacks = mutableListOf<(RuntimeException?) -> Unit>()
        private val stopCallbacks = mutableListOf<() -> Unit>()
        var onExpired: ((() -> Unit) -> Unit)? = null

        fun start(context: Context, title: String, content: String,
                  onStarted: (RuntimeException?) -> Unit) {
            if (instance?.ready == true) {
                onStarted(null)
                return
            }
            startCallbacks.add(onStarted)
            try {
                ContextCompat.startForegroundService(
                    context, Intent(context, DownloadService::class.java)
                        .putExtra("title", title).putExtra("content", content)
                )
            } catch (e: RuntimeException) {
                startCallbacks.remove(onStarted)
                onStarted(e)
            }
        }

        fun stop(context: Context, onStopped: () -> Unit = {}) {
            stopCallbacks.add(onStopped)
            if (!context.stopService(Intent(context, DownloadService::class.java))) {
                val callbacks = stopCallbacks.toList()
                stopCallbacks.clear()
                callbacks.forEach { it() }
            }
        }

        fun updateProgress(title: String, content: String, progress: Long, total: Long) {
            instance?.update(title, content, progress, total)
        }

        private fun finishStarts(error: RuntimeException?) {
            val callbacks = startCallbacks.toList()
            startCallbacks.clear()
            callbacks.forEach { it(error) }
        }
    }
}
