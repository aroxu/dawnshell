package me.aroxu.termux.bfu;

import android.content.Context;
import android.os.Build;
import android.os.UserManager;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;

/** Stores the exportable client identity only in this app's CE storage. */
final class BfuSshClientKeyStore {

    static final class Identity {
        final String privateKey;
        final String publicKey;

        Identity(String privateKey, String publicKey) {
            this.privateKey = privateKey;
            this.publicKey = publicKey;
        }
    }

    private static final String FORMAT = "TERMUX-BFU-SSH-KEY-V1";
    private static final int MAX_BYTES = 16 * 1024;

    private BfuSshClientKeyStore() {}

    static Identity ensure(Context context) throws IOException {
        requireUnlocked(context);
        File file = identityFile(context);
        if (file.isFile()) return read(file);
        if (file.exists()) throw new IOException("SSH identity path is not a regular file");
        return generateAndReplace(context);
    }

    static Identity generateAndReplace(Context context) throws IOException {
        requireUnlocked(context);
        OpenSshEd25519Key.Generated generated;
        try {
            generated = OpenSshEd25519Key.generate(new SecureRandom());
        } catch (GeneralSecurityException e) {
            throw new IOException("could not generate Ed25519 key", e);
        }
        Identity identity = new Identity(generated.privateKey, generated.publicKey);
        write(identityFile(context), identity);
        return identity;
    }

    private static File identityFile(Context context) throws IOException {
        File directory = new File(context.getApplicationContext().getFilesDir(), "ssh");
        if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("could not create CE SSH key directory");
        }
        setOwnerOnly(directory, true);
        return new File(directory, "termux-bfu-client.identity");
    }

    private static void write(File destination, Identity identity) throws IOException {
        String record = FORMAT + "\n" + identity.publicKey + "\n" + identity.privateKey;
        byte[] bytes = record.getBytes(StandardCharsets.US_ASCII);
        File temporary = new File(destination.getParentFile(), destination.getName() + ".new");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(bytes);
            output.getFD().sync();
        }
        setOwnerOnly(temporary, false);
        if (destination.exists() && !destination.delete()) {
            throw new IOException("could not replace CE SSH identity");
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("could not publish CE SSH identity");
        }
        setOwnerOnly(destination, false);
    }

    private static Identity read(File file) throws IOException {
        if (file.length() <= 0 || file.length() > MAX_BYTES) {
            throw new IOException("CE SSH identity has an invalid size");
        }
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (output.size() + count > MAX_BYTES) {
                    throw new IOException("CE SSH identity exceeds the size limit");
                }
                output.write(buffer, 0, count);
            }
        }
        String record = new String(output.toByteArray(), StandardCharsets.US_ASCII);
        int first = record.indexOf('\n');
        int second = first < 0 ? -1 : record.indexOf('\n', first + 1);
        if (first < 0 || second < 0 || !FORMAT.equals(record.substring(0, first))) {
            throw new IOException("CE SSH identity has an unsupported format");
        }
        String publicKey = record.substring(first + 1, second);
        String privateKey = record.substring(second + 1);
        if (!publicKey.startsWith("ssh-ed25519 ")
                || !privateKey.startsWith("-----BEGIN OPENSSH PRIVATE KEY-----\n")
                || !privateKey.endsWith("-----END OPENSSH PRIVATE KEY-----\n")) {
            throw new IOException("CE SSH identity is corrupt");
        }
        setOwnerOnly(file, false);
        return new Identity(privateKey, publicKey);
    }

    private static void requireUnlocked(Context context) throws IOException {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;
        UserManager manager = (UserManager) context.getSystemService(Context.USER_SERVICE);
        if (manager == null || !manager.isUserUnlocked()) {
            throw new IOException("unlock Android before accessing the SSH client key");
        }
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file, boolean executable) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
        if (executable) file.setExecutable(true, true);
    }
}
