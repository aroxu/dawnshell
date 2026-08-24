package me.aroxu.dawnshell;

import android.app.Activity;

import com.google.android.material.dialog.MaterialAlertDialogBuilder;

/**
 * Shows short-lived user feedback as a dismissible dialog.
 *
 * <p>Toasts truncate long codec, root, and provisioning messages and disappear
 * before they can be read, so every notice uses a dialog the user dismisses.
 */
final class DawnShellNotice {

    private DawnShellNotice() {}

    static void show(Activity activity, int messageRes) {
        if (activity == null || activity.isFinishing()) return;
        show(activity, activity.getString(messageRes));
    }

    static void show(Activity activity, String message) {
        if (activity == null || activity.isFinishing()) return;
        if (message == null || message.trim().isEmpty()) return;
        new MaterialAlertDialogBuilder(activity)
                .setMessage(message)
                .setPositiveButton(android.R.string.ok, null)
                .show();
    }
}
