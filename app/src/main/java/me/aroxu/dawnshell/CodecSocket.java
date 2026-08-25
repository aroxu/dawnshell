package me.aroxu.dawnshell;

import java.io.IOException;

/**
 * Plain AF_UNIX transport for the codec bridge.
 *
 * <p>Android's {@code LocalSocket} surfaces ancillary descriptors only through
 * its own stream wrapper, and reading a message that carries an SCM_RIGHTS
 * descriptor through that wrapper fails with EMSGSIZE ("Message too long").
 * This class performs {@code recvmsg}/{@code sendmsg} directly so a shared
 * memory descriptor can accompany a request header of any size.
 */
final class CodecSocket implements AutoCloseable {

    static {
        System.loadLibrary("dawnshell_codec_socket");
    }

    /** Signals an orderly peer disconnect rather than an error. */
    static final int END_OF_STREAM = -2;

    private final int descriptor;
    private boolean closed;

    private CodecSocket(int descriptor) {
        this.descriptor = descriptor;
    }

    static CodecSocket listen(String abstractName, int backlog) throws IOException {
        return new CodecSocket(nativeCreateServer(abstractName, backlog));
    }

    /**
     * Accepts one peer and reports its credentials.
     *
     * @param credentials a two-element array that receives uid and pid
     */
    CodecSocket accept(int[] credentials) throws IOException {
        if (credentials.length < 2) {
            throw new IllegalArgumentException("credentials needs two slots");
        }
        return new CodecSocket(nativeAccept(descriptor, credentials));
    }

    void setTimeoutMs(int timeoutMs) throws IOException {
        nativeSetTimeoutMs(descriptor, timeoutMs);
    }

    /**
     * Reads exactly {@code length} bytes.
     *
     * @param receivedDescriptor a one-element array that receives an ancillary
     *     descriptor, or is left untouched when the message carried none
     * @return the byte count, or {@link #END_OF_STREAM} when the peer closed
     */
    int receiveFully(byte[] buffer, int offset, int length,
                     int[] receivedDescriptor) throws IOException {
        return nativeReceive(descriptor, buffer, offset, length,
                receivedDescriptor);
    }

    void sendFully(byte[] buffer, int offset, int length) throws IOException {
        nativeSend(descriptor, buffer, offset, length);
    }

    void shutdown() {
        nativeShutdown(descriptor);
    }

    @Override
    public synchronized void close() {
        if (closed) return;
        closed = true;
        nativeClose(descriptor);
    }

    private static native int nativeCreateServer(String name, int backlog)
            throws IOException;

    private static native int nativeAccept(int server, int[] credentials)
            throws IOException;

    private static native int nativeSetTimeoutMs(int descriptor, int timeoutMs)
            throws IOException;

    private static native int nativeReceive(int descriptor, byte[] buffer,
            int offset, int length, int[] receivedDescriptor) throws IOException;

    private static native int nativeSend(int descriptor, byte[] buffer,
            int offset, int length) throws IOException;

    private static native void nativeClose(int descriptor);

    private static native void nativeShutdown(int descriptor);
}
