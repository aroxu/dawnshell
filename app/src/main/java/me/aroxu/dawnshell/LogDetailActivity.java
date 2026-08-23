package me.aroxu.dawnshell;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.widget.NestedScrollView;

import com.google.android.material.appbar.MaterialToolbar;

import java.io.IOException;

/** Full-screen, selectable, live-following view of one DawnShell log stream. */
public final class LogDetailActivity extends AppCompatActivity {

    private static final String EXTRA_TYPE = "me.aroxu.dawnshell.extra.LOG_TYPE";

    private final Handler refreshHandler = new Handler(Looper.getMainLooper());
    private TextView logText;
    private NestedScrollView logScroll;
    private String type;
    private String displayed = "";
    private boolean resumed;
    private boolean followingTail = true;
    private boolean programmaticScroll;

    private final Runnable refreshTask = new Runnable() {
        @Override
        public void run() {
            refreshNow();
            if (resumed) refreshHandler.postDelayed(this, 1_000L);
        }
    };

    static Intent createIntent(Context context, String type) {
        return new Intent(context, LogDetailActivity.class).putExtra(EXTRA_TYPE, type);
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        type = getIntent().getStringExtra(EXTRA_TYPE);
        if (!DawnShellLogRepository.isKnown(type)) {
            Toast.makeText(this, R.string.dawnshell_log_unknown, Toast.LENGTH_LONG).show();
            finish();
            return;
        }

        setContentView(R.layout.activity_log_detail);
        logText = findViewById(R.id.log_detail_text);
        logScroll = findViewById(R.id.log_detail_scroll);
        TextView description = findViewById(R.id.log_detail_description);
        description.setText(DawnShellLogRepository.descriptionRes(type));

        MaterialToolbar toolbar = findViewById(R.id.log_detail_toolbar);
        toolbar.setTitle(DawnShellLogRepository.titleRes(type));
        toolbar.setNavigationOnClickListener(view -> finish());
        toolbar.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == R.id.action_copy_log) {
                copyAll();
                return true;
            }
            if (item.getItemId() == R.id.action_refresh_log) {
                refreshNow();
                return true;
            }
            return false;
        });

        logScroll.setOnScrollChangeListener((NestedScrollView.OnScrollChangeListener)
                (view, scrollX, scrollY, oldScrollX, oldScrollY) -> {
                    if (!programmaticScroll) followingTail = isNearBottom();
                });
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (logText == null) return;
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

    private void refreshNow() {
        if (hasSelection()) return;
        String value;
        try {
            value = DawnShellLogRepository.read(this, type);
        } catch (IOException e) {
            value = getString(R.string.dawnshell_log_read_failed,
                    BfuSu.sanitize(e.getMessage()));
        }
        if (TextUtils.equals(displayed, value)) return;

        boolean follow = displayed.isEmpty() || followingTail;
        int previousScroll = logScroll.getScrollY();
        displayed = value;
        logText.setText(value);
        logScroll.post(() -> {
            programmaticScroll = true;
            if (follow) {
                logScroll.fullScroll(NestedScrollView.FOCUS_DOWN);
                followingTail = true;
            } else {
                logScroll.scrollTo(0, previousScroll);
            }
            logScroll.post(() -> programmaticScroll = false);
        });
    }

    private boolean isNearBottom() {
        if (logScroll.getChildCount() == 0) return true;
        int contentHeight = logScroll.getChildAt(0).getHeight();
        int visibleBottom = logScroll.getScrollY() + logScroll.getHeight()
                - logScroll.getPaddingBottom();
        int tolerance = (int) (24f * getResources().getDisplayMetrics().density + 0.5f);
        return visibleBottom >= contentHeight - tolerance;
    }

    private boolean hasSelection() {
        int start = logText.getSelectionStart();
        int end = logText.getSelectionEnd();
        return start >= 0 && end >= 0 && start != end;
    }

    private void copyAll() {
        CharSequence value = logText.getText();
        if (TextUtils.isEmpty(value)) {
            Toast.makeText(this, R.string.dawnshell_log_copy_empty,
                    Toast.LENGTH_SHORT).show();
            return;
        }
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            Toast.makeText(this, R.string.bfu_clipboard_unavailable,
                    Toast.LENGTH_LONG).show();
            return;
        }
        clipboard.setPrimaryClip(ClipData.newPlainText(
                getString(DawnShellLogRepository.titleRes(type)), value));
        Toast.makeText(this, R.string.dawnshell_log_copied, Toast.LENGTH_SHORT).show();
    }
}
