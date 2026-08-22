package me.aroxu.termux.bfu;

import org.junit.Test;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.attribute.PosixFilePermission;
import java.security.SecureRandom;
import java.util.EnumSet;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class OpenSshEd25519KeyTest {

    @Test
    public void generatedPrivateKeyIsAcceptedByOpenSsh() throws Exception {
        OpenSshEd25519Key.Generated generated =
                OpenSshEd25519Key.generate(new SecureRandom());
        assertTrue(generated.publicKey.startsWith("ssh-ed25519 "));
        assertTrue(generated.privateKey.startsWith(
                "-----BEGIN OPENSSH PRIVATE KEY-----\n"));

        File directory = Files.createTempDirectory("termux-bfu-key-test").toFile();
        File privateKey = new File(directory, "id_ed25519");
        try {
            try (FileOutputStream output = new FileOutputStream(privateKey)) {
                output.write(generated.privateKey.getBytes(StandardCharsets.US_ASCII));
            }
            restrictToCurrentUser(privateKey);
            Process process = new ProcessBuilder("ssh-keygen", "-y", "-f",
                    privateKey.getAbsolutePath()).redirectErrorStream(true).start();
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            try (InputStream input = process.getInputStream()) {
                byte[] buffer = new byte[1024];
                int count;
                while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            }
            assertEquals(new String(output.toByteArray(), StandardCharsets.US_ASCII),
                    0, process.waitFor());
            String derived = new String(output.toByteArray(), StandardCharsets.US_ASCII).trim();
            int derivedComment = derived.lastIndexOf(' ');
            if (derivedComment > derived.indexOf(' ')) {
                derived = derived.substring(0, derivedComment);
            }
            assertEquals(generated.publicKey.substring(0,
                    generated.publicKey.lastIndexOf(' ')), derived);
        } finally {
            privateKey.delete();
            directory.delete();
        }
    }

    private static void restrictToCurrentUser(File file) throws Exception {
        if (System.getProperty("os.name", "").toLowerCase().contains("win")) {
            String user = System.getProperty("user.name");
            Process permissions = new ProcessBuilder("icacls", file.getAbsolutePath(),
                    "/inheritance:r", "/grant:r", user + ":(R,W)")
                    .redirectErrorStream(true).start();
            while (permissions.getInputStream().read() >= 0) {
                // Drain command output.
            }
            assertEquals(0, permissions.waitFor());
        } else {
            Files.setPosixFilePermissions(file.toPath(), EnumSet.of(
                    PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE));
        }
    }
}
