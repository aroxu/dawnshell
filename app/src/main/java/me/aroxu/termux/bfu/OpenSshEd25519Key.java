package me.aroxu.termux.bfu;

import net.i2p.crypto.eddsa.EdDSAPrivateKey;
import net.i2p.crypto.eddsa.EdDSAPublicKey;
import net.i2p.crypto.eddsa.KeyPairGenerator;
import net.i2p.crypto.eddsa.spec.EdDSAGenParameterSpec;
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.SecureRandom;

/** Creates an unencrypted OpenSSH Ed25519 client identity. */
final class OpenSshEd25519Key {

    static final class Generated {
        final String privateKey;
        final String publicKey;

        Generated(String privateKey, String publicKey) {
            this.privateKey = privateKey;
            this.publicKey = publicKey;
        }
    }

    private static final byte[] AUTH_MAGIC =
            "openssh-key-v1\0".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] KEY_TYPE =
            "ssh-ed25519".getBytes(StandardCharsets.US_ASCII);
    private static final String COMMENT = "termux-bfu-client";

    private OpenSshEd25519Key() {}

    static Generated generate(SecureRandom random) throws GeneralSecurityException,
            IOException {
        KeyPairGenerator generator = new KeyPairGenerator();
        generator.initialize(new EdDSAGenParameterSpec(EdDSANamedCurveTable.ED_25519), random);
        KeyPair pair = generator.generateKeyPair();
        byte[] seed = ((EdDSAPrivateKey) pair.getPrivate()).getSeed();
        byte[] publicBytes = ((EdDSAPublicKey) pair.getPublic()).getAbyte();

        byte[] publicBlob = publicBlob(publicBytes);
        String publicKey = "ssh-ed25519 "
                + encodeBase64(publicBlob, 0) + " " + COMMENT;
        String privateKey = encodePrivateKey(random, seed, publicBytes, publicBlob);
        return new Generated(privateKey, publicKey);
    }

    private static byte[] publicBlob(byte[] publicBytes) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        writeString(output, KEY_TYPE);
        writeString(output, publicBytes);
        return output.toByteArray();
    }

    private static String encodePrivateKey(SecureRandom random, byte[] seed,
                                           byte[] publicBytes, byte[] publicBlob)
            throws IOException {
        ByteArrayOutputStream privateSection = new ByteArrayOutputStream();
        int check = random.nextInt();
        writeUint32(privateSection, check);
        writeUint32(privateSection, check);
        writeString(privateSection, KEY_TYPE);
        writeString(privateSection, publicBytes);
        byte[] privateAndPublic = new byte[seed.length + publicBytes.length];
        System.arraycopy(seed, 0, privateAndPublic, 0, seed.length);
        System.arraycopy(publicBytes, 0, privateAndPublic, seed.length, publicBytes.length);
        writeString(privateSection, privateAndPublic);
        writeString(privateSection, COMMENT.getBytes(StandardCharsets.UTF_8));
        int padding = 8 - (privateSection.size() % 8);
        if (padding == 0) padding = 8;
        for (int i = 1; i <= padding; i++) privateSection.write(i);

        ByteArrayOutputStream envelope = new ByteArrayOutputStream();
        envelope.write(AUTH_MAGIC);
        writeString(envelope, "none".getBytes(StandardCharsets.US_ASCII));
        writeString(envelope, "none".getBytes(StandardCharsets.US_ASCII));
        writeString(envelope, new byte[0]);
        writeUint32(envelope, 1);
        writeString(envelope, publicBlob);
        writeString(envelope, privateSection.toByteArray());

        String base64 = encodeBase64(envelope.toByteArray(), 70);
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n"
                + base64 + "\n-----END OPENSSH PRIVATE KEY-----\n";
    }

    private static void writeString(ByteArrayOutputStream output, byte[] value)
            throws IOException {
        writeUint32(output, value.length);
        output.write(value);
    }

    private static void writeUint32(ByteArrayOutputStream output, int value) {
        output.write((value >>> 24) & 0xff);
        output.write((value >>> 16) & 0xff);
        output.write((value >>> 8) & 0xff);
        output.write(value & 0xff);
    }

    private static String encodeBase64(byte[] input, int lineLength) {
        final char[] alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                .toCharArray();
        StringBuilder output = new StringBuilder(((input.length + 2) / 3) * 4);
        int column = 0;
        for (int offset = 0; offset < input.length; offset += 3) {
            int remaining = input.length - offset;
            int value = (input[offset] & 0xff) << 16;
            if (remaining > 1) value |= (input[offset + 1] & 0xff) << 8;
            if (remaining > 2) value |= input[offset + 2] & 0xff;
            char[] block = {
                    alphabet[(value >>> 18) & 63],
                    alphabet[(value >>> 12) & 63],
                    remaining > 1 ? alphabet[(value >>> 6) & 63] : '=',
                    remaining > 2 ? alphabet[value & 63] : '='
            };
            for (char character : block) {
                if (lineLength > 0 && column == lineLength) {
                    output.append('\n');
                    column = 0;
                }
                output.append(character);
                column++;
            }
        }
        return output.toString();
    }
}
