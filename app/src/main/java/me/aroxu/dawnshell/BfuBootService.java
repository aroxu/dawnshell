package me.aroxu.dawnshell;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.IBinder;
import android.os.UserManager;
import android.util.Log;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

public class BfuBootService extends Service {

    static final String ACTION_START = "me.aroxu.dawnshell.action.START_BFU";
    static final String ACTION_INSTALL_DEBIAN =
            "me.aroxu.dawnshell.action.INSTALL_DEBIAN_ROOTFS";
    static final String ACTION_CONFIGURE_DEBIAN =
            "me.aroxu.dawnshell.action.CONFIGURE_DEBIAN_SYSTEM";
    static final String ACTION_DEBIAN_START =
            "me.aroxu.dawnshell.action.START_DEBIAN_SYSTEMD";
    static final String ACTION_DEBIAN_RESTART =
            "me.aroxu.dawnshell.action.RESTART_DEBIAN_SYSTEMD";
    static final String ACTION_DEBIAN_STATUS =
            "me.aroxu.dawnshell.action.STATUS_DEBIAN_SYSTEMD";
    static final String ACTION_DEBIAN_STOP =
            "me.aroxu.dawnshell.action.STOP_DEBIAN_SYSTEMD";
    static final String ACTION_REMOVE_DEBIAN_ROOTFS =
            "me.aroxu.dawnshell.action.REMOVE_DEBIAN_ROOTFS";
    static final String ACTION_APPLY_DOCKER_NETWORK_POLICY =
            "me.aroxu.dawnshell.action.APPLY_DOCKER_NETWORK_POLICY";

    private static final String TAG = "DawnShell";
    private static final String NOTIFICATION_CHANNEL_ID = "dawnshell";
    private static final int NOTIFICATION_ID = 2222;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final ExecutorService lifecycleExecutor = Executors.newSingleThreadExecutor();
    private final Object lifecycleLock = new Object();
    private Future<?> lifecycleFuture;
    private DebianLauncher.Operation activeLifecycleOperation;
    private long lifecycleRequestId;
    private final AtomicLong urgentControlGeneration = new AtomicLong();
    private final AtomicBoolean startupChecksStarted = new AtomicBoolean(false);
    private final AtomicBoolean rootfsInstallStarted = new AtomicBoolean(false);
    private final AtomicBoolean systemConfigurationStarted = new AtomicBoolean(false);
    private final AtomicBoolean lifecycleOperationStarted = new AtomicBoolean(false);
    private final AtomicBoolean rootfsRemovalStarted = new AtomicBoolean(false);
    private final AtomicBoolean dockerPolicyStarted = new AtomicBoolean(false);

    private final BroadcastReceiver userUnlockedReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_USER_UNLOCKED.equals(intent.getAction())) {
                Log.i(TAG, "USER_UNLOCKED received");
                try {
                    BfuOperationLog.append(BfuBootService.this,
                            "USER_UNLOCKED received; Debian lifecycle unchanged");
                } catch (IOException e) {
                    Log.e(TAG, "Failed to persist USER_UNLOCKED event", e);
                }
                Log.i(TAG, "BFU Debian remains active after USER_UNLOCKED");
            }
        }
    };
    private boolean unlockReceiverRegistered;

    @Override
    public void onCreate() {
        super.onCreate();
        startForeground(NOTIFICATION_ID, buildNotification());
        registerUnlockReceiver();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        boolean disabledControlAllowed = ACTION_DEBIAN_STATUS.equals(action)
                || ACTION_DEBIAN_STOP.equals(action)
                || ACTION_REMOVE_DEBIAN_ROOTFS.equals(action);
        if (!BfuPreferences.isEnabled(this) && !disabledControlAllowed) {
            Log.i(TAG, "BFU service stopped because BFU mode is disabled");
            stopSelf();
            return START_NOT_STICKY;
        }

        boolean userUnlocked = isUserUnlocked();
        if (ACTION_START.equals(action) && !userUnlocked
                && startupChecksStarted.compareAndSet(false, true)) {
            executor.execute(this::runBfuStartupChecks);
        } else if (ACTION_START.equals(action) && userUnlocked) {
            Log.i(TAG, "BFU startup checks skipped because Android is already unlocked");
        }

        if (ACTION_APPLY_DOCKER_NETWORK_POLICY.equals(action)) {
            String policy = BfuPreferences.dockerNetworkPolicy(this);
            boolean hostIpcCompatibility =
                    BfuPreferences.dockerHostIpcCompatibility(this);
            if (!userUnlocked) {
                DockerNetworkProvisioner.recordRejected(this,
                        "unlock Android before applying Docker network policy");
            } else if (dockerPolicyStarted.compareAndSet(false, true)) {
                DockerNetworkProvisioner.recordQueued(this, policy,
                        hostIpcCompatibility);
                executor.execute(() -> runDockerNetworkPolicy(policy,
                        hostIpcCompatibility));
            } else {
                DockerNetworkProvisioner.recordRejected(this,
                        "another Docker policy operation is already running");
            }
        } else if (ACTION_REMOVE_DEBIAN_ROOTFS.equals(action)) {
            if (!userUnlocked) {
                recordOperation("DEBIAN_ROOTFS_REMOVE_REJECTED user_locked=true");
            } else if (rootfsInstallStarted.get() || systemConfigurationStarted.get()
                    || lifecycleOperationStarted.get()
                    || !rootfsRemovalStarted.compareAndSet(false, true)) {
                recordOperation("DEBIAN_ROOTFS_REMOVE_REJECTED another_operation_running=true");
            } else {
                executor.execute(this::runDebianRootfsRemoval);
            }
        } else if (ACTION_INSTALL_DEBIAN.equals(action)) {
            if (!userUnlocked) {
                Log.w(TAG, "Debian rootfs install rejected while CE is locked");
                DebianRootfsInstaller.recordRejected(this,
                        "unlock Android before installing the Debian rootfs");
            } else if (rootfsInstallStarted.compareAndSet(false, true)) {
                DebianRootfsInstaller.recordQueued(this);
                executor.execute(this::runDebianRootfsInstall);
            } else {
                Log.i(TAG, "Debian rootfs install already running in this service");
                DebianRootfsInstaller.recordMessage(this,
                        "REQUEST_IGNORED: a Debian rootfs installation is already running");
            }
        } else if (ACTION_CONFIGURE_DEBIAN.equals(action)) {
            if (!userUnlocked) {
                Log.w(TAG, "Debian system configuration rejected while CE is locked");
                DebianSystemProvisioner.recordRejected(this,
                        "unlock Android before configuring Debian systemd and SSH");
            } else if (systemConfigurationStarted.compareAndSet(false, true)) {
                DebianSystemProvisioner.recordQueued(this);
                executor.execute(this::runDebianSystemConfiguration);
            } else {
                DebianSystemProvisioner.recordMessage(this,
                        "REQUEST_IGNORED: Debian system configuration is already running");
            }
        } else {
            DebianLauncher.Operation operation = lifecycleOperation(action);
            if (operation != null) requestLifecycleOperation(operation, "app_button");
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (unlockReceiverRegistered) {
            unregisterReceiver(userUnlockedReceiver);
            unlockReceiverRegistered = false;
        }
        executor.shutdownNow();
        lifecycleExecutor.shutdownNow();
        stopForeground(true);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    static void requestDebianRootfsInstall(Context context) {
        startServiceAction(context, ACTION_INSTALL_DEBIAN);
    }

    static void requestDebianSystemConfiguration(Context context) {
        startServiceAction(context, ACTION_CONFIGURE_DEBIAN);
    }

    static void requestDebianRootfsRemoval(Context context) {
        startServiceAction(context, ACTION_REMOVE_DEBIAN_ROOTFS);
    }

    static void requestDockerNetworkPolicy(Context context) {
        startServiceAction(context, ACTION_APPLY_DOCKER_NETWORK_POLICY);
    }

    static void requestDebianLifecycle(Context context, DebianLauncher.Operation operation) {
        String action;
        switch (operation) {
            case START:
                action = ACTION_DEBIAN_START;
                break;
            case RESTART:
                action = ACTION_DEBIAN_RESTART;
                break;
            case STATUS:
                action = ACTION_DEBIAN_STATUS;
                break;
            case STOP:
                action = ACTION_DEBIAN_STOP;
                break;
            default:
                throw new IllegalArgumentException("Unsupported lifecycle operation");
        }
        startServiceAction(context, action);
    }

    private static void startServiceAction(Context context, String action) {
        Intent intent = new Intent(context, BfuBootService.class).setAction(action);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    private void runBfuStartupChecks() {
        long controlGeneration = urgentControlGeneration.get();
        BfuRuntime.Layout layout = null;
        try {
            Context deContext = BfuPreferences.deviceProtectedContext(this);
            Log.i(TAG, "DE context initialized: " + deContext.getFilesDir());
            layout = BfuRuntime.provision(deContext);
            Log.i(TAG, "BFU runtime verified: " + layout.root);
            String output = BfuRuntime.executeDirectBootProbe(layout);
            Log.i(TAG, "DE executable probe succeeded: " + output);
        } catch (IOException e) {
            Log.e(TAG, "BFU runtime provisioning or executable probe failed", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.w(TAG, "BFU executable probe interrupted");
            return;
        }

        try {
            BfuRootProbe.Result rootResult = BfuRootProbe.run(this);
            if (rootResult.root) {
                Log.i(TAG, "root probe: uid=0; " + rootResult.summary());
            } else {
                Log.w(TAG, "root probe failed; " + rootResult.summary());
            }

            if (!rootResult.succeededDuringBfu()) {
                Log.w(TAG, "Rootfs probe skipped because BFU root was not proven");
                return;
            }

            BfuCeIsolationProbe.Result ceIsolationResult =
                    BfuCeIsolationProbe.run(this);
            if (ceIsolationResult.succeededDuringBfu()) {
                Log.i(TAG, "DawnShell CE isolation proven; "
                        + ceIsolationResult.summary());
            } else if (BfuPreferences.allowCeReadableBfu(this)
                    && ceIsolationResult.contentAccessibleDuringBfu()) {
                String warning = "CE_ISOLATION_OVERRIDE_USED "
                        + ceIsolationResult.summary();
                Log.w(TAG, warning);
                BfuOperationLog.append(this, warning);
            } else {
                Log.e(TAG, "Refusing Debian launch because DawnShell CE isolation "
                        + "was not proven; " + ceIsolationResult.summary());
                return;
            }
            if (layout == null) {
                Log.w(TAG, "Rootfs probe skipped because BFU runtime was not provisioned");
                return;
            }

            BfuRootfsProbe.Result rootfsResult = BfuRootfsProbe.run(this, layout);
            if (rootfsResult.succeededDuringBfu()) {
                Log.i(TAG, "Debian rootfs accessible; " + rootfsResult.summary());
            } else {
                Log.w(TAG, "Debian rootfs probe failed; " + rootfsResult.summary());
                return;
            }

            BfuDebianRuntimeProbe.Result runtimeResult =
                    BfuDebianRuntimeProbe.run(this, layout);
            if (runtimeResult.succeededDuringBfu()) {
                Log.i(TAG, "Debian namespace/chroot probe succeeded; "
                        + runtimeResult.summary());
                if (urgentControlGeneration.get() == controlGeneration) {
                    requestLifecycleOperation(DebianLauncher.Operation.START,
                            "locked_boot");
                } else {
                    recordOperation("DEBIAN_AUTOSTART_SUPPRESSED "
                            + "reason=urgent_control_requested_during_startup");
                }
            } else {
                Log.w(TAG, "Debian namespace/chroot probe failed; "
                        + runtimeResult.summary());
            }
        } catch (IOException e) {
            Log.e(TAG, "Root/rootfs/runtime probe or DE log write failed", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.w(TAG, "Root, rootfs, or runtime probe interrupted");
        }
    }

    private void runDebianRootfsInstall() {
        try {
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            DebianRootfsInstaller.install(this, layout);
        } catch (IOException | IllegalStateException e) {
            Log.e(TAG, "Could not provision the Debian rootfs installer", e);
            DebianRootfsInstaller.recordRejected(this,
                    "installer provisioning failed: " + BfuSu.sanitize(e.getMessage()));
        } finally {
            rootfsInstallStarted.set(false);
        }
    }

    private void runDebianSystemConfiguration() {
        long controlGeneration = urgentControlGeneration.get();
        BfuRuntime.Layout layout = null;
        try {
            layout = BfuRuntime.provision(this);
            // Reconfiguration must never mutate packages below a live PID 1.
            if (!runDebianLifecycleNow(layout, DebianLauncher.Operation.STOP,
                    "AFU_reconfiguration")) {
                DebianSystemProvisioner.recordRejected(this,
                        "could not prove that the current Debian PID 1 stopped");
                return;
            }
            if (DebianSystemProvisioner.configure(this, layout)
                    && urgentControlGeneration.get() == controlGeneration) {
                runDebianLifecycleNow(layout, DebianLauncher.Operation.START,
                        "AFU_configuration_completed");
            } else if (urgentControlGeneration.get() != controlGeneration) {
                recordOperation("DEBIAN_AUTOSTART_SUPPRESSED "
                        + "reason=urgent_control_requested_during_configuration");
            }
        } catch (IOException | IllegalStateException e) {
            Log.e(TAG, "Could not provision the Debian system configurator", e);
            DebianSystemProvisioner.recordRejected(this,
                    "configuration provisioning failed: "
                            + BfuSu.sanitize(e.getMessage()));
        } finally {
            systemConfigurationStarted.set(false);
        }
    }

    private void runDebianRootfsRemoval() {
        try {
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            DebianRootfsRemover.remove(this, layout);
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_ROOTFS_REMOVE_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            recordOperation("DEBIAN_ROOTFS_REMOVE_FAILED interrupted=true");
        } finally {
            rootfsRemovalStarted.set(false);
            if (!BfuPreferences.isEnabled(this)) stopSelf();
        }
    }

    private void runDockerNetworkPolicy(String policy,
                                        boolean hostIpcCompatibility) {
        long controlGeneration = urgentControlGeneration.get();
        BfuRuntime.Layout layout = null;
        boolean wasRunning = false;
        try {
            layout = BfuRuntime.provision(this);
            wasRunning = DebianLauncher.isRunning(layout);
            if (wasRunning && !runDebianLifecycleNow(layout,
                    DebianLauncher.Operation.STOP, "AFU_Docker_policy")) {
                DockerNetworkProvisioner.recordRejected(this,
                        "could not prove that Debian PID 1 stopped");
                return;
            }
            DockerNetworkProvisioner.apply(this, layout, policy,
                    hostIpcCompatibility);
        } catch (IOException | IllegalStateException e) {
            DockerNetworkProvisioner.recordRejected(this,
                    "Docker policy provisioning failed: "
                            + BfuSu.sanitize(e.getMessage()));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            DockerNetworkProvisioner.recordRejected(this,
                    "Docker policy operation interrupted");
        } finally {
            if (wasRunning && layout != null && !Thread.currentThread().isInterrupted()
                    && urgentControlGeneration.get() == controlGeneration) {
                runDebianLifecycleNow(layout, DebianLauncher.Operation.START,
                        "AFU_Docker_policy_completed");
            } else if (wasRunning
                    && urgentControlGeneration.get() != controlGeneration) {
                recordOperation("DEBIAN_AUTOSTART_SUPPRESSED "
                        + "reason=urgent_control_requested_during_Docker_policy");
            }
            dockerPolicyStarted.set(false);
        }
    }

    private void recordOperation(String message) {
        try {
            BfuOperationLog.append(this, message);
        } catch (IOException e) {
            Log.e(TAG, "Could not persist operation result", e);
        }
    }

    private void requestLifecycleOperation(DebianLauncher.Operation operation,
                                           String trigger) {
        boolean urgent = operation == DebianLauncher.Operation.STOP
                || operation == DebianLauncher.Operation.RESTART;
        if (operation == DebianLauncher.Operation.RESTART
                && managementOperationRunning()) {
            recordOperation("DEBIAN_LIFECYCLE_REJECTED operation=restart "
                    + "reason=management_operation_running");
            Log.w(TAG, "Restart rejected while a rootfs management operation is active");
            return;
        }

        synchronized (lifecycleLock) {
            if (lifecycleFuture != null && !lifecycleFuture.isDone()) {
                if (!urgent) {
                    recordOperation("DEBIAN_LIFECYCLE_REJECTED operation="
                            + operation.name().toLowerCase(java.util.Locale.US)
                            + " reason=lifecycle_operation_running");
                    Log.i(TAG, "Debian lifecycle operation already running");
                    return;
                }
                if (activeLifecycleOperation != null
                        && (activeLifecycleOperation == operation
                        || activeLifecycleOperation == DebianLauncher.Operation.STOP)) {
                    recordOperation("DEBIAN_LIFECYCLE_REJECTED operation="
                            + operation.name().toLowerCase(java.util.Locale.US)
                            + " reason="
                            + activeLifecycleOperation.name().toLowerCase(
                            java.util.Locale.US)
                            + "_already_running");
                    return;
                }
                lifecycleFuture.cancel(true);
                recordOperation("DEBIAN_LIFECYCLE_PREEMPTED_BY operation="
                        + operation.name().toLowerCase(java.util.Locale.US));
            }
            if (urgent) urgentControlGeneration.incrementAndGet();
            final long requestId = ++lifecycleRequestId;
            lifecycleOperationStarted.set(true);
            activeLifecycleOperation = operation;
            lifecycleFuture = lifecycleExecutor.submit(() -> {
                BfuRuntime.Layout layout = null;
                try {
                    layout = BfuRuntime.provision(this);
                    runDebianLifecycleNow(layout, operation, trigger);
                } catch (IOException | IllegalStateException e) {
                    Log.e(TAG, "Could not provision Debian lifecycle runtime", e);
                    DebianLauncher.recordFailure(this, layout, operation,
                            e.getMessage());
                } finally {
                    synchronized (lifecycleLock) {
                        if (lifecycleRequestId == requestId) {
                            lifecycleOperationStarted.set(false);
                            activeLifecycleOperation = null;
                        }
                    }
                    if (!BfuPreferences.isEnabled(this)) stopSelf();
                }
            });
        }
    }

    private boolean managementOperationRunning() {
        return rootfsInstallStarted.get() || systemConfigurationStarted.get()
                || rootfsRemovalStarted.get() || dockerPolicyStarted.get();
    }

    private boolean runDebianLifecycleNow(BfuRuntime.Layout layout,
                                          DebianLauncher.Operation operation,
                                          String trigger) {
        try {
            return DebianLauncher.run(this, layout, operation, trigger);
        } catch (IOException e) {
            Log.e(TAG, "Debian lifecycle I/O failed: " + operation, e);
            DebianLauncher.recordFailure(this, layout, operation, e.getMessage());
            return false;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.w(TAG, "Debian lifecycle interrupted: " + operation);
            DebianLauncher.recordFailure(this, layout, operation, "interrupted");
            return false;
        }
    }

    private static DebianLauncher.Operation lifecycleOperation(String action) {
        if (ACTION_DEBIAN_START.equals(action)) return DebianLauncher.Operation.START;
        if (ACTION_DEBIAN_RESTART.equals(action)) return DebianLauncher.Operation.RESTART;
        if (ACTION_DEBIAN_STATUS.equals(action)) return DebianLauncher.Operation.STATUS;
        if (ACTION_DEBIAN_STOP.equals(action)) return DebianLauncher.Operation.STOP;
        return null;
    }

    private boolean isUserUnlocked() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true;
        UserManager userManager = (UserManager) getSystemService(Context.USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }

    private void registerUnlockReceiver() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;
        registerReceiver(userUnlockedReceiver, new IntentFilter(Intent.ACTION_USER_UNLOCKED));
        unlockReceiverRegistered = true;
    }

    private Notification buildNotification() {
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    getString(R.string.bfu_notification_channel),
                    NotificationManager.IMPORTANCE_LOW);
            channel.setDescription(getString(R.string.bfu_notification_channel_description));
            manager.createNotificationChannel(channel);
        }

        Intent activityIntent = new Intent(this, BootActivity.class);
        int pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingIntentFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pendingIntent = PendingIntent.getActivity(
                this, 0, activityIntent, pendingIntentFlags);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, NOTIFICATION_CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        return builder
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle(getString(R.string.bfu_notification_title))
                .setContentText(getString(R.string.bfu_notification_text))
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build();
    }
}
