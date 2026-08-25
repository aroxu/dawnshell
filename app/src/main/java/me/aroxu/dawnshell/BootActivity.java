package me.aroxu.dawnshell;

import android.annotation.SuppressLint;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PersistableBundle;
import android.os.Process;
import android.os.UserManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.TextUtils;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.Log;
import android.util.Base64;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.widget.AppCompatTextView;

import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.color.MaterialColors;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.textfield.TextInputLayout;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class BootActivity extends AppCompatActivity {

    private static final String TAG = "DawnShell";
    private static final int REQUEST_EXPORT_SSH_PRIVATE_KEY = 1001;

    private CompoundButton enableBfu;
    private CompoundButton allowCeReadableBfu;
    private RadioGroup cgroupPolicyGroup;
    private RadioGroup dockerNetworkPolicyGroup;
    private CompoundButton dockerHostIpcCompatibility;
    private CompoundButton hardwareCodecBridge;
    private RadioGroup usbPassthroughGroup;
    private TextInputLayout usbExclusiveDeviceIdsLayout;
    private EditText usbExclusiveDeviceIds;
    private TextView generatedPublicKey;
    private TextView probeSummary;
    private TextView settingsDirty;
    private TextView rootProbeStatus;
    private TextView ceIsolationProbeStatus;
    private TextView rootfsProbeStatus;
    private TextView debianRuntimeProbeStatus;
    private Button rootAuthorizationButton;
    private TextView rootAuthorizationStatus;
    private TextView operationLog;
    private TextView installStatus;
    private TextView installLog;
    private TextView systemConfigStatus;
    private TextView systemConfigLog;
    private TextView lifecycleStatus;
    private TextView dockerPolicyStatus;
    private TextView hardwareCodecStatus;
    private Button hardwareCodecSelfTestButton;
    private Button hardwareCodecPerformanceTestButton;
    private Button hardwareCodecLongRunStartButton;
    private Button hardwareCodecLongRunStopButton;
    private TextView hardwareCodecLongRunStatus;
    private TextView lifecycleLog;
    private EditText rootPassword;
    private EditText rootPasswordConfirm;
    private EditText debianPassword;
    private EditText debianPasswordConfirm;
    private Button rootPasswordButton;
    private Button debianPasswordButton;
    private Handler liveLogHandler;
    private final ExecutorService rootAuthorizationExecutor =
            Executors.newSingleThreadExecutor();
    private final ExecutorService passwordExecutor =
            Executors.newSingleThreadExecutor();
    private final ExecutorService codecSelfTestExecutor =
            Executors.newSingleThreadExecutor();
    private final ExecutorService codecControlExecutor =
            Executors.newSingleThreadExecutor();
    private volatile boolean rootAuthorizationInProgress;
    private volatile boolean passwordUpdateInProgress;
    private volatile boolean codecSelfTestInProgress;
    private volatile boolean codecControlInProgress;
    private boolean activityResumed;
    private BfuRootAuthorization.Result pendingRootAuthorizationResult;
    private String pendingRootAuthorizationFailure;
    private String lastDisplayedOperationLog = "";
    private String lastDisplayedInstallLog = "";
    private String lastDisplayedSystemConfigLog = "";
    private String lastDisplayedLifecycleLog = "";

    private final Runnable refreshLiveLog = new Runnable() {
        @Override
        public void run() {
            refreshRootAuthorizationStatus();
            refreshInstallerStatus();
            refreshSystemConfigurationStatus();
            refreshLifecycleStatus();
            refreshDockerPolicyStatus();
            refreshHardwareCodecStatus();
            refreshHardwareCodecLongRunStatus();
            liveLogHandler.postDelayed(this, 1_000L);
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        liveLogHandler = new Handler(Looper.getMainLooper());
        setContentView(R.layout.activity_boot);
        bindDashboardViews();
        loadSettings();
        watchSettingsChanges();
    }

    @Override
    protected void onResume() {
        super.onResume();
        activityResumed = true;
        liveLogHandler.removeCallbacks(refreshLiveLog);
        liveLogHandler.post(refreshLiveLog);
        showPendingRootAuthorizationResult();
    }

    @Override
    protected void onPause() {
        activityResumed = false;
        liveLogHandler.removeCallbacks(refreshLiveLog);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        rootAuthorizationExecutor.shutdownNow();
        passwordExecutor.shutdownNow();
        codecSelfTestExecutor.shutdownNow();
        codecControlExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode,
                                    @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_EXPORT_SSH_PRIVATE_KEY
                || resultCode != RESULT_OK || data == null) return;
        Uri destination = data.getData();
        if (destination == null) {
            DawnShellNotice.show(this, R.string.bfu_private_key_export_failed);
            return;
        }
        try {
            BfuSshClientKeyStore.Identity identity = BfuSshClientKeyStore.ensure(this);
            try (OutputStream output = getContentResolver().openOutputStream(
                    destination, "wt")) {
                if (output == null) throw new IOException("document provider returned no stream");
                output.write(identity.privateKey.getBytes(
                        java.nio.charset.StandardCharsets.US_ASCII));
                output.flush();
            }
            recordOperation("SSH_CLIENT_PRIVATE_KEY_EXPORTED destination=document_provider");
            DawnShellNotice.show(this, R.string.bfu_private_key_exported);
        } catch (IOException e) {
            recordOperation("SSH_CLIENT_PRIVATE_KEY_EXPORT_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_private_key_export_failed_detail,
                    e.getMessage()));
        }
    }

    private void bindDashboardViews() {
        MaterialToolbar toolbar = findViewById(R.id.dashboard_toolbar);
        toolbar.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == R.id.action_logs) {
                openLogs();
                return true;
            }
            if (item.getItemId() == R.id.action_licenses) {
                startActivity(new Intent(this, OpenSourceLicensesActivity.class));
                return true;
            }
            return false;
        });

        enableBfu = findViewById(R.id.switch_enable_bfu);
        allowCeReadableBfu = findViewById(R.id.switch_allow_ce_readable_bfu);
        cgroupPolicyGroup = findViewById(R.id.cgroup_policy_group);
        dockerNetworkPolicyGroup = findViewById(R.id.docker_network_policy_group);
        dockerHostIpcCompatibility = findViewById(
                R.id.switch_docker_host_ipc_compatibility);
        hardwareCodecBridge = findViewById(
                R.id.switch_hardware_codec_bridge);
        usbPassthroughGroup = findViewById(R.id.usb_passthrough_group);
        usbExclusiveDeviceIdsLayout = findViewById(
                R.id.usb_exclusive_device_ids_layout);
        usbExclusiveDeviceIds = findViewById(R.id.usb_exclusive_device_ids);
        generatedPublicKey = findViewById(R.id.generated_public_key);
        probeSummary = findViewById(R.id.probe_summary);
        settingsDirty = findViewById(R.id.settings_dirty_text);
        rootAuthorizationButton = findViewById(R.id.root_authorization_button);
        rootAuthorizationStatus = findViewById(R.id.root_authorization_status);
        installStatus = findViewById(R.id.install_status);
        systemConfigStatus = findViewById(R.id.system_config_status);
        lifecycleStatus = findViewById(R.id.lifecycle_status);
        dockerPolicyStatus = findViewById(R.id.docker_policy_status);
        hardwareCodecStatus = findViewById(R.id.hardware_codec_status);
        hardwareCodecSelfTestButton = findViewById(
                R.id.run_hardware_codec_self_test_button);
        hardwareCodecPerformanceTestButton = findViewById(
                R.id.run_hardware_codec_performance_test_button);
        hardwareCodecLongRunStartButton = findViewById(
                R.id.start_hardware_codec_long_run_button);
        hardwareCodecLongRunStopButton = findViewById(
                R.id.stop_hardware_codec_long_run_button);
        hardwareCodecLongRunStatus = findViewById(
                R.id.hardware_codec_long_run_status);
        rootPassword = findViewById(R.id.root_password);
        rootPasswordConfirm = findViewById(R.id.root_password_confirm);
        debianPassword = findViewById(R.id.debian_password);
        debianPasswordConfirm = findViewById(R.id.debian_password_confirm);
        rootPasswordButton = findViewById(R.id.root_password_button);
        debianPasswordButton = findViewById(R.id.debian_password_button);

        rootAuthorizationButton.setOnClickListener(view -> confirmRootAuthorization());
        findViewById(R.id.save_provision_button)
                .setOnClickListener(view -> saveAndProvision());
        findViewById(R.id.refresh_probes_button)
                .setOnClickListener(view -> refreshProbeStatus(true));
        findViewById(R.id.install_debian_button)
                .setOnClickListener(view -> confirmDebianInstall());
        findViewById(R.id.configure_system_button)
                .setOnClickListener(view -> confirmSystemConfiguration());
        findViewById(R.id.apply_docker_policy_button)
                .setOnClickListener(view -> confirmDockerNetworkPolicy());
        findViewById(R.id.apply_host_usb_policy_button)
                .setOnClickListener(view -> confirmHostUsbPolicy());
        findViewById(R.id.probe_hardware_codecs_button)
                .setOnClickListener(view -> applyHardwareCodecSetting());
        hardwareCodecSelfTestButton.setOnClickListener(view ->
                runHardwareCodecSelfTest());
        hardwareCodecPerformanceTestButton.setOnClickListener(view ->
                runHardwareCodecPerformanceTest());
        findViewById(R.id.open_ffmpeg_codec_guide_button).setOnClickListener(view ->
                showFfmpegCodecGuide());
        findViewById(R.id.open_live_codec_guide_button).setOnClickListener(view ->
                showLiveCodecGuide());
        hardwareCodecLongRunStartButton.setOnClickListener(view ->
                confirmHardwareCodecLongRun());
        hardwareCodecLongRunStopButton.setOnClickListener(view ->
                runHardwareCodecLongRun(HardwareCodecLongRun.Operation.STOP));
        findViewById(R.id.open_hardware_codec_long_run_log_button)
                .setOnClickListener(view -> startActivity(LogDetailActivity.createIntent(
                        this, DawnShellLogRepository.CODEC_LONG_RUN)));
        findViewById(R.id.open_hardware_codec_log_button).setOnClickListener(view ->
                startActivity(LogDetailActivity.createIntent(
                        this, DawnShellLogRepository.HARDWARE_CODEC)));
        findViewById(R.id.open_compatibility_log_button).setOnClickListener(view ->
                startActivity(LogDetailActivity.createIntent(
                        this, DawnShellLogRepository.COMPATIBILITY)));
        findViewById(R.id.open_host_usb_log_button).setOnClickListener(view ->
                startActivity(LogDetailActivity.createIntent(
                        this, DawnShellLogRepository.LIFECYCLE)));
        findViewById(R.id.start_debian_button).setOnClickListener(view ->
                requestLifecycle(DebianLauncher.Operation.START));
        findViewById(R.id.restart_debian_button)
                .setOnClickListener(view -> confirmRestartDebian());
        findViewById(R.id.status_debian_button).setOnClickListener(view ->
                requestLifecycle(DebianLauncher.Operation.STATUS));
        findViewById(R.id.stop_debian_button)
                .setOnClickListener(view -> confirmStopDebian());
        findViewById(R.id.export_private_key_button)
                .setOnClickListener(view -> confirmPrivateKeyFileExport());
        findViewById(R.id.copy_key_import_button)
                .setOnClickListener(view -> confirmCopyKeyImportCommand());
        findViewById(R.id.copy_ssh_connect_button).setOnClickListener(view ->
                copySshClientCommand("ssh_connect", buildSshConnectCommand(),
                        R.string.bfu_ssh_connect_command_copied));
        findViewById(R.id.rotate_ssh_key_button)
                .setOnClickListener(view -> confirmRotateSshClientKey());
        rootPasswordButton.setOnClickListener(view -> updateDebianPassword(
                "root", rootPassword, rootPasswordConfirm));
        debianPasswordButton.setOnClickListener(view -> updateDebianPassword(
                "debian", debianPassword, debianPasswordConfirm));
        findViewById(R.id.remove_rootfs_button)
                .setOnClickListener(view -> confirmDebianRootfsRemoval());
        findViewById(R.id.open_logs_button).setOnClickListener(view -> openLogs());
        findViewById(R.id.open_setup_logs_button).setOnClickListener(view -> openLogs());
        findViewById(R.id.open_runtime_log_button).setOnClickListener(view ->
                startActivity(LogDetailActivity.createIntent(
                        this, DawnShellLogRepository.LIFECYCLE)));
    }

    private void watchSettingsChanges() {
        CompoundButton.OnCheckedChangeListener listener = (button, checked) ->
                settingsDirty.setVisibility(View.VISIBLE);
        enableBfu.setOnCheckedChangeListener(listener);
        allowCeReadableBfu.setOnCheckedChangeListener(listener);
        RadioGroup.OnCheckedChangeListener radioListener = (group, checkedId) ->
                settingsDirty.setVisibility(View.VISIBLE);
        cgroupPolicyGroup.setOnCheckedChangeListener(radioListener);
        dockerNetworkPolicyGroup.setOnCheckedChangeListener(radioListener);
        dockerHostIpcCompatibility.setOnCheckedChangeListener(listener);
        hardwareCodecBridge.setOnCheckedChangeListener(listener);
        usbPassthroughGroup.setOnCheckedChangeListener((group, checkedId) -> {
            settingsDirty.setVisibility(View.VISIBLE);
            refreshUsbExclusiveEditorState();
        });
        usbExclusiveDeviceIds.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence text, int start, int count,
                                          int after) {}

            @Override
            public void onTextChanged(CharSequence text, int start, int before,
                                      int count) {
                settingsDirty.setVisibility(View.VISIBLE);
                usbExclusiveDeviceIdsLayout.setError(null);
            }

            @Override
            public void afterTextChanged(Editable editable) {}
        });
    }

    private void openLogs() {
        startActivity(new Intent(this, LogsActivity.class));
    }

    private ScrollView buildSettingsView() {
        int padding = dp(16);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(padding, padding, padding, padding);

        TextView hero = new TextView(this);
        hero.setText(R.string.dawnshell_home_title);
        hero.setTextSize(28f);
        hero.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        content.addView(hero, matchWrap());

        TextView explanation = createBodyText(R.string.bfu_settings_explanation);
        LinearLayout.LayoutParams heroBodyLayout = sectionSpacing(dp(6), dp(20));
        content.addView(explanation, heroBodyLayout);

        LinearLayout directBootCard = createSectionCard(content,
                R.string.dawnshell_section_direct_boot,
                R.string.dawnshell_section_direct_boot_description);

        enableBfu = new CheckBox(this);
        enableBfu.setText(R.string.bfu_enable);
        directBootCard.addView(enableBfu, matchWrap());

        TextView rootAuthorizationExplanation =
                createBodyText(R.string.bfu_root_authorization_explanation);
        directBootCard.addView(rootAuthorizationExplanation, sectionSpacing(dp(6), dp(8)));

        rootAuthorizationButton = createActionButton(
                R.string.bfu_request_root_authorization);
        rootAuthorizationButton.setOnClickListener(view -> confirmRootAuthorization());
        directBootCard.addView(rootAuthorizationButton, matchWrap());

        rootAuthorizationStatus = createLogConsole(3, 8);
        addLogConsole(directBootCard, rootAuthorizationStatus, dp(8));

        Button save = createActionButton(R.string.bfu_save_and_provision);
        save.setOnClickListener(view -> saveAndProvision());
        directBootCard.addView(save, matchWrap());

        LinearLayout setupCard = createSectionCard(content,
                R.string.dawnshell_section_debian_setup,
                R.string.dawnshell_section_debian_setup_description);

        TextView installExplanation = createBodyText(R.string.bfu_debian_install_explanation);
        setupCard.addView(installExplanation, sectionSpacing(0, dp(8)));

        Button install = createActionButton(R.string.bfu_install_debian);
        install.setOnClickListener(view -> confirmDebianInstall());
        setupCard.addView(install, matchWrap());

        installStatus = createLogConsole(3, 7);
        addLogConsole(setupCard, installStatus, dp(6));
        installLog = createLogConsole(12, 22);
        addExpandableConsole(setupCard, R.string.bfu_debian_install_log_title, installLog);

        TextView systemConfigExplanation =
                createBodyText(R.string.bfu_system_config_explanation);
        setupCard.addView(systemConfigExplanation, sectionSpacing(dp(18), dp(8)));

        Button configureSystem = createActionButton(R.string.bfu_configure_system);
        configureSystem.setOnClickListener(view -> confirmSystemConfiguration());
        setupCard.addView(configureSystem, matchWrap());

        systemConfigStatus = createLogConsole(3, 7);
        addLogConsole(setupCard, systemConfigStatus, dp(6));
        systemConfigLog = createLogConsole(12, 22);
        addExpandableConsole(setupCard, R.string.bfu_system_config_log_title,
                systemConfigLog);

        LinearLayout runtimeCard = createSectionCard(content,
                R.string.dawnshell_section_runtime,
                R.string.dawnshell_section_runtime_description);
        TextView lifecycleExplanation = createBodyText(R.string.bfu_lifecycle_explanation);
        runtimeCard.addView(lifecycleExplanation, sectionSpacing(0, dp(8)));

        Button startDebian = createActionButton(R.string.bfu_start_debian_short);
        startDebian.setOnClickListener(view -> requestLifecycle(DebianLauncher.Operation.START));
        Button restartDebian = createActionButton(R.string.bfu_restart_debian_short);
        restartDebian.setOnClickListener(view -> confirmRestartDebian());
        runtimeCard.addView(createButtonRow(startDebian, restartDebian), matchWrap());

        Button statusDebian = createActionButton(R.string.bfu_status_debian_short);
        statusDebian.setOnClickListener(view -> requestLifecycle(DebianLauncher.Operation.STATUS));
        Button stopDebian = createActionButton(R.string.bfu_stop_debian_short);
        stopDebian.setOnClickListener(view -> confirmStopDebian());
        runtimeCard.addView(createButtonRow(statusDebian, stopDebian),
                sectionSpacing(dp(4), 0));

        lifecycleStatus = createLogConsole(3, 8);
        addLogConsole(runtimeCard, lifecycleStatus, dp(6));
        lifecycleLog = createLogConsole(12, 24);
        addExpandableConsole(runtimeCard, R.string.bfu_lifecycle_log_title, lifecycleLog);

        LinearLayout accessCard = createSectionCard(content,
                R.string.dawnshell_section_access,
                R.string.dawnshell_section_access_description);

        TextView generatedKeyExplanation =
                createBodyText(R.string.bfu_generated_key_explanation);
        accessCard.addView(generatedKeyExplanation, sectionSpacing(0, dp(8)));

        generatedPublicKey = createLogConsole(3, 6);
        addLogConsole(accessCard, generatedPublicKey, dp(8));

        Button exportPrivateKey = createActionButton(R.string.bfu_export_private_key_file);
        exportPrivateKey.setOnClickListener(view -> confirmPrivateKeyFileExport());
        accessCard.addView(exportPrivateKey, matchWrap());

        Button copyKeyImportCommand = createActionButton(R.string.bfu_copy_key_import_command);
        copyKeyImportCommand.setOnClickListener(view -> confirmCopyKeyImportCommand());
        accessCard.addView(copyKeyImportCommand, sectionSpacing(dp(4), 0));

        Button copySshConnectCommand = createActionButton(
                R.string.bfu_copy_ssh_connect_command);
        copySshConnectCommand.setOnClickListener(view -> copySshClientCommand(
                "ssh_connect", buildSshConnectCommand(),
                R.string.bfu_ssh_connect_command_copied));
        accessCard.addView(copySshConnectCommand, sectionSpacing(dp(4), 0));

        Button rotateSshKey = createActionButton(R.string.bfu_rotate_ssh_client_key);
        rotateSshKey.setOnClickListener(view -> confirmRotateSshClientKey());
        accessCard.addView(rotateSshKey, sectionSpacing(dp(4), 0));

        LinearLayout accountCard = createSectionCard(content,
                R.string.dawnshell_section_accounts,
                R.string.dawnshell_section_accounts_description);

        TextView passwordExplanation = createBodyText(R.string.bfu_password_explanation);
        accountCard.addView(passwordExplanation, sectionSpacing(0, dp(8)));

        rootPassword = createPasswordEditor(R.string.bfu_root_password_hint);
        accountCard.addView(rootPassword, matchWrap());
        rootPasswordConfirm = createPasswordEditor(R.string.bfu_root_password_confirm_hint);
        accountCard.addView(rootPasswordConfirm, matchWrap());
        rootPasswordButton = createActionButton(R.string.bfu_set_root_password);
        rootPasswordButton.setOnClickListener(view -> updateDebianPassword(
                "root", rootPassword, rootPasswordConfirm));
        accountCard.addView(rootPasswordButton, matchWrap());

        debianPassword = createPasswordEditor(R.string.bfu_debian_password_hint);
        accountCard.addView(debianPassword, sectionSpacing(dp(16), 0));
        debianPasswordConfirm = createPasswordEditor(
                R.string.bfu_debian_password_confirm_hint);
        accountCard.addView(debianPasswordConfirm, matchWrap());
        debianPasswordButton = createActionButton(R.string.bfu_set_debian_password);
        debianPasswordButton.setOnClickListener(view -> updateDebianPassword(
                "debian", debianPassword, debianPasswordConfirm));
        accountCard.addView(debianPasswordButton, matchWrap());

        LinearLayout advancedCard = createSectionCard(content,
                R.string.dawnshell_section_advanced,
                R.string.dawnshell_section_advanced_description);

        LinearLayout advancedContent = new LinearLayout(this);
        advancedContent.setOrientation(LinearLayout.VERTICAL);
        advancedContent.setVisibility(View.GONE);
        Button advancedToggle = createExpandableToggle(
                R.string.dawnshell_show_advanced, R.string.dawnshell_hide_advanced,
                advancedContent);
        advancedCard.addView(advancedToggle, matchWrap());

        allowCeReadableBfu = new CheckBox(this);
        allowCeReadableBfu.setText(R.string.bfu_allow_ce_readable);
        advancedContent.addView(allowCeReadableBfu, matchWrap());

        TextView ceOverrideWarning = createBodyText(R.string.bfu_allow_ce_readable_warning);
        ceOverrideWarning.setTextColor(Color.rgb(255, 183, 77));
        advancedContent.addView(ceOverrideWarning, sectionSpacing(0, dp(10)));

        Button refreshRootStatus = createActionButton(R.string.bfu_refresh_probe_status);
        refreshRootStatus.setText(R.string.bfu_refresh_probe_status);
        refreshRootStatus.setOnClickListener(view -> refreshProbeStatus(true));
        advancedContent.addView(refreshRootStatus, matchWrap());

        rootProbeStatus = createLogConsole(3, 8);
        addLogConsole(advancedContent, rootProbeStatus, dp(8));

        ceIsolationProbeStatus = createLogConsole(3, 8);
        addLogConsole(advancedContent, ceIsolationProbeStatus, dp(8));

        rootfsProbeStatus = createLogConsole(3, 8);
        addLogConsole(advancedContent, rootfsProbeStatus, dp(8));

        debianRuntimeProbeStatus = createLogConsole(4, 10);
        addLogConsole(advancedContent, debianRuntimeProbeStatus, dp(12));

        operationLog = createLogConsole(7, 14);
        addExpandableConsole(advancedContent, R.string.bfu_operation_log_title,
                operationLog);
        advancedCard.addView(advancedContent, matchWrap());

        LinearLayout dangerCard = createSectionCard(content,
                R.string.dawnshell_section_danger,
                R.string.dawnshell_section_danger_description);
        Button removeRootfs = createActionButton(R.string.bfu_remove_debian_rootfs);
        removeRootfs.setTextColor(Color.rgb(255, 82, 82));
        removeRootfs.setOnClickListener(view -> confirmDebianRootfsRemoval());
        dangerCard.addView(removeRootfs, matchWrap());

        ScrollView scrollView = new ScrollView(this);
        scrollView.setFillViewport(true);
        scrollView.setSmoothScrollingEnabled(true);
        // Avoid the same Android 16 vendor ScrollBarDrawable crash that affects
        // the consoles. Scrolling remains available by touch and keyboard.
        scrollView.setVerticalScrollBarEnabled(false);
        scrollView.addView(content);
        return scrollView;
    }

    private LinearLayout createSectionCard(LinearLayout parent, int titleRes,
                                           int descriptionRes) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(16), dp(16), dp(16), dp(16));
        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.argb(18, 127, 127, 127));
        background.setCornerRadius(dp(16));
        background.setStroke(Math.max(1, dp(1)), Color.argb(48, 127, 127, 127));
        card.setBackground(background);

        TextView title = new TextView(this);
        title.setText(titleRes);
        title.setTextSize(20f);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        card.addView(title, matchWrap());

        TextView description = createBodyText(descriptionRes);
        card.addView(description, sectionSpacing(dp(4), dp(12)));

        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        layout.bottomMargin = dp(14);
        parent.addView(card, layout);
        return card;
    }

    private TextView createBodyText(int textRes) {
        TextView text = new TextView(this);
        text.setText(textRes);
        text.setTextSize(14f);
        text.setLineSpacing(0f, 1.15f);
        return text;
    }

    private Button createActionButton(int textRes) {
        Button button = new Button(this);
        button.setText(textRes);
        button.setAllCaps(false);
        button.setMinHeight(dp(48));
        return button;
    }

    private LinearLayout createButtonRow(Button first, Button second) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams firstLayout = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        firstLayout.rightMargin = dp(4);
        row.addView(first, firstLayout);
        LinearLayout.LayoutParams secondLayout = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        secondLayout.leftMargin = dp(4);
        row.addView(second, secondLayout);
        return row;
    }

    private void addExpandableConsole(LinearLayout parent, int titleRes,
                                      TextView console) {
        TextView title = createBodyText(titleRes);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        parent.addView(title, sectionSpacing(dp(12), 0));

        LinearLayout details = new LinearLayout(this);
        details.setOrientation(LinearLayout.VERTICAL);
        details.setVisibility(View.GONE);

        TextView hint = createBodyText(R.string.bfu_log_console_hint);
        hint.setTextSize(12f);
        details.addView(hint, sectionSpacing(dp(4), 0));
        addLogConsole(details, console, 0);

        Button toggle = createExpandableToggle(R.string.dawnshell_show_details,
                R.string.dawnshell_hide_details, details);
        toggle.setContentDescription(getString(titleRes));
        parent.addView(toggle, sectionSpacing(dp(4), 0));
        parent.addView(details, matchWrap());
    }

    private Button createExpandableToggle(int showTextRes, int hideTextRes,
                                          LinearLayout target) {
        Button toggle = createActionButton(showTextRes);
        toggle.setCompoundDrawablesWithIntrinsicBounds(0, 0,
                android.R.drawable.arrow_down_float, 0);
        toggle.setOnClickListener(view -> {
            boolean show = target.getVisibility() != View.VISIBLE;
            target.setVisibility(show ? View.VISIBLE : View.GONE);
            toggle.setText(show ? hideTextRes : showTextRes);
            toggle.setCompoundDrawablesWithIntrinsicBounds(0, 0,
                    show ? android.R.drawable.arrow_up_float
                            : android.R.drawable.arrow_down_float, 0);
        });
        return toggle;
    }

    private LinearLayout.LayoutParams sectionSpacing(int top, int bottom) {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        layout.topMargin = top;
        layout.bottomMargin = bottom;
        return layout;
    }

    private void refreshGeneratedSshIdentity(boolean provisionPublicKey) {
        try {
            BfuSshClientKeyStore.Identity identity = BfuSshClientKeyStore.ensure(this);
            if (provisionPublicKey) {
                BfuRuntime.Layout layout = BfuRuntime.provision(this);
                BfuAuthorizedKeys.validateAndSave(layout, identity.publicKey);
            }
            replaceConsoleText(generatedPublicKey, identity.publicKey, false);
        } catch (IOException e) {
            replaceConsoleText(generatedPublicKey,
                    getString(R.string.bfu_generated_key_failed, e.getMessage()), false);
        }
    }

    private void confirmRotateSshClientKey() {
        if (!isUserUnlocked()) {
            DawnShellNotice.show(this, R.string.bfu_ssh_key_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_rotate_ssh_key_confirm_title)
                .setMessage(R.string.bfu_rotate_ssh_key_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_rotate_ssh_key_confirm_button,
                        (dialog, which) -> rotateSshClientKey())
                .show();
    }

    private void rotateSshClientKey() {
        try {
            BfuSshClientKeyStore.Identity identity =
                    BfuSshClientKeyStore.generateAndReplace(this);
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            BfuAuthorizedKeys.validateAndSave(layout, identity.publicKey);
            replaceConsoleText(generatedPublicKey, identity.publicKey, false);
            recordOperation("SSH_CLIENT_KEY_ROTATED algorithm=ed25519 de_public_key_updated=true");
            new MaterialAlertDialogBuilder(this)
                    .setTitle(R.string.bfu_rotate_ssh_key_done_title)
                    .setMessage(R.string.bfu_rotate_ssh_key_done_message)
                    .setPositiveButton(android.R.string.ok, null)
                    .show();
        } catch (IOException e) {
            recordOperation("SSH_CLIENT_KEY_ROTATE_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_generated_key_failed,
                    e.getMessage()));
        }
    }

    private void confirmPrivateKeyFileExport() {
        if (!isUserUnlocked()) {
            DawnShellNotice.show(this, R.string.bfu_ssh_key_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_export_private_key_confirm_title)
                .setMessage(R.string.bfu_export_private_key_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_export_private_key_confirm_button,
                        (dialog, which) -> launchPrivateKeyExport())
                .show();
    }

    private void launchPrivateKeyExport() {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("application/octet-stream");
        intent.putExtra(Intent.EXTRA_TITLE, "dawnshell-ed25519");
        startActivityForResult(intent, REQUEST_EXPORT_SSH_PRIVATE_KEY);
    }

    private void confirmCopyKeyImportCommand() {
        if (!isUserUnlocked()) {
            DawnShellNotice.show(this, R.string.bfu_ssh_key_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_copy_key_import_confirm_title)
                .setMessage(R.string.bfu_copy_key_import_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_copy_key_import_confirm_button,
                        (dialog, which) -> copyKeyImportCommand())
                .show();
    }

    private void copyKeyImportCommand() {
        try {
            String command = buildKeyImportCommand(BfuSshClientKeyStore.ensure(this));
            copySshClientCommand("key_import", command,
                    R.string.bfu_key_import_command_copied);
            liveLogHandler.postDelayed(() -> clearSensitiveClipboard(command), 120_000L);
        } catch (IOException e) {
            recordOperation("SSH_CLIENT_KEY_IMPORT_COPY_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_generated_key_failed,
                    e.getMessage()));
        }
    }

    private void clearSensitiveClipboard(String expected) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null || !clipboard.hasPrimaryClip()
                || clipboard.getPrimaryClip() == null
                || clipboard.getPrimaryClip().getItemCount() == 0) return;
        CharSequence current = clipboard.getPrimaryClip().getItemAt(0).coerceToText(this);
        if (!TextUtils.equals(expected, current)) return;
        if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip();
        else clipboard.setPrimaryClip(ClipData.newPlainText("", ""));
        recordOperation("SSH_CLIENT_PRIVATE_KEY_CLIPBOARD_CLEARED timeout_seconds=120");
    }

    private String buildKeyImportCommand(BfuSshClientKeyStore.Identity identity) {
        String encoded = Base64.encodeToString(
                identity.privateKey.getBytes(java.nio.charset.StandardCharsets.US_ASCII),
                Base64.NO_WRAP);
        return "set -eu; umask 077; KEY=\"$HOME/.ssh/dawnshell-ed25519\"; "
                + "mkdir -p \"$HOME/.ssh\"; chmod 0700 \"$HOME/.ssh\"; "
                + "printf '%s' '" + encoded + "' | base64 -d > \"$KEY\"; "
                + "chmod 0600 \"$KEY\"; "
                + "printf 'Imported DawnShell client key: %s\\n' \"$KEY\"";
    }

    private static String buildSshConnectCommand() {
        return "ssh -i \"$HOME/.ssh/dawnshell-ed25519\" -p 22 "
                + "-o IdentitiesOnly=yes -o PasswordAuthentication=no "
                + "-o StrictHostKeyChecking=accept-new "
                + "-o UserKnownHostsFile=\"$HOME/.ssh/dawnshell-known_hosts\" "
                + "-o ConnectTimeout=10 debian@127.0.0.1";
    }

    private void copySshClientCommand(String operation, String command,
                                      int noticeMessage) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            DawnShellNotice.show(this, R.string.bfu_clipboard_unavailable);
            recordOperation("SSH_CLIENT_COMMAND_COPY_FAILED type=" + operation
                    + " clipboard_unavailable=true");
            return;
        }
        ClipData clip = ClipData.newPlainText("DawnShell command", command);
        if (Build.VERSION.SDK_INT >= 33) {
            PersistableBundle extras = new PersistableBundle();
            extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true);
            clip.getDescription().setExtras(extras);
        }
        clipboard.setPrimaryClip(clip);
        recordOperation("SSH_CLIENT_COMMAND_COPIED type=" + operation);
        DawnShellNotice.show(this, noticeMessage);
    }

    private void loadSettings() {
        enableBfu.setChecked(BfuPreferences.isEnabled(this));
        allowCeReadableBfu.setChecked(BfuPreferences.allowCeReadableBfu(this));
        selectCgroupPolicy(BfuPreferences.cgroupPolicy(this));
        selectDockerNetworkPolicy(BfuPreferences.dockerNetworkPolicy(this));
        dockerHostIpcCompatibility.setChecked(
                BfuPreferences.dockerHostIpcCompatibility(this));
        hardwareCodecBridge.setChecked(BfuPreferences.hardwareCodecBridge(this));
        selectUsbPassthroughMode(BfuPreferences.usbPassthroughMode(this));
        usbExclusiveDeviceIds.setText(BfuPreferences.usbExclusiveDeviceIds(this));
        refreshUsbExclusiveEditorState();
        refreshGeneratedSshIdentity(true);
        refreshRootAuthorizationStatus();
        refreshProbeStatus(false);
        refreshInstallerStatus();
        refreshSystemConfigurationStatus();
        refreshLifecycleStatus();
        refreshDockerPolicyStatus();
        refreshHardwareCodecStatus();
        settingsDirty.setVisibility(View.GONE);
    }

    private void refreshProbeStatus(boolean recordOperation) {
        String rootResult;
        try {
            rootResult = BfuRootProbe.readLastPersistentResult(this);
            if (rootResult.isEmpty()) rootResult = getString(R.string.bfu_root_probe_none);
            replaceConsoleText(rootProbeStatus,
                    getString(R.string.bfu_root_probe_status, rootResult), false);
        } catch (IOException e) {
            rootResult = getString(R.string.bfu_root_probe_read_failed, e.getMessage());
            replaceConsoleText(rootProbeStatus, rootResult, false);
        }

        String ceIsolationResult;
        try {
            ceIsolationResult = BfuCeIsolationProbe.readLastPersistentResult(this);
            if (ceIsolationResult.isEmpty()) {
                ceIsolationResult = getString(R.string.bfu_ce_isolation_probe_none);
            }
            replaceConsoleText(ceIsolationProbeStatus,
                    getString(R.string.bfu_ce_isolation_probe_status,
                            ceIsolationResult), false);
        } catch (IOException e) {
            ceIsolationResult = getString(
                    R.string.bfu_ce_isolation_probe_read_failed, e.getMessage());
            replaceConsoleText(ceIsolationProbeStatus, ceIsolationResult, false);
        }

        String rootfsResult;
        try {
            rootfsResult = BfuRootfsProbe.readLastPersistentResult(this);
            if (rootfsResult.isEmpty()) rootfsResult = getString(R.string.bfu_rootfs_probe_none);
            replaceConsoleText(rootfsProbeStatus,
                    getString(R.string.bfu_rootfs_probe_status, rootfsResult), false);
        } catch (IOException e) {
            rootfsResult = getString(R.string.bfu_rootfs_probe_read_failed, e.getMessage());
            replaceConsoleText(rootfsProbeStatus, rootfsResult, false);
        }

        String runtimeResult;
        try {
            runtimeResult = BfuDebianRuntimeProbe.readLastPersistentResult(this);
            if (runtimeResult.isEmpty()) {
                runtimeResult = getString(R.string.bfu_debian_runtime_probe_none);
            }
            replaceConsoleText(debianRuntimeProbeStatus,
                    getString(R.string.bfu_debian_runtime_probe_status, runtimeResult), false);
        } catch (IOException e) {
            runtimeResult = getString(
                    R.string.bfu_debian_runtime_probe_read_failed, e.getMessage());
            replaceConsoleText(debianRuntimeProbeStatus, runtimeResult, false);
        }

        String compactProbe = runtimeResult;
        if (compactProbe == null || compactProbe.contains(
                getString(R.string.bfu_debian_runtime_probe_none))) {
            compactProbe = rootfsResult;
        }
        replaceConsoleText(probeSummary, getString(R.string.dawnshell_probe_summary,
                compact(oneLine(compactProbe), 240)), false);

        if (recordOperation) {
            recordOperation("PROBE_RESULTS_REFRESHED root={" + oneLine(rootResult)
                    + "} ce_isolation={" + oneLine(ceIsolationResult)
                    + "} rootfs={" + oneLine(rootfsResult)
                    + "} runtime={" + oneLine(runtimeResult) + "}");
        }
    }

    private void saveAndProvision() {
        recordOperation("PROVISION_STARTED enable_bfu=" + enableBfu.isChecked()
                + " allow_ce_readable_bfu=" + allowCeReadableBfu.isChecked()
                + " usb_passthrough_mode=" + selectedUsbPassthroughMode()
                + " cgroup_policy=" + selectedCgroupPolicy()
                + " docker_network_policy=" + selectedDockerNetworkPolicy()
                + " docker_host_ipc_compatibility="
                + dockerHostIpcCompatibility.isChecked()
                + " hardware_codec_bridge=" + hardwareCodecBridge.isChecked());
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            BfuSshClientKeyStore.Identity identity = BfuSshClientKeyStore.ensure(this);
            int keyCount = BfuAuthorizedKeys.validateAndSave(layout, identity.publicKey);
            recordOperation("PROVISION_SUCCEEDED runtime=" + layout.root
                    + " authorized_key_count=" + keyCount);
            if (hardwareCodecBridge.isChecked()) {
                BfuBootService.requestHardwareCodecProbe(this);
            } else {
                HardwareCodecService.stop(this);
            }
            DawnShellNotice.show(this, getString(R.string.bfu_saved, layout.root));
        } catch (IOException | IllegalStateException e) {
            recordOperation("PROVISION_FAILED " + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_provision_failed, e.getMessage()));
        }
    }

    private void confirmRootAuthorization() {
        if (!isUserUnlocked()) {
            recordOperation("ROOT_AUTHORIZATION_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.bfu_root_authorization_requires_unlock);
            return;
        }

        int uid = Process.myUid();
        String packages = packagesForUid(uid);
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_root_authorization_confirm_title)
                .setMessage(getString(R.string.bfu_root_authorization_confirm_message,
                        Integer.toString(uid), packages))
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_root_authorization_confirm_button,
                        (dialog, which) -> requestRootAuthorization())
                .show();
    }

    private void requestRootAuthorization() {
        if (rootAuthorizationInProgress) return;
        rootAuthorizationInProgress = true;
        rootAuthorizationButton.setEnabled(false);
        replaceConsoleText(rootAuthorizationStatus,
                getString(R.string.bfu_root_authorization_waiting), true);
        recordOperation("ROOT_AUTHORIZATION_STARTED shared_uid=" + Process.myUid());
        Context applicationContext = getApplicationContext();

        rootAuthorizationExecutor.execute(() -> {
            BfuRootAuthorization.Result result = null;
            String failure = null;
            try {
                result = BfuRootAuthorization.request(applicationContext);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                failure = applicationContext.getString(
                        R.string.bfu_root_authorization_interrupted);
            } catch (IOException | IllegalStateException e) {
                failure = BfuSu.sanitize(e.getMessage());
            }

            BfuRootAuthorization.Result completedResult = result;
            String completedFailure = failure;
            liveLogHandler.post(() -> finishRootAuthorization(
                    completedResult, completedFailure));
        });
    }

    private void finishRootAuthorization(BfuRootAuthorization.Result result, String failure) {
        if (isFinishing() || isDestroyed()) return;
        rootAuthorizationInProgress = false;
        rootAuthorizationButton.setEnabled(true);
        refreshRootAuthorizationStatus();

        pendingRootAuthorizationResult = result;
        pendingRootAuthorizationFailure = failure;
        if (result != null) {
            recordOperation((result.authorizedWhileUnlocked()
                    ? "ROOT_AUTHORIZATION_SUCCEEDED " : "ROOT_AUTHORIZATION_FAILED ")
                    + result.summary());
        } else {
            recordOperation("ROOT_AUTHORIZATION_FAILED "
                    + (failure == null ? "unknown failure" : failure));
        }
        if (activityResumed) showPendingRootAuthorizationResult();
    }

    private void showPendingRootAuthorizationResult() {
        BfuRootAuthorization.Result result = pendingRootAuthorizationResult;
        String failure = pendingRootAuthorizationFailure;
        if (result == null && failure == null) return;
        pendingRootAuthorizationResult = null;
        pendingRootAuthorizationFailure = null;

        if (result != null && result.authorizedWhileUnlocked()) {
            new MaterialAlertDialogBuilder(this)
                    .setTitle(R.string.bfu_root_authorization_verified_title)
                    .setMessage(getString(R.string.bfu_root_authorization_verified_message,
                            Integer.toString(result.appUid)))
                    .setPositiveButton(android.R.string.ok, null)
                    .show();
            return;
        }

        String reason = failure;
        if (reason == null && result != null) reason = result.summary();
        if (reason == null) reason = getString(R.string.bfu_root_authorization_unknown_failure);
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_root_authorization_failed_title)
                .setMessage(getString(R.string.bfu_root_authorization_failed_message, reason))
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }

    private void refreshRootAuthorizationStatus() {
        if (rootAuthorizationStatus == null || rootAuthorizationInProgress) return;
        try {
            String result = BfuRootAuthorization.readLastPersistentResult(this);
            if (result.isEmpty()) result = getString(R.string.bfu_root_authorization_none);
            replaceConsoleText(rootAuthorizationStatus, getString(
                    R.string.bfu_root_authorization_status, result), true);
        } catch (IOException e) {
            replaceConsoleText(rootAuthorizationStatus, getString(
                    R.string.bfu_root_authorization_read_failed, e.getMessage()), true);
        }
    }

    private String packagesForUid(int uid) {
        String[] packages = getPackageManager().getPackagesForUid(uid);
        if (packages == null || packages.length == 0) return getPackageName();
        Arrays.sort(packages);
        StringBuilder result = new StringBuilder();
        for (String packageName : packages) {
            if (result.length() > 0) result.append("\n");
            result.append("• ").append(packageName);
        }
        return result.toString();
    }

    private void confirmDebianInstall() {
        if (!enableBfu.isChecked()) {
            recordOperation("DEBIAN_INSTALL_REJECTED bfu_disabled=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_enabled);
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DEBIAN_INSTALL_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_unlock);
            return;
        }

        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_install_confirm_title)
                .setMessage(R.string.bfu_install_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_install_confirm_button,
                        (dialog, which) -> startDebianInstall())
                .show();
    }

    private void confirmDebianRootfsRemoval() {
        if (!isUserUnlocked()) {
            recordOperation("DEBIAN_ROOTFS_REMOVE_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.bfu_remove_rootfs_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_remove_rootfs_confirm_title)
                .setMessage(R.string.bfu_remove_rootfs_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_remove_rootfs_continue,
                        (dialog, which) -> confirmTypedDebianRootfsRemoval())
                .show();
    }

    private void confirmTypedDebianRootfsRemoval() {
        View confirmationView = getLayoutInflater().inflate(
                R.layout.dialog_delete_rootfs, null, false);
        EditText confirmation = confirmationView.findViewById(
                R.id.delete_rootfs_confirmation);
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_remove_rootfs_final_title)
                .setMessage(R.string.bfu_remove_rootfs_final_message)
                .setView(confirmationView)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_remove_rootfs_button,
                        (dialog, which) -> {
                            String value = confirmation.getText().toString();
                            confirmation.setText("");
                            if (!"DELETE".equals(value)) {
                                DawnShellNotice.show(this, R.string.bfu_remove_rootfs_confirmation_mismatch);
                                return;
                            }
                            BfuBootService.requestDebianRootfsRemoval(this);
                            recordOperation("DEBIAN_ROOTFS_REMOVE_REQUESTED "
                                    + "root=/data/local/debian");
                            DawnShellNotice.show(this, R.string.bfu_remove_rootfs_requested);
                        })
                .show();
    }

    private void startDebianInstall() {
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            BfuBootService.requestDebianRootfsInstall(this);
            recordOperation("DEBIAN_INSTALL_REQUESTED suite=trixie architecture="
                    + layout.architecture.debianArchitecture
                    + " android_abi=" + layout.architecture.androidAbi);
            DawnShellNotice.show(this, R.string.bfu_install_requested);
            refreshInstallerStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_INSTALL_REQUEST_FAILED " + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_provision_failed, e.getMessage()));
        }
    }

    private void confirmSystemConfiguration() {
        if (!enableBfu.isChecked()) {
            recordOperation("DEBIAN_CONFIG_REJECTED bfu_disabled=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_enabled);
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DEBIAN_CONFIG_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.bfu_system_config_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_system_config_confirm_title)
                .setMessage(R.string.bfu_system_config_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_system_config_confirm_button,
                        (dialog, which) -> startSystemConfiguration())
                .show();
    }

    private void startSystemConfiguration() {
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            BfuSshClientKeyStore.Identity identity = BfuSshClientKeyStore.ensure(this);
            int keyCount = BfuAuthorizedKeys.validateAndSave(layout, identity.publicKey);
            BfuBootService.requestDebianSystemConfiguration(this);
            recordOperation("DEBIAN_CONFIG_REQUESTED suite=trixie ssh_user=debian"
                    + " ssh_port=22 authorized_key_count=" + keyCount);
            DawnShellNotice.show(this, R.string.bfu_system_config_requested);
            refreshSystemConfigurationStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_CONFIG_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(
                    R.string.bfu_system_config_request_failed, e.getMessage()));
        }
    }

    private void confirmDockerNetworkPolicy() {
        if (!enableBfu.isChecked()) {
            recordOperation("DOCKER_POLICY_REJECTED bfu_disabled=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_enabled);
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DOCKER_POLICY_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.dawnshell_docker_policy_requires_unlock);
            return;
        }
        String policy = selectedDockerNetworkPolicy();
        int message = BfuPreferences.DOCKER_HOST_ONLY.equals(policy)
                ? R.string.dawnshell_docker_policy_confirm_host
                : R.string.dawnshell_docker_policy_confirm_bridge;
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dawnshell_docker_policy_confirm_title)
                .setMessage(message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.dawnshell_docker_policy_confirm_button,
                        (dialog, which) -> startDockerNetworkPolicy())
                .show();
    }

    private void confirmHostUsbPolicy() {
        if (!enableBfu.isChecked()) {
            recordOperation("HOST_USB_POLICY_REJECTED bfu_disabled=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_enabled);
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("HOST_USB_POLICY_REJECTED user_locked=true");
            DawnShellNotice.show(this, R.string.dawnshell_host_usb_requires_unlock);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dawnshell_host_usb_confirm_title)
                .setMessage(R.string.dawnshell_host_usb_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.dawnshell_apply_host_usb_policy,
                        (dialog, which) -> startHostUsbPolicy())
                .show();
    }

    private void startHostUsbPolicy() {
        try {
            savePreferences();
            BfuRuntime.provision(this);
            BfuBootService.requestHostUsbPolicy(this);
            recordOperation("HOST_USB_POLICY_REQUESTED mode="
                    + selectedUsbPassthroughMode()
                    + " device_ids="
                    + BfuPreferences.usbExclusiveDeviceIds(this));
            DawnShellNotice.show(this, R.string.dawnshell_host_usb_policy_requested);
        } catch (IOException | IllegalStateException e) {
            recordOperation("HOST_USB_POLICY_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_provision_failed,
                    e.getMessage()));
        }
    }

    private void applyHardwareCodecSetting() {
        if (hardwareCodecBridge.isChecked() && !enableBfu.isChecked()) {
            recordOperation("HARDWARE_CODEC_REJECTED bfu_disabled=true");
            DawnShellNotice.show(this, R.string.dawnshell_codec_requires_bfu);
            return;
        }
        try {
            savePreferences();
            if (hardwareCodecBridge.isChecked()) {
                BfuBootService.requestHardwareCodecProbe(this);
                recordOperation("HARDWARE_CODEC_PROBE_REQUESTED user_unlocked="
                        + isUserUnlocked());
                DawnShellNotice.show(this, R.string.dawnshell_codec_probe_requested);
            } else {
                HardwareCodecService.stop(this);
                recordOperation("HARDWARE_CODEC_SERVICE_STOP_REQUESTED");
                DawnShellNotice.show(this, R.string.dawnshell_codec_disabled);
            }
            refreshHardwareCodecStatus();
        } catch (IllegalStateException e) {
            recordOperation("HARDWARE_CODEC_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_provision_failed,
                    e.getMessage()));
        }
    }

    private void runHardwareCodecSelfTest() {
        runHardwareCodecFileSelfTest();
    }

    private void runHardwareCodecPerformanceTest() {
        runHardwareCodecTest(true);
    }

    private void showFfmpegCodecGuide() {
        // Upstream MediaCodec spellings come first because most callers reach
        // for them before the DawnShell-specific tool names.
        showCodecGuideText(R.string.dawnshell_codec_ffmpeg_guide_title,
                getString(R.string.dawnshell_codec_mediacodec_syntax_body)
                        + getString(R.string.dawnshell_codec_ffmpeg_guide_body));
    }

    private void showLiveCodecGuide() {
        showCodecGuide(R.string.dawnshell_codec_live_guide_title,
                R.string.dawnshell_codec_live_guide_body);
    }

    private void showCodecGuide(int titleResource, int bodyResource) {
        showCodecGuideText(titleResource, getString(bodyResource));
    }

    private void showCodecGuideText(int titleResource, String guide) {
        TextView content = new AppCompatTextView(this);
        content.setText(guide);
        content.setTextIsSelectable(true);
        content.setTypeface(Typeface.MONOSPACE);
        content.setTextSize(13f);
        content.setTextColor(MaterialColors.getColor(content,
                com.google.android.material.R.attr.colorOnSurface));
        content.setPadding(dp(20), dp(8), dp(20), dp(20));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(content, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        new MaterialAlertDialogBuilder(this)
                .setTitle(titleResource)
                .setView(scroll)
                .setNegativeButton(R.string.dawnshell_codec_ffmpeg_guide_close, null)
                .setPositiveButton(R.string.dawnshell_codec_ffmpeg_guide_copy,
                        (dialog, which) -> copyFfmpegCodecGuide(guide))
                .show();
    }

    private void copyFfmpegCodecGuide(String guide) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            DawnShellNotice.show(this, R.string.bfu_clipboard_unavailable);
            return;
        }
        clipboard.setPrimaryClip(ClipData.newPlainText(
                "DawnShell FFmpeg guide", guide));
        recordOperation("HARDWARE_CODEC_FFMPEG_GUIDE_COPIED");
        DawnShellNotice.show(this, R.string.dawnshell_codec_ffmpeg_guide_copied);
    }

    private void runHardwareCodecFileSelfTest() {
        if (codecSelfTestInProgress) return;
        if (!hardwareCodecBridge.isChecked()
                || !BfuPreferences.hardwareCodecBridge(this)) {
            DawnShellNotice.show(this, R.string.dawnshell_codec_self_test_requires_setup);
            return;
        }
        codecSelfTestInProgress = true;
        hardwareCodecSelfTestButton.setEnabled(false);
        hardwareCodecPerformanceTestButton.setEnabled(false);
        DawnShellNotice.show(this, R.string.dawnshell_codec_self_test_started);
        codecSelfTestExecutor.execute(() -> {
            boolean passed = false;
            long token = -1L;
            String output = "FAILED stage=debian_download";
            try {
                BfuRuntime.Layout layout = BfuRuntime.provision(this);
                File destination = HardwareCodecFileSelfTest.inputFile(this);
                String rootTemporary = BfuRootfsProbe.ROOTFS_PATH
                        + "/var/tmp/dawnshell-codec-file-self-test.mp4";
                String debianScript = "set -eu; "
                        + "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; "
                        + "if ! command -v wget >/dev/null 2>&1; then "
                        + "apt-get -o Acquire::Retries=3 update; "
                        + "DEBIAN_FRONTEND=noninteractive apt-get install -y wget ca-certificates; "
                        + "fi; "
                        + "wget --timeout=30 --tries=3 -O /var/tmp/dawnshell-codec-file-self-test.mp4 "
                        + BfuSu.shellQuote(HardwareCodecFileSelfTest.TEST_URL);
                String toolbox = BfuSu.shellQuote(layout.toolboxBinary.getAbsolutePath());
                String staged = destination.getAbsolutePath() + ".new";
                String command = toolbox + " chroot "
                        + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                        + " /bin/sh -c " + BfuSu.shellQuote(debianScript)
                        + " && " + toolbox + " cp " + BfuSu.shellQuote(rootTemporary)
                        + " " + BfuSu.shellQuote(staged)
                        + " && " + toolbox + " chmod 0600 " + BfuSu.shellQuote(staged)
                        + " && " + toolbox + " chown "
                        + android.os.Process.myUid() + ":" + android.os.Process.myUid()
                        + " " + BfuSu.shellQuote(staged)
                        + " && " + toolbox + " mv " + BfuSu.shellQuote(staged)
                        + " " + BfuSu.shellQuote(destination.getAbsolutePath())
                        + " && " + toolbox + " rm -f " + BfuSu.shellQuote(rootTemporary);
                BfuSu.Result download = BfuSu.runRaw(command, 240_000L);
                if (!download.exitedSuccessfully()) {
                    throw new IOException("Debian wget failed: "
                            + BfuSu.sanitizeTail(download.output));
                }
                token = HardwareCodecService.requestFileSelfTest(this);
                output = "FAILED token=" + token + " timeout=true";
                long deadline = android.os.SystemClock.elapsedRealtime() + 90_000L;
                while (android.os.SystemClock.elapsedRealtime() < deadline) {
                    Thread.sleep(500L);
                    String status = HardwareCodecFileSelfTest.readStatus(this);
                    if (!status.contains("token=" + token)) continue;
                    if (status.startsWith("PASSED ") || status.startsWith("FAILED ")) {
                        output = status;
                        passed = status.startsWith("PASSED ");
                        break;
                    }
                }
            } catch (IOException e) {
                output = "FAILED token=" + token + " error="
                        + BfuSu.sanitize(e.getMessage());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                output = "FAILED token=" + token + " interrupted=true";
            }
            final boolean finalPassed = passed;
            final String finalOutput = output;
            HardwareCodecProbe.recordBrokerEvent(this,
                    "SELF_TEST_" + finalOutput);
            try {
                BfuOperationLog.append(this, "HARDWARE_CODEC_FILE_SELF_TEST_"
                        + finalOutput);
            } catch (IOException e) {
                Log.w(TAG, "Could not persist file-backed codec self-test", e);
            }
            runOnUiThread(() -> {
                codecSelfTestInProgress = false;
                hardwareCodecSelfTestButton.setEnabled(true);
                hardwareCodecPerformanceTestButton.setEnabled(true);
                refreshHardwareCodecStatus();
                DawnShellNotice.show(this, getString(finalPassed
                        ? R.string.dawnshell_codec_self_test_passed
                        : R.string.dawnshell_codec_self_test_failed));
            });
        });
    }

    private void confirmHardwareCodecLongRun() {
        if (!hardwareCodecBridge.isChecked()
                || !BfuPreferences.hardwareCodecBridge(this)) {
            DawnShellNotice.show(this, R.string.dawnshell_codec_self_test_requires_setup);
            return;
        }
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.dawnshell_codec_long_run_confirm_title)
                .setMessage(R.string.dawnshell_codec_long_run_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.dawnshell_codec_long_run_start,
                        (dialog, which) -> runHardwareCodecLongRun(
                                HardwareCodecLongRun.Operation.START))
                .show();
    }

    private void runHardwareCodecLongRun(HardwareCodecLongRun.Operation operation) {
        if (codecControlInProgress) return;
        if (operation == HardwareCodecLongRun.Operation.START
                && (!hardwareCodecBridge.isChecked()
                || !BfuPreferences.hardwareCodecBridge(this))) {
            DawnShellNotice.show(this, R.string.dawnshell_codec_self_test_requires_setup);
            return;
        }
        final BfuRuntime.Layout layout;
        try {
            layout = BfuRuntime.provision(this);
        } catch (IOException | IllegalStateException e) {
            HardwareCodecLongRun.recordFailure(this, operation, e.getMessage());
            DawnShellNotice.show(this, getString(R.string.dawnshell_codec_long_run_failed,
                    BfuSu.sanitize(e.getMessage())));
            return;
        }
        if (operation == HardwareCodecLongRun.Operation.START) {
            HardwareCodecService.ensureStarted(this, false);
        }
        codecControlInProgress = true;
        hardwareCodecLongRunStartButton.setEnabled(false);
        hardwareCodecLongRunStopButton.setEnabled(false);
        DawnShellNotice.show(this, operation == HardwareCodecLongRun.Operation.START
                        ? R.string.dawnshell_codec_long_run_start_requested
                        : R.string.dawnshell_codec_long_run_stop_requested);
        codecControlExecutor.execute(() -> {
            boolean passed = false;
            String output;
            try {
                BfuSu.Result result = HardwareCodecLongRun.run(this, layout, operation);
                passed = result.exitedSuccessfully();
                output = "exit=" + result.exitCode + " timeout=" + result.timedOut
                        + " output=" + result.output;
            } catch (IOException | RuntimeException e) {
                output = BfuSu.sanitize(e.getMessage());
                HardwareCodecLongRun.recordFailure(this, operation, output);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                output = "interrupted";
                HardwareCodecLongRun.recordFailure(this, operation, output);
            }
            final boolean successful = passed;
            final String summary = BfuSu.sanitize(output);
            try {
                BfuOperationLog.append(this, "HARDWARE_CODEC_LONG_RUN_"
                        + operation.name() + "_"
                        + (successful ? "SUCCEEDED " : "FAILED ") + summary);
            } catch (IOException e) {
                Log.w(TAG, "Could not persist hardware codec long-run operation", e);
            }
            runOnUiThread(() -> {
                codecControlInProgress = false;
                hardwareCodecLongRunStartButton.setEnabled(true);
                hardwareCodecLongRunStopButton.setEnabled(true);
                refreshHardwareCodecLongRunStatus();
                String message = successful
                        ? getString(R.string.dawnshell_codec_long_run_control_succeeded)
                        : getString(R.string.dawnshell_codec_long_run_failed, summary);
                DawnShellNotice.show(this, message);
            });
        });
    }

    private void runHardwareCodecTest(boolean performance) {
        if (codecSelfTestInProgress) return;
        if (!hardwareCodecBridge.isChecked()
                || !BfuPreferences.hardwareCodecBridge(this)) {
            DawnShellNotice.show(this, R.string.dawnshell_codec_self_test_requires_setup);
            return;
        }
        final BfuRuntime.Layout codecLayout;
        final String chrootTool;
        try {
            codecLayout = BfuRuntime.provision(this);
            chrootTool = codecLayout.toolboxBinary.getAbsolutePath();
        } catch (IOException | IllegalStateException e) {
            String detail = BfuSu.sanitize(e.getMessage());
            HardwareCodecProbe.recordBrokerEvent(this,
                    (performance ? "PERFORMANCE_TEST_" : "SELF_TEST_")
                            + "FAILED runtime_provisioning " + detail);
            recordOperation("HARDWARE_CODEC_"
                    + (performance ? "PERFORMANCE_TEST_" : "SELF_TEST_")
                    + "FAILED runtime_provisioning " + detail);
            DawnShellNotice.show(this, getString(performance
                            ? R.string.dawnshell_codec_performance_test_failed
                            : R.string.dawnshell_codec_self_test_failed));
            refreshHardwareCodecStatus();
            return;
        }
        codecSelfTestInProgress = true;
        hardwareCodecSelfTestButton.setEnabled(false);
        hardwareCodecPerformanceTestButton.setEnabled(false);
        DawnShellNotice.show(this, performance
                        ? R.string.dawnshell_codec_performance_test_started
                        : R.string.dawnshell_codec_self_test_started);
        HardwareCodecService.ensureStarted(this, false);
        codecSelfTestExecutor.execute(() -> {
            String output;
            boolean passed = false;
            boolean missingTools = false;
            try {
                Thread.sleep(500L);
                String command = BfuSu.shellQuote(chrootTool) + " chroot "
                        + BfuSu.shellQuote(BfuRootfsProbe.ROOTFS_PATH)
                        + (performance
                        ? " /usr/local/bin/dawnshell-codec-performance-test"
                        : " /usr/local/bin/dawnshell-codec-self-test");
                BfuSu.Result result = performance
                        ? BfuSu.runRaw(command, 600_000L)
                        : BfuSu.run(command, 30_000L);
                output = "command=" + result.command + " exit=" + result.exitCode
                        + " timeout=" + result.timedOut + " output=" + result.output;
                passed = result.exitedSuccessfully();
                // Exit 127 means the configurator never installed the codec
                // tools, which is a setup step rather than a codec failure.
                missingTools = !passed && result.exitCode == 127
                        && result.output != null
                        && result.output.contains("dawnshell-codec");
                if (passed && performance) {
                    output += "\n" + HardwareCodecRecoveryTest.run(this, codecLayout);
                }
            } catch (IOException e) {
                passed = false;
                output = BfuSu.sanitizeTail(e.getMessage());
            } catch (InterruptedException e) {
                passed = false;
                Thread.currentThread().interrupt();
                output = "interrupted";
            } catch (RuntimeException e) {
                passed = false;
                output = BfuSu.sanitize(e.getMessage());
            }
            final boolean finalPassed = passed;
            final boolean finalMissingTools = missingTools;
            final String finalOutput = performance
                    ? BfuSu.sanitizeTail(output) : BfuSu.sanitize(output);
            HardwareCodecProbe.recordBrokerEvent(this,
                    (performance ? "PERFORMANCE_TEST_" : "SELF_TEST_")
                            + (finalPassed ? "PASSED "
                            : finalMissingTools
                            ? "FAILED tools_missing run_debian_configuration "
                            : "FAILED ")
                            + finalOutput);
            try {
                BfuOperationLog.append(this, "HARDWARE_CODEC_"
                        + (performance ? "PERFORMANCE_TEST_" : "SELF_TEST_")
                        + (finalPassed ? "PASSED " : "FAILED ") + finalOutput);
            } catch (IOException e) {
                Log.w(TAG, "Could not persist hardware codec self-test operation", e);
            }
            runOnUiThread(() -> {
                codecSelfTestInProgress = false;
                hardwareCodecSelfTestButton.setEnabled(true);
                hardwareCodecPerformanceTestButton.setEnabled(true);
                refreshHardwareCodecStatus();
                int passedText = performance
                        ? R.string.dawnshell_codec_performance_test_passed
                        : R.string.dawnshell_codec_self_test_passed;
                int failedText = performance
                        ? R.string.dawnshell_codec_performance_test_failed
                        : R.string.dawnshell_codec_self_test_failed;
                if (finalMissingTools) {
                    failedText = R.string.dawnshell_codec_tools_missing;
                }
                // The notice reports the outcome only; the full codec output
                // stays in the hardware codec log, where it can be copied.
                DawnShellNotice.show(this, getString(
                                finalPassed ? passedText : failedText));
            });
        });
    }

    private void startDockerNetworkPolicy() {
        try {
            savePreferences();
            BfuRuntime.provision(this);
            String policy = selectedDockerNetworkPolicy();
            BfuBootService.requestDockerNetworkPolicy(this);
            recordOperation("DOCKER_POLICY_REQUESTED policy=" + policy
                    + " android_network_namespace=shared"
                    + " host_ipc_compatibility="
                    + dockerHostIpcCompatibility.isChecked());
            DawnShellNotice.show(this, R.string.dawnshell_docker_policy_requested);
            refreshDockerPolicyStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DOCKER_POLICY_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(R.string.bfu_provision_failed,
                    e.getMessage()));
        }
    }

    private void requestLifecycle(DebianLauncher.Operation operation) {
        if ((operation == DebianLauncher.Operation.START
                || operation == DebianLauncher.Operation.RESTART)
                && !enableBfu.isChecked()) {
            recordOperation("DEBIAN_LIFECYCLE_REJECTED operation="
                    + operation.name().toLowerCase(java.util.Locale.US)
                    + " bfu_disabled=true");
            DawnShellNotice.show(this, R.string.bfu_install_requires_enabled);
            return;
        }
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.provision(this);
            BfuBootService.requestDebianLifecycle(this, operation);
            recordOperation("DEBIAN_LIFECYCLE_REQUESTED operation="
                    + operation.name().toLowerCase(java.util.Locale.US));
            DawnShellNotice.show(this, getString(R.string.bfu_lifecycle_requested,
                    operation.name()));
            refreshLifecycleStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_LIFECYCLE_REQUEST_FAILED operation="
                    + operation.name() + " " + BfuSu.sanitize(e.getMessage()));
            DawnShellNotice.show(this, getString(
                    R.string.bfu_lifecycle_request_failed, e.getMessage()));
        }
    }

    private void savePreferences() {
        String usbMode = selectedUsbPassthroughMode();
        String usbDeviceIds;
        try {
            usbDeviceIds = BfuPreferences.normalizeUsbExclusiveDeviceIds(
                    usbExclusiveDeviceIds.getText().toString());
        } catch (IllegalArgumentException e) {
            usbExclusiveDeviceIdsLayout.setError(
                    getString(R.string.dawnshell_usb_exclusive_ids_invalid));
            throw new IllegalStateException(
                    getString(R.string.dawnshell_usb_exclusive_ids_invalid));
        }
        if (BfuPreferences.USB_PASSTHROUGH_EXCLUSIVE.equals(usbMode)
                && usbDeviceIds.isEmpty()) {
            usbExclusiveDeviceIdsLayout.setError(
                    getString(R.string.dawnshell_usb_exclusive_ids_required));
            throw new IllegalStateException(
                    getString(R.string.dawnshell_usb_exclusive_ids_required));
        }
        BfuPreferences.save(this, enableBfu.isChecked(),
                allowCeReadableBfu.isChecked(), selectedCgroupPolicy(),
                 selectedDockerNetworkPolicy(),
                 dockerHostIpcCompatibility.isChecked(), usbMode, usbDeviceIds,
                 hardwareCodecBridge.isChecked());
        usbExclusiveDeviceIdsLayout.setError(null);
        if (settingsDirty != null) settingsDirty.setVisibility(View.GONE);
    }

    private void selectUsbPassthroughMode(String mode) {
        int id = R.id.usb_passthrough_off;
        if (BfuPreferences.USB_PASSTHROUGH_DIRECT.equals(mode)) {
            id = R.id.usb_passthrough_direct;
        } else if (BfuPreferences.USB_PASSTHROUGH_EXCLUSIVE.equals(mode)) {
            id = R.id.usb_passthrough_exclusive;
        }
        usbPassthroughGroup.check(id);
    }

    private String selectedUsbPassthroughMode() {
        int id = usbPassthroughGroup.getCheckedRadioButtonId();
        if (id == R.id.usb_passthrough_direct) {
            return BfuPreferences.USB_PASSTHROUGH_DIRECT;
        }
        if (id == R.id.usb_passthrough_exclusive) {
            return BfuPreferences.USB_PASSTHROUGH_EXCLUSIVE;
        }
        return BfuPreferences.USB_PASSTHROUGH_OFF;
    }

    private void refreshUsbExclusiveEditorState() {
        boolean exclusive = BfuPreferences.USB_PASSTHROUGH_EXCLUSIVE.equals(
                selectedUsbPassthroughMode());
        usbExclusiveDeviceIdsLayout.setEnabled(exclusive);
        if (!exclusive) usbExclusiveDeviceIdsLayout.setError(null);
    }

    private void selectCgroupPolicy(String policy) {
        int id = R.id.cgroup_policy_auto;
        if (BfuPreferences.CGROUP_V2.equals(policy)) id = R.id.cgroup_policy_v2;
        else if (BfuPreferences.CGROUP_V1.equals(policy)) id = R.id.cgroup_policy_v1;
        cgroupPolicyGroup.check(id);
    }

    private String selectedCgroupPolicy() {
        int id = cgroupPolicyGroup.getCheckedRadioButtonId();
        if (id == R.id.cgroup_policy_v2) return BfuPreferences.CGROUP_V2;
        if (id == R.id.cgroup_policy_v1) return BfuPreferences.CGROUP_V1;
        return BfuPreferences.CGROUP_AUTO;
    }

    private void selectDockerNetworkPolicy(String policy) {
        int id = R.id.docker_policy_host;
        if (BfuPreferences.DOCKER_AUTO_BRIDGE.equals(policy)) {
            id = R.id.docker_policy_auto;
        } else if (BfuPreferences.DOCKER_NATIVE_NFT_BRIDGE.equals(policy)) {
            id = R.id.docker_policy_nft;
        } else if (BfuPreferences.DOCKER_IPTABLES_NFT_BRIDGE.equals(policy)) {
            id = R.id.docker_policy_iptables_nft;
        } else if (BfuPreferences.DOCKER_LEGACY_BRIDGE.equals(policy)) {
            id = R.id.docker_policy_legacy;
        }
        dockerNetworkPolicyGroup.check(id);
    }

    private String selectedDockerNetworkPolicy() {
        int id = dockerNetworkPolicyGroup.getCheckedRadioButtonId();
        if (id == R.id.docker_policy_auto) return BfuPreferences.DOCKER_AUTO_BRIDGE;
        if (id == R.id.docker_policy_nft) {
            return BfuPreferences.DOCKER_NATIVE_NFT_BRIDGE;
        }
        if (id == R.id.docker_policy_iptables_nft) {
            return BfuPreferences.DOCKER_IPTABLES_NFT_BRIDGE;
        }
        if (id == R.id.docker_policy_legacy) return BfuPreferences.DOCKER_LEGACY_BRIDGE;
        return BfuPreferences.DOCKER_HOST_ONLY;
    }

    private void updateDebianPassword(String account, EditText passwordEditor,
                                      EditText confirmationEditor) {
        if (!isUserUnlocked()) {
            DawnShellNotice.show(this, R.string.bfu_password_requires_unlock);
            recordOperation("DEBIAN_PASSWORD_REJECTED account=" + account
                    + " user_locked=true");
            return;
        }
        if (passwordUpdateInProgress) {
            DawnShellNotice.show(this, R.string.bfu_password_busy);
            return;
        }

        char[] password = new char[passwordEditor.length()];
        char[] confirmation = new char[confirmationEditor.length()];
        passwordEditor.getText().getChars(0, password.length, password, 0);
        confirmationEditor.getText().getChars(0, confirmation.length, confirmation, 0);
        passwordEditor.setText("");
        confirmationEditor.setText("");
        if (!Arrays.equals(password, confirmation)) {
            Arrays.fill(password, '\0');
            Arrays.fill(confirmation, '\0');
            DawnShellNotice.show(this, R.string.bfu_password_mismatch);
            recordOperation("DEBIAN_PASSWORD_REJECTED account=" + account
                    + " confirmation_mismatch=true");
            return;
        }
        Arrays.fill(confirmation, '\0');

        passwordUpdateInProgress = true;
        rootPasswordButton.setEnabled(false);
        debianPasswordButton.setEnabled(false);
        Context applicationContext = getApplicationContext();
        passwordExecutor.execute(() -> {
            DebianPasswordManager.Result result = null;
            String failure = null;
            try {
                result = DebianPasswordManager.update(
                        applicationContext, account, password);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                failure = "interrupted";
                Arrays.fill(password, '\0');
            } catch (RuntimeException e) {
                failure = BfuSu.sanitize(e.getMessage());
                Arrays.fill(password, '\0');
            }
            DebianPasswordManager.Result finalResult = result;
            String finalFailure = failure;
            runOnUiThread(() -> finishPasswordUpdate(
                    account, finalResult, finalFailure));
        });
    }

    private void finishPasswordUpdate(String account,
                                      DebianPasswordManager.Result result,
                                      String failure) {
        passwordUpdateInProgress = false;
        rootPasswordButton.setEnabled(true);
        debianPasswordButton.setEnabled(true);
        if (result != null && result.succeeded()) {
            recordOperation("DEBIAN_PASSWORD_UPDATED account=" + account
                    + " command=" + result.command + " exit=0 timeout=false");
            DawnShellNotice.show(this, getString(
                    R.string.bfu_password_updated, account));
        } else {
            String safeFailure = result == null
                    ? (failure == null ? "unknown failure" : failure)
                    : result.summary();
            recordOperation("DEBIAN_PASSWORD_FAILED account=" + account
                    + " " + safeFailure);
            DawnShellNotice.show(this, getString(
                    R.string.bfu_password_failed, account, safeFailure));
        }
    }

    private void confirmStopDebian() {
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_stop_confirm_title)
                .setMessage(R.string.bfu_stop_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_stop_confirm_button,
                        (dialog, which) -> requestLifecycle(
                                DebianLauncher.Operation.STOP))
                .show();
    }

    private void confirmRestartDebian() {
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.bfu_restart_confirm_title)
                .setMessage(R.string.bfu_restart_confirm_message)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.bfu_restart_confirm_button,
                        (dialog, which) -> requestLifecycle(
                                DebianLauncher.Operation.RESTART))
                .show();
    }

    private void refreshSystemConfigurationStatus() {
        if (systemConfigStatus == null) return;
        try {
            String status = DebianSystemProvisioner.readStatus(this);
            if (status.isEmpty()) status = getString(R.string.bfu_system_config_status_none);
            replaceConsoleText(systemConfigStatus,
                    getString(R.string.bfu_system_config_status, compact(status, 360)), false);
        } catch (IOException e) {
            replaceConsoleText(systemConfigStatus, getString(
                    R.string.bfu_system_config_status_failed, e.getMessage()), false);
        }
    }

    private void refreshLifecycleStatus() {
        if (lifecycleStatus == null) return;
        try {
            String status = DebianLauncher.readStatus(this);
            if (status.isEmpty()) status = getString(R.string.bfu_lifecycle_status_none);
            replaceConsoleText(lifecycleStatus,
                    getString(R.string.bfu_lifecycle_status, compact(status, 420)), false);
        } catch (IOException e) {
            replaceConsoleText(lifecycleStatus, getString(
                    R.string.bfu_lifecycle_status_failed, e.getMessage()), false);
        }
    }

    private void refreshDockerPolicyStatus() {
        if (dockerPolicyStatus == null) return;
        try {
            String status = DockerNetworkProvisioner.readStatus(this);
            if (status.isEmpty()) {
                status = getString(R.string.dawnshell_docker_policy_status_none);
            }
            replaceConsoleText(dockerPolicyStatus, getString(
                    R.string.dawnshell_docker_policy_status,
                    compact(status, 420)), false);
        } catch (IOException e) {
            replaceConsoleText(dockerPolicyStatus, getString(
                    R.string.dawnshell_docker_policy_status_failed,
                    e.getMessage()), false);
        }
    }

    private void refreshHardwareCodecStatus() {
        if (hardwareCodecStatus == null) return;
        try {
            String status = HardwareCodecProbe.readStatus(this);
            if (status.isEmpty()) {
                status = getString(R.string.dawnshell_codec_status_none);
            }
            String broker = HardwareCodecProbe.readBrokerStatus(this);
            if (!broker.isEmpty()) status = status + "\n" + broker;
            replaceConsoleText(hardwareCodecStatus, getString(
                    R.string.dawnshell_codec_status, compact(status, 520)), false);
        } catch (IOException | RuntimeException e) {
            replaceConsoleText(hardwareCodecStatus, getString(
                    R.string.dawnshell_codec_status_failed,
                    BfuSu.sanitize(e.getMessage())), false);
        }
    }

    private void refreshHardwareCodecLongRunStatus() {
        if (hardwareCodecLongRunStatus == null) return;
        try {
            String status = HardwareCodecLongRun.readStatus(this);
            if (status.isEmpty()) {
                status = getString(R.string.dawnshell_codec_long_run_status_none);
            }
            replaceConsoleText(hardwareCodecLongRunStatus, getString(
                    R.string.dawnshell_codec_long_run_status,
                    compact(status, 520)), false);
        } catch (IOException | RuntimeException e) {
            replaceConsoleText(hardwareCodecLongRunStatus, getString(
                    R.string.dawnshell_codec_long_run_status_failed,
                    BfuSu.sanitize(e.getMessage())), false);
        }
    }

    private void refreshInstallerStatus() {
        if (installStatus == null) return;

        try {
            String status = DebianRootfsInstaller.readStatus(this);
            if (status.isEmpty()) status = getString(R.string.bfu_debian_install_status_none);
            replaceConsoleText(installStatus,
                    getString(R.string.bfu_debian_install_status,
                            compact(status, 360)), false);
        } catch (IOException e) {
            replaceConsoleText(installStatus,
                    getString(R.string.bfu_debian_install_status_failed, e.getMessage()),
                    false);
        }
    }

    private void refreshOperationLog() {
        if (operationLog == null) return;
        try {
            String log = BfuOperationLog.readTail(this);
            if (log.isEmpty()) log = getString(R.string.bfu_operation_log_none);
            if (!log.equals(lastDisplayedOperationLog)) {
                if (hasConsoleSelection(operationLog)
                        || !isConsoleAtBottom(operationLog, lastDisplayedOperationLog)) return;
                lastDisplayedOperationLog = log;
                operationLog.setText(log);
                scrollConsoleToBottom(operationLog);
            }
        } catch (IOException e) {
            replaceConsoleText(operationLog,
                    getString(R.string.bfu_operation_log_failed, e.getMessage()), true);
        }
    }

    private void recordOperation(String message) {
        try {
            BfuOperationLog.append(this, message);
        } catch (IOException e) {
            Log.e(TAG, "Failed to append BFU UI operation log", e);
        }
    }

    private void replaceConsoleText(TextView console, String value, boolean followBottom) {
        if (console == null || TextUtils.equals(console.getText(), value)) return;
        console.setText(value);
    }

    private void scrollConsoleToBottom(TextView console) {
        console.post(() -> {
            if (console.getLayout() == null) return;
            int scroll = console.getLayout().getLineTop(console.getLineCount())
                    - console.getHeight() + console.getPaddingBottom();
            console.scrollTo(0, Math.max(0, scroll));
        });
    }

    private static boolean hasConsoleSelection(TextView console) {
        int start = console.getSelectionStart();
        int end = console.getSelectionEnd();
        return start >= 0 && end >= 0 && start != end;
    }

    private boolean isConsoleAtBottom(TextView console, String displayedValue) {
        if (displayedValue.isEmpty() || console.getLayout() == null) return true;
        int contentBottom = console.getLayout().getLineTop(console.getLineCount());
        int visibleBottom = console.getScrollY() + console.getHeight()
                - console.getPaddingBottom();
        int tolerance = dp(24);
        return visibleBottom >= contentBottom - tolerance;
    }

    private static String oneLine(String value) {
        if (value == null) return "(null)";
        return value.replace('\r', ' ').replace('\n', ' ').trim();
    }

    private static String compact(String value, int maximumLength) {
        if (value == null) return "";
        String clean = value.trim();
        if (clean.length() <= maximumLength) return clean;
        return clean.substring(0, Math.max(0, maximumLength - 1)) + "…";
    }

    private EditText createPasswordEditor(int hint) {
        EditText editor = new EditText(this);
        editor.setHint(hint);
        editor.setSingleLine(true);
        editor.setInputType(InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_VARIATION_PASSWORD
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        return editor;
    }

    private TextView createLogConsole(int minimumLines, int maximumLines) {
        TextView console = new ConsoleTextView(this);
        console.setTypeface(Typeface.MONOSPACE);
        console.setTextSize(12f);
        console.setTextColor(Color.rgb(222, 231, 240));
        console.setHighlightColor(Color.rgb(55, 96, 145));
        console.setGravity(Gravity.TOP | Gravity.START);
        console.setLineSpacing(0f, 1.15f);
        console.setMinLines(minimumLines);
        console.setMaxLines(maximumLines);
        console.setHorizontallyScrolling(false);
        // Some Android 16 vendor frameworks crash while drawing a forced,
        // non-fading scrollbar before its ScrollBarDrawable is initialized.
        // Selection's movement method still provides touch scrolling.
        console.setVerticalScrollBarEnabled(false);
        console.setTextIsSelectable(true);
        console.setPadding(dp(12), dp(12), dp(12), dp(12));

        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.rgb(13, 18, 23));
        background.setCornerRadius(dp(10));
        background.setStroke(Math.max(1, dp(1)), Color.rgb(59, 72, 84));
        console.setBackground(background);
        return console;
    }

    private void addLogConsole(LinearLayout parent, TextView console, int bottomMargin) {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        layout.topMargin = dp(8);
        layout.bottomMargin = bottomMargin;
        parent.addView(console, layout);
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    /** Lets a console consume drags while it can scroll, then hands edge drags to the page. */
    private static final class ConsoleTextView extends AppCompatTextView {
        private float previousY;

        ConsoleTextView(Context context) {
            super(context);
        }

        @Override
        public boolean performClick() {
            return super.performClick();
        }

        // TextView's implementation handles click accessibility, long-press
        // selection, and movement after the interception policy above runs.
        @SuppressLint("ClickableViewAccessibility")
        @Override
        public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    previousY = event.getY();
                    getParent().requestDisallowInterceptTouchEvent(true);
                    break;
                case MotionEvent.ACTION_MOVE:
                    float currentY = event.getY();
                    float delta = currentY - previousY;
                    if (Math.abs(delta) >= 1f) {
                        int direction = delta < 0f ? 1 : -1;
                        boolean keepInConsole = hasConsoleSelection(this)
                                || canScrollVertically(direction);
                        getParent().requestDisallowInterceptTouchEvent(keepInConsole);
                    }
                    previousY = currentY;
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    getParent().requestDisallowInterceptTouchEvent(false);
                    break;
                default:
                    break;
            }
            return super.onTouchEvent(event);
        }
    }

    private boolean isUserUnlocked() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true;
        UserManager userManager = (UserManager) getSystemService(USER_SERVICE);
        return userManager != null && userManager.isUserUnlocked();
    }

    private static ViewGroup.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }
}
