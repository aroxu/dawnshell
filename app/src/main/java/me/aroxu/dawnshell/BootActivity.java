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
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.widget.AppCompatTextView;

import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.textfield.TextInputLayout;

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
    private volatile boolean rootAuthorizationInProgress;
    private volatile boolean passwordUpdateInProgress;
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
            Toast.makeText(this, R.string.bfu_private_key_export_failed,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_private_key_exported,
                    Toast.LENGTH_LONG).show();
        } catch (IOException e) {
            recordOperation("SSH_CLIENT_PRIVATE_KEY_EXPORT_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(R.string.bfu_private_key_export_failed_detail,
                    e.getMessage()), Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_ssh_key_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, getString(R.string.bfu_generated_key_failed,
                    e.getMessage()), Toast.LENGTH_LONG).show();
        }
    }

    private void confirmPrivateKeyFileExport() {
        if (!isUserUnlocked()) {
            Toast.makeText(this, R.string.bfu_ssh_key_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_ssh_key_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, getString(R.string.bfu_generated_key_failed,
                    e.getMessage()), Toast.LENGTH_LONG).show();
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
                                      int toastMessage) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            Toast.makeText(this, R.string.bfu_clipboard_unavailable,
                    Toast.LENGTH_LONG).show();
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
        Toast.makeText(this, toastMessage, Toast.LENGTH_SHORT).show();
    }

    private void loadSettings() {
        enableBfu.setChecked(BfuPreferences.isEnabled(this));
        allowCeReadableBfu.setChecked(BfuPreferences.allowCeReadableBfu(this));
        selectCgroupPolicy(BfuPreferences.cgroupPolicy(this));
        selectDockerNetworkPolicy(BfuPreferences.dockerNetworkPolicy(this));
        dockerHostIpcCompatibility.setChecked(
                BfuPreferences.dockerHostIpcCompatibility(this));
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
                + dockerHostIpcCompatibility.isChecked());
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.Layout layout = BfuRuntime.provision(this);
            BfuSshClientKeyStore.Identity identity = BfuSshClientKeyStore.ensure(this);
            int keyCount = BfuAuthorizedKeys.validateAndSave(layout, identity.publicKey);
            recordOperation("PROVISION_SUCCEEDED runtime=" + layout.root
                    + " authorized_key_count=" + keyCount);
            Toast.makeText(this, getString(R.string.bfu_saved, layout.root),
                    Toast.LENGTH_LONG).show();
        } catch (IOException | IllegalStateException e) {
            recordOperation("PROVISION_FAILED " + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(R.string.bfu_provision_failed, e.getMessage()),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void confirmRootAuthorization() {
        if (!isUserUnlocked()) {
            recordOperation("ROOT_AUTHORIZATION_REJECTED user_locked=true");
            Toast.makeText(this, R.string.bfu_root_authorization_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_install_requires_enabled,
                    Toast.LENGTH_LONG).show();
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DEBIAN_INSTALL_REJECTED user_locked=true");
            Toast.makeText(this, R.string.bfu_install_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_remove_rootfs_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
                                Toast.makeText(this,
                                        R.string.bfu_remove_rootfs_confirmation_mismatch,
                                        Toast.LENGTH_LONG).show();
                                return;
                            }
                            BfuBootService.requestDebianRootfsRemoval(this);
                            recordOperation("DEBIAN_ROOTFS_REMOVE_REQUESTED "
                                    + "root=/data/local/debian");
                            Toast.makeText(this, R.string.bfu_remove_rootfs_requested,
                                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_install_requested,
                    Toast.LENGTH_LONG).show();
            refreshInstallerStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_INSTALL_REQUEST_FAILED " + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(R.string.bfu_provision_failed, e.getMessage()),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void confirmSystemConfiguration() {
        if (!enableBfu.isChecked()) {
            recordOperation("DEBIAN_CONFIG_REJECTED bfu_disabled=true");
            Toast.makeText(this, R.string.bfu_install_requires_enabled,
                    Toast.LENGTH_LONG).show();
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DEBIAN_CONFIG_REJECTED user_locked=true");
            Toast.makeText(this, R.string.bfu_system_config_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.bfu_system_config_requested,
                    Toast.LENGTH_LONG).show();
            refreshSystemConfigurationStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_CONFIG_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(
                    R.string.bfu_system_config_request_failed, e.getMessage()),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void confirmDockerNetworkPolicy() {
        if (!enableBfu.isChecked()) {
            recordOperation("DOCKER_POLICY_REJECTED bfu_disabled=true");
            Toast.makeText(this, R.string.bfu_install_requires_enabled,
                    Toast.LENGTH_LONG).show();
            return;
        }
        if (!isUserUnlocked()) {
            recordOperation("DOCKER_POLICY_REJECTED user_locked=true");
            Toast.makeText(this, R.string.dawnshell_docker_policy_requires_unlock,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, R.string.dawnshell_docker_policy_requested,
                    Toast.LENGTH_LONG).show();
            refreshDockerPolicyStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DOCKER_POLICY_REQUEST_FAILED "
                    + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(R.string.bfu_provision_failed,
                    e.getMessage()), Toast.LENGTH_LONG).show();
        }
    }

    private void requestLifecycle(DebianLauncher.Operation operation) {
        if ((operation == DebianLauncher.Operation.START
                || operation == DebianLauncher.Operation.RESTART)
                && !enableBfu.isChecked()) {
            recordOperation("DEBIAN_LIFECYCLE_REJECTED operation="
                    + operation.name().toLowerCase(java.util.Locale.US)
                    + " bfu_disabled=true");
            Toast.makeText(this, R.string.bfu_install_requires_enabled,
                    Toast.LENGTH_LONG).show();
            return;
        }
        try {
            savePreferences();
            BfuCeIsolationProbe.provisionSentinel(this);
            BfuRuntime.provision(this);
            BfuBootService.requestDebianLifecycle(this, operation);
            recordOperation("DEBIAN_LIFECYCLE_REQUESTED operation="
                    + operation.name().toLowerCase(java.util.Locale.US));
            Toast.makeText(this, getString(R.string.bfu_lifecycle_requested,
                    operation.name()), Toast.LENGTH_SHORT).show();
            refreshLifecycleStatus();
        } catch (IOException | IllegalStateException e) {
            recordOperation("DEBIAN_LIFECYCLE_REQUEST_FAILED operation="
                    + operation.name() + " " + BfuSu.sanitize(e.getMessage()));
            Toast.makeText(this, getString(
                    R.string.bfu_lifecycle_request_failed, e.getMessage()),
                    Toast.LENGTH_LONG).show();
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
                dockerHostIpcCompatibility.isChecked(), usbMode, usbDeviceIds);
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
            Toast.makeText(this, R.string.bfu_password_requires_unlock,
                    Toast.LENGTH_LONG).show();
            recordOperation("DEBIAN_PASSWORD_REJECTED account=" + account
                    + " user_locked=true");
            return;
        }
        if (passwordUpdateInProgress) {
            Toast.makeText(this, R.string.bfu_password_busy,
                    Toast.LENGTH_SHORT).show();
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
            Toast.makeText(this, R.string.bfu_password_mismatch,
                    Toast.LENGTH_LONG).show();
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
            Toast.makeText(this, getString(
                    R.string.bfu_password_updated, account), Toast.LENGTH_LONG).show();
        } else {
            String safeFailure = result == null
                    ? (failure == null ? "unknown failure" : failure)
                    : result.summary();
            recordOperation("DEBIAN_PASSWORD_FAILED account=" + account
                    + " " + safeFailure);
            Toast.makeText(this, getString(
                    R.string.bfu_password_failed, account, safeFailure),
                    Toast.LENGTH_LONG).show();
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
