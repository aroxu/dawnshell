package me.aroxu.dawnshell;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.res.AssetManager;
import android.os.Bundle;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.google.android.material.appbar.MaterialToolbar;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/** Selectable copy of every license and source offer shipped inside the APK. */
public final class OpenSourceLicensesActivity extends AppCompatActivity {

    private static final String ASSET_ROOT = "open_source_licenses/";
    private static final String[] DOCUMENTS = {
            "SOURCE_OFFER.txt",
            "README.md",
            "THIRD_PARTY_NOTICES.md",
            "ANDROID_DEPENDENCIES.md",
            "DawnShell-MIT.txt",
            "Apache-2.0.txt",
            "CC0-1.0.txt",
            "Expat.txt",
            "GPL-2.0-only.txt",
            "GPL-2.0-or-later.txt",
            "GPL-3.0-or-later.txt",
            "LGPL-2.1-or-later.txt",
            "LGPL-3.0-or-later.txt",
            "base-installer-1.226-copyright.txt",
            "debian-archive-keyring-2025.1-copyright.txt",
            "GnuPG-2.4.9-additional-notices.txt",
            "Libgcrypt-1.12.1-additional-notices.txt"
    };

    private String displayedText = "";

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_open_source_licenses);

        MaterialToolbar toolbar = findViewById(R.id.licenses_toolbar);
        toolbar.setNavigationOnClickListener(view -> finish());
        toolbar.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == R.id.action_copy_licenses) {
                copyAll();
                return true;
            }
            return false;
        });

        TextView text = findViewById(R.id.licenses_text);
        try {
            displayedText = readBundle(getAssets());
            text.setText(displayedText);
        } catch (IOException e) {
            displayedText = getString(R.string.dawnshell_licenses_read_failed,
                    e.getMessage());
            text.setText(displayedText);
        }
    }

    private static String readBundle(AssetManager assets) throws IOException {
        StringBuilder result = new StringBuilder(128 * 1024);
        for (String document : DOCUMENTS) {
            if (result.length() > 0) result.append("\n\n");
            result.append("===== ").append(document).append(" =====\n\n");
            try (InputStream input = assets.open(ASSET_ROOT + document);
                 BufferedReader reader = new BufferedReader(new InputStreamReader(
                         input, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    result.append(line).append('\n');
                }
            }
        }
        return result.toString();
    }

    private void copyAll() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(
                Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            Toast.makeText(this, R.string.bfu_clipboard_unavailable,
                    Toast.LENGTH_LONG).show();
            return;
        }
        clipboard.setPrimaryClip(ClipData.newPlainText(
                getString(R.string.dawnshell_open_source_licenses), displayedText));
        Toast.makeText(this, R.string.dawnshell_licenses_copied,
                Toast.LENGTH_SHORT).show();
    }
}
