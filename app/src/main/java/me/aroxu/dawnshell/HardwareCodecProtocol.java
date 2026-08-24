package me.aroxu.dawnshell;

/** Wire constants shared with the source-built Debian dawnshell-codec client. */
final class HardwareCodecProtocol {

    static final int MAGIC = 0x44534342; // "DSCB"
    static final int VERSION = 1;
    static final int HEADER_BYTES = 32;
    static final int RESPONSE_BIT = 0x8000;

    static final int HELLO = 1;
    static final int CAPABILITIES = 2;
    static final int CREATE = 3;
    static final int INPUT = 4;
    static final int OUTPUT = 5;
    static final int FLUSH = 6;
    static final int EOS = 7;
    static final int CLOSE = 8;

    static final int MODE_DECODE = 1;
    static final int MODE_ENCODE = 2;
    static final int CODEC_AVC = 1;
    static final int CODEC_HEVC = 2;
    static final int PIXEL_FORMAT_BITSTREAM = 0;
    static final int PIXEL_FORMAT_I420 = 1;

    static final int OK = 0;
    static final int AGAIN = 1;
    static final int FORMAT_CHANGED = 2;
    static final int ERROR_PROTOCOL = -1;
    static final int ERROR_VERSION = -2;
    static final int ERROR_UNAUTHORIZED = -3;
    static final int ERROR_UNSUPPORTED = -4;
    static final int ERROR_LIMIT = -5;
    static final int ERROR_CODEC = -6;
    static final int ERROR_SESSION = -7;
    static final int ERROR_IO = -8;

    static final int CREATE_PAYLOAD_BYTES = 28;
    static final int MAX_CONTROL_PAYLOAD = 1024 * 1024;
    static final int MAX_MEDIA_PAYLOAD = 8 * 1024 * 1024;
    static final int MAX_SESSIONS = 4;
    static final int MAX_SESSIONS_PER_PEER = 2;
    static final String SOCKET_NAME = "dawnshell.codec.v1";

    private HardwareCodecProtocol() {}
}
