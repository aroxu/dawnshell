package me.aroxu.dawnshell;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.google.android.material.appbar.MaterialToolbar;

import java.io.IOException;

/** Live index of the separate DawnShell log streams. */
public final class LogsActivity extends AppCompatActivity {

    private final Handler refreshHandler = new Handler(Looper.getMainLooper());
    private boolean resumed;

    private final Runnable refreshTask = new Runnable() {
        @Override
        public void run() {
            refreshSummaries();
            if (resumed) refreshHandler.postDelayed(this, 1_000L);
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_logs);

        MaterialToolbar toolbar = findViewById(R.id.logs_toolbar);
        toolbar.setNavigationOnClickListener(view -> finish());

        bind(R.id.log_card_operations, DawnShellLogRepository.OPERATIONS);
        bind(R.id.log_card_installation, DawnShellLogRepository.INSTALLATION);
        bind(R.id.log_card_configuration, DawnShellLogRepository.CONFIGURATION);
        bind(R.id.log_card_compatibility, DawnShellLogRepository.COMPATIBILITY);
        bind(R.id.log_card_hardware_codec, DawnShellLogRepository.HARDWARE_CODEC);
        bind(R.id.log_card_lifecycle, DawnShellLogRepository.LIFECYCLE);
        bind(R.id.log_card_diagnostics, DawnShellLogRepository.DIAGNOSTICS);
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        refreshHandler.removeCallbacks(refreshTask);
        refreshHandler.post(refreshTask);
    }

    @Override
    protected void onPause() {
        resumed = false;
        refreshHandler.removeCallbacks(refreshTask);
        super.onPause();
    }

    private void bind(int viewId, String type) {
        findViewById(viewId).setOnClickListener(view ->
                startActivity(LogDetailActivity.createIntent(this, type)));
    }

    private void refreshSummaries() {
        refreshSummary(R.id.log_summary_operations, DawnShellLogRepository.OPERATIONS);
        refreshSummary(R.id.log_summary_installation, DawnShellLogRepository.INSTALLATION);
        refreshSummary(R.id.log_summary_configuration, DawnShellLogRepository.CONFIGURATION);
        refreshSummary(R.id.log_summary_compatibility, DawnShellLogRepository.COMPATIBILITY);
        refreshSummary(R.id.log_summary_hardware_codec,
                DawnShellLogRepository.HARDWARE_CODEC);
        refreshSummary(R.id.log_summary_lifecycle, DawnShellLogRepository.LIFECYCLE);
        refreshSummary(R.id.log_summary_diagnostics, DawnShellLogRepository.DIAGNOSTICS);
    }

    private void refreshSummary(int viewId, String type) {
        TextView view = findViewById(viewId);
        String value;
        try {
            value = DawnShellLogRepository.readSummary(this, type);
        } catch (IOException e) {
            value = getString(R.string.dawnshell_log_read_failed,
                    BfuSu.sanitize(e.getMessage()));
        }
        if (!value.contentEquals(view.getText())) view.setText(value);
    }
}
