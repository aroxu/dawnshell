package me.aroxu.dawnshell;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Direct-Boot-aware, crash-isolated Android process for MediaCodec access.
 *
 * The first implementation intentionally exposes only the hardware capability
 * probe. The process boundary and lifecycle are the foundation for the local
 * Debian codec protocol without coupling a vendor codec crash to PID 1 or SSH.
 */
public final class HardwareCodecService extends Service {

    private static final String TAG = "DawnShellCodec";
    private static final String ACTION_BOOT =
            "me.aroxu.dawnshell.action.START_HARDWARE_CODEC_BRIDGE";
    private static final String ACTION_PROBE =
            "me.aroxu.dawnshell.action.PROBE_HARDWARE_CODECS";
    private static final String CHANNEL_ID = "dawnshell_hardware_codec";
    private static final int NOTIFICATION_ID = 2223;
    private static final long[] BOOT_RETRY_DELAYS_MS = {
            0L, 2_000L, 5_000L, 10_000L, 20_000L, 30_000L
    };

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean probeRunning = new AtomicBoolean(false);
    private HardwareCodecBroker broker;

    static void ensureStarted(Context context, boolean bootRetry) {
        Intent intent = new Intent(context, HardwareCodecService.class)
                .setAction(bootRetry ? ACTION_BOOT : ACTION_PROBE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, HardwareCodecService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_BOOT : intent.getAction();
        // Explicit intents can only originate inside this non-exported app. Trust
        // them so a long-lived :codec process cannot observe stale multi-process
        // SharedPreferences after the UI commits a newly enabled setting.
        if (intent == null && (!BfuPreferences.isEnabled(this)
                || !BfuPreferences.hardwareCodecBridge(this))) {
            Log.i(TAG, "Hardware codec service stopped because the opt-in is disabled");
            stopSelf();
            return START_NOT_STICKY;
        }
        try {
            ensureBrokerStarted();
        } catch (IOException e) {
            Log.e(TAG, "Could not start hardware codec local broker", e);
            HardwareCodecProbe.recordBrokerEvent(this,
                    "START_FAILED error=" + BfuSu.sanitize(e.getMessage()));
        }
        boolean retry = ACTION_BOOT.equals(action);
        if (probeRunning.compareAndSet(false, true)) {
            executor.execute(() -> runProbe(retry));
        } else {
            Log.i(TAG, "MediaCodec probe already running; duplicate request ignored");
        }
        return START_STICKY;
    }

    private void runProbe(boolean retry) {
        try {
            int attempts = retry ? BOOT_RETRY_DELAYS_MS.length : 1;
            for (int index = 0; index < attempts; index++) {
                long delay = retry ? BOOT_RETRY_DELAYS_MS[index] : 0L;
                if (delay > 0L) Thread.sleep(delay);
                HardwareCodecProbe.Result result = HardwareCodecProbe.run(this,
                        retry ? "locked_boot_attempt_" + (index + 1) : "manual");
                if (result.passed) {
                    Log.i(TAG, "Hardware MediaCodec probe passed: " + result.summary);
                    return;
                }
                if (index + 1 < attempts) {
                    Log.w(TAG, "Hardware MediaCodec unavailable; retrying after boot: "
                            + result.summary);
                }
            }
            Log.w(TAG, "Hardware MediaCodec remained unavailable; Debian is unaffected");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.i(TAG, "Hardware MediaCodec probe interrupted");
        } finally {
            probeRunning.set(false);
        }
    }

    @Override
    public void onDestroy() {
        synchronized (this) {
            if (broker != null) {
                broker.close();
                broker = null;
            }
        }
        executor.shutdownNow();
        stopForeground(true);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private synchronized void ensureBrokerStarted() throws IOException {
        if (broker != null) return;
        HardwareCodecBroker candidate = new HardwareCodecBroker(this);
        try {
            candidate.start();
            broker = candidate;
        } catch (IOException | RuntimeException e) {
            candidate.close();
            throw e;
        }
    }

    private Notification buildNotification() {
        Intent activityIntent = new Intent(this, BootActivity.class);
        PendingIntent activityPendingIntent = PendingIntent.getActivity(
                this, 2223, activityIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle(getString(R.string.dawnshell_codec_notification_title))
                .setContentText(getString(R.string.dawnshell_codec_notification_text))
                .setContentIntent(activityPendingIntent)
                .setOngoing(true)
                .build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = (NotificationManager) getSystemService(
                Context.NOTIFICATION_SERVICE);
        if (manager == null) return;
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, getString(R.string.dawnshell_codec_notification_channel),
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription(getString(
                R.string.dawnshell_codec_notification_channel_description));
        manager.createNotificationChannel(channel);
    }
}
