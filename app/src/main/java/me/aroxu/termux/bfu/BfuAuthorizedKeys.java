package me.aroxu.termux.bfu;

import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Validates and stores public keys only in Device Protected Storage. */
final class BfuAuthorizedKeys {

    private static final int MAX_BYTES = 32 * 1024;
    private static final int MAX_KEYS = 32;
    private static final Set<String> ALLOWED_TYPES = new HashSet<>(Arrays.asList(
            "ssh-ed25519",
            "ssh-rsa",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "sk-ssh-ed25519@openssh.com",
            "sk-ecdsa-sha2-nistp256@openssh.com"
    ));

    private BfuAuthorizedKeys() {}

    static int validateAndSave(BfuRuntime.Layout layout, String input) throws IOException {
        if (input == null || input.indexOf('\0') >= 0) {
            throw new IOException("authorized_keys contains invalid text");
        }
        String normalizedInput = input.replace("\r\n", "\n").replace('\r', '\n');
        StringBuilder normalized = new StringBuilder();
        int keyCount = 0;
        for (String originalLine : normalizedInput.split("\n", -1)) {
            String line = originalLine.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            if (line.length() > 16 * 1024) {
                throw new IOException("an SSH public-key line is too long");
            }
            String[] fields = line.split("\\s+", 3);
            if (fields.length < 2 || !ALLOWED_TYPES.contains(fields[0])) {
                throw new IOException("only bare supported SSH public keys are allowed; key options are forbidden");
            }
            if (!fields[1].matches("[A-Za-z0-9+/]+={0,2}")) {
                throw new IOException("SSH public key has invalid base64 text");
            }
            byte[] blob;
            try {
                blob = Base64.decode(fields[1], Base64.NO_WRAP);
            } catch (IllegalArgumentException e) {
                throw new IOException("SSH public key has invalid base64", e);
            }
            validateBlobType(fields[0], blob);
            keyCount++;
            if (keyCount > MAX_KEYS) throw new IOException("at most 32 SSH public keys are allowed");
            normalized.append(line).append('\n');
            if (normalized.toString().getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) {
                throw new IOException("authorized_keys exceeds 32 KiB");
            }
        }
        if (keyCount == 0) {
            throw new IOException("enter at least one SSH public key");
        }

        byte[] contents = normalized.toString().getBytes(StandardCharsets.UTF_8);
        File destination = layout.authorizedKeys;
        File temporary = new File(destination.getParentFile(), destination.getName() + ".new");
        try (FileOutputStream output = new FileOutputStream(temporary, false)) {
            output.write(contents);
            output.getFD().sync();
        }
        setOwnerOnly(temporary);
        if (destination.exists() && !destination.delete()) {
            throw new IOException("cannot replace DE authorized_keys");
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("cannot publish DE authorized_keys");
        }
        setOwnerOnly(destination);
        return keyCount;
    }

    static String read(BfuRuntime.Layout layout) throws IOException {
        File file = layout.authorizedKeys;
        if (!file.isFile()) return "";
        if (file.length() > MAX_BYTES) throw new IOException("DE authorized_keys exceeds 32 KiB");
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (output.size() + count > MAX_BYTES) {
                    throw new IOException("DE authorized_keys exceeds 32 KiB");
                }
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static void validateBlobType(String declaredType, byte[] blob) throws IOException {
        if (blob.length < 5) throw new IOException("SSH public key blob is truncated");
        long length = ((long) (blob[0] & 0xff) << 24)
                | ((long) (blob[1] & 0xff) << 16)
                | ((long) (blob[2] & 0xff) << 8)
                | (long) (blob[3] & 0xff);
        if (length <= 0 || length > blob.length - 4 || length > 256) {
            throw new IOException("SSH public key blob has an invalid type field");
        }
        String embeddedType = new String(blob, 4, (int) length, StandardCharsets.US_ASCII);
        if (!declaredType.equals(embeddedType)) {
            throw new IOException("SSH public key type does not match its encoded blob");
        }
    }

    @SuppressWarnings("ResultOfMethodCallIgnored")
    private static void setOwnerOnly(File file) {
        file.setReadable(false, false);
        file.setWritable(false, false);
        file.setExecutable(false, false);
        file.setReadable(true, true);
        file.setWritable(true, true);
    }
}
