package me.aroxu.dawnshell;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.MotionEvent;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.widget.NestedScrollView;

import com.google.android.material.appbar.MaterialToolbar;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Full-screen, selectable, live-following view of one DawnShell log stream. */
public final class LogDetailActivity extends AppCompatActivity {

    private static final String EXTRA_TYPE = "me.aroxu.dawnshell.extra.LOG_TYPE";

    private final Handler refreshHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService readExecutor = Executors.newSingleThreadExecutor();
    private TextView logText;
    private NestedScrollView logScroll;
    private String type;
    private String displayed = "";
    private boolean resumed;
    private boolean followingTail = true;
    private boolean programmaticScroll;
    private boolean userScrollGesture;
    private boolean refreshInProgress;

    private final Runnable refreshTask = new Runnable() {
        @Override
        public void run() {
            requestRefresh();
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
            DawnShellNotice.show(this, R.string.dawnshell_log_unknown);
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
                requestRefresh();
                return true;
            }
            return false;
        });

        logScroll.setOnScrollChangeListener((NestedScrollView.OnScrollChangeListener)
                (view, scrollX, scrollY, oldScrollX, oldScrollY) -> {
                    if (!programmaticScroll || userScrollGesture) {
                        if (scrollY < oldScrollY) {
                            followingTail = false;
                        } else if (isAtBottom()) {
                            followingTail = true;
                        }
                    }
                });
        logScroll.setOnTouchListener((view, event) -> {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    userScrollGesture = true;
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    userScrollGesture = false;
                    logScroll.post(() -> followingTail = isAtBottom());
                    break;
                default:
                    break;
            }
            return false;
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

    @Override
    protected void onDestroy() {
        readExecutor.shutdownNow();
        super.onDestroy();
    }

    private void requestRefresh() {
        if (hasSelection() || refreshInProgress || readExecutor.isShutdown()) return;
        refreshInProgress = true;
        readExecutor.execute(() -> {
            String value;
            try {
                value = DawnShellLogRepository.read(this, type);
            } catch (IOException | RuntimeException e) {
                value = getString(R.string.dawnshell_log_read_failed,
                        BfuSu.sanitize(e.getMessage()));
            }
            final String result = value;
            runOnUiThread(() -> {
                refreshInProgress = false;
                if (isFinishing() || isDestroyed() || hasSelection()) return;
                applyRefresh(result);
            });
        });
    }

    private void applyRefresh(String value) {
        if (TextUtils.equals(displayed, value)) return;

        boolean follow = displayed.isEmpty() || followingTail;
        int previousScroll = logScroll.getScrollY();
        displayed = value;
        // setText() itself may synchronously reset NestedScrollView to the top.
        // Suppress that callback before changing the text, not only in post().
        programmaticScroll = true;
        logText.setText(value);
        logScroll.post(() -> {
            if (follow && !userScrollGesture) {
                scrollToBottom();
                followingTail = true;
            } else {
                logScroll.scrollTo(0, Math.min(previousScroll, maximumScrollY()));
                followingTail = isAtBottom();
            }
            // A second frame handles late TextView re-layout for long logs.
            logScroll.postOnAnimation(() -> {
                if (follow && !userScrollGesture) scrollToBottom();
                programmaticScroll = false;
                if (!userScrollGesture) followingTail = isAtBottom();
            });
        });
    }

    private void scrollToBottom() {
        logScroll.scrollTo(0, maximumScrollY());
    }

    private int maximumScrollY() {
        if (logScroll.getChildCount() == 0) return 0;
        int viewport = logScroll.getHeight()
                - logScroll.getPaddingTop() - logScroll.getPaddingBottom();
        return Math.max(0, logScroll.getChildAt(0).getHeight() - viewport);
    }

    private boolean isAtBottom() {
        // Allow only layout rounding, not a visible "near bottom" band: any
        // deliberate upward scroll must pause live following immediately.
        return logScroll.getScrollY() >= maximumScrollY() - 2;
    }

    private boolean hasSelection() {
        int start = logText.getSelectionStart();
        int end = logText.getSelectionEnd();
        return start >= 0 && end >= 0 && start != end;
    }

    private void copyAll() {
        CharSequence value = logText.getText();
        if (TextUtils.isEmpty(value)) {
            DawnShellNotice.show(this, R.string.dawnshell_log_copy_empty);
            return;
        }
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            DawnShellNotice.show(this, R.string.bfu_clipboard_unavailable);
            return;
        }
        clipboard.setPrimaryClip(ClipData.newPlainText(
                getString(DawnShellLogRepository.titleRes(type)), value));
        DawnShellNotice.show(this, R.string.dawnshell_log_copied);
    }
}
