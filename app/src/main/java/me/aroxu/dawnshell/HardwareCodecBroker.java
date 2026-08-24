package me.aroxu.dawnshell;

import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Process;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Root-authenticated, versioned local bridge between Debian and MediaCodec. */
final class HardwareCodecBroker implements Closeable {

    private static final String TAG = "DawnShellCodec";
    private static final int PEER_TIMEOUT_MS = 30_000;

    private final Context context;
    private final ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService peerExecutor = Executors.newFixedThreadPool(4);
    private final AtomicBoolean closed = new AtomicBoolean(false);
    private final AtomicInteger activeSessions = new AtomicInteger(0);
    private final AtomicLong nextSessionId = new AtomicLong(
            (System.currentTimeMillis() << 12) ^ Process.myPid());
    private LocalServerSocket server;

    HardwareCodecBroker(Context context) {
        this.context = BfuPreferences.deviceProtectedContext(context).getApplicationContext();
    }

    synchronized void start() throws IOException {
        if (server != null) return;
        server = new LocalServerSocket(HardwareCodecProtocol.SOCKET_NAME);
        HardwareCodecProbe.writeBrokerStatus(context, "LISTENING protocol="
                + HardwareCodecProtocol.VERSION + " socket=@"
                + HardwareCodecProtocol.SOCKET_NAME
                + " transport=abstract_unix peer_uid=root active_sessions=0");
        HardwareCodecProbe.recordBrokerEvent(context, "LISTENING socket=@"
                + HardwareCodecProtocol.SOCKET_NAME + " protocol="
                + HardwareCodecProtocol.VERSION + " peer_uid=root");
        acceptExecutor.execute(this::acceptLoop);
    }

    private void acceptLoop() {
        while (!closed.get()) {
            try {
                LocalSocket socket = server.accept();
                Credentials credentials = socket.getPeerCredentials();
                if (credentials == null || (credentials.getUid() != 0
                        && credentials.getUid() != Process.myUid())) {
                    int rejectedUid = credentials == null ? -1 : credentials.getUid();
                    int rejectedPid = credentials == null ? -1 : credentials.getPid();
                    HardwareCodecProbe.recordBrokerEvent(context, "PEER_REJECTED uid="
                            + rejectedUid + " pid=" + rejectedPid);
                    socket.close();
                    continue;
                }
                peerExecutor.execute(() -> handlePeer(socket, credentials));
            } catch (IOException e) {
                if (!closed.get()) {
                    HardwareCodecProbe.recordBrokerEvent(context,
                            "ACCEPT_FAILED error=" + safe(e));
                }
            } catch (RuntimeException e) {
                HardwareCodecProbe.recordBrokerEvent(context,
                        "ACCEPT_RUNTIME_FAILED error=" + safe(e));
            }
        }
    }

    private void handlePeer(LocalSocket socket, Credentials credentials) {
        Map<Long, CodecSession> sessions = new HashMap<>();
        int uid = -1;
        int pid = -1;
        try (LocalSocket peer = socket;
             DataInputStream input = new DataInputStream(new BufferedInputStream(
                     peer.getInputStream()));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(
                     peer.getOutputStream()))) {
            peer.setSoTimeout(PEER_TIMEOUT_MS);
            uid = credentials.getUid();
            pid = credentials.getPid();
            HardwareCodecProbe.recordBrokerEvent(context, "PEER_CONNECTED uid="
                    + uid + " pid=" + pid);
            while (!closed.get()) {
                Request request;
                try {
                    request = readRequest(input);
                } catch (EOFException e) {
                    break;
                } catch (ProtocolException e) {
                    writeResponse(output, e.type, e.sessionId, e.requestId,
                            e.status, textPayload(e.getMessage()));
                    break;
                }
                dispatch(request, sessions, output);
            }
        } catch (IOException | RuntimeException e) {
            if (!closed.get()) {
                HardwareCodecProbe.recordBrokerEvent(context, "PEER_FAILED uid="
                        + uid + " pid=" + pid + " error=" + safe(e));
            }
        } finally {
            for (CodecSession session : sessions.values()) closeSession(session);
            HardwareCodecProbe.recordBrokerEvent(context, "PEER_CLOSED uid="
                    + uid + " pid=" + pid);
        }
    }

    private Request readRequest(DataInputStream input) throws IOException, ProtocolException {
        int magic = input.readInt();
        int version = input.readUnsignedShort();
        int type = input.readUnsignedShort();
        int flags = input.readInt();
        long sessionId = input.readLong();
        int payloadLength = input.readInt();
        int requestId = input.readInt();
        int reserved = input.readInt();
        if (magic != HardwareCodecProtocol.MAGIC) {
            throw new ProtocolException(type, sessionId, requestId,
                    HardwareCodecProtocol.ERROR_PROTOCOL, "invalid protocol magic");
        }
        if (version != HardwareCodecProtocol.VERSION) {
            throw new ProtocolException(type, sessionId, requestId,
                    HardwareCodecProtocol.ERROR_VERSION, "unsupported protocol version");
        }
        if ((type & HardwareCodecProtocol.RESPONSE_BIT) != 0 || flags != 0
                || reserved != 0 || requestId <= 0) {
            throw new ProtocolException(type, sessionId, requestId,
                    HardwareCodecProtocol.ERROR_PROTOCOL, "invalid request header");
        }
        int maximum = type == HardwareCodecProtocol.INPUT
                ? HardwareCodecProtocol.MAX_MEDIA_PAYLOAD
                : HardwareCodecProtocol.MAX_CONTROL_PAYLOAD;
        if (payloadLength < 0 || payloadLength > maximum) {
            throw new ProtocolException(type, sessionId, requestId,
                    HardwareCodecProtocol.ERROR_LIMIT, "payload length exceeds limit");
        }
        byte[] payload = new byte[payloadLength];
        input.readFully(payload);
        return new Request(type, sessionId, requestId, payload);
    }

    private void dispatch(Request request, Map<Long, CodecSession> sessions,
                          DataOutputStream output) throws IOException {
        try {
            switch (request.type) {
                case HardwareCodecProtocol.HELLO:
                    requireEmpty(request);
                    writeResponse(output, request.type, 0, request.requestId,
                            HardwareCodecProtocol.OK, helloPayload());
                    return;
                case HardwareCodecProtocol.CAPABILITIES:
                    requireEmpty(request);
                    writeResponse(output, request.type, 0, request.requestId,
                            HardwareCodecProtocol.OK, capabilitiesPayload());
                    return;
                case HardwareCodecProtocol.CREATE:
                    create(request, sessions, output);
                    return;
                case HardwareCodecProtocol.INPUT:
                    input(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.OUTPUT:
                    output(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.FLUSH:
                    requireEmpty(request);
                    requireSession(request, sessions).flush();
                    writeResponse(output, request.type, request.sessionId,
                            request.requestId, HardwareCodecProtocol.OK, new byte[0]);
                    return;
                case HardwareCodecProtocol.EOS:
                    eos(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.CLOSE:
                    requireEmpty(request);
                    CodecSession removed = sessions.remove(request.sessionId);
                    if (removed == null) throw sessionError("unknown session");
                    closeSession(removed);
                    writeResponse(output, request.type, request.sessionId,
                            request.requestId, HardwareCodecProtocol.OK, new byte[0]);
                    return;
                default:
                    throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                            "unsupported message type");
            }
        } catch (RequestException e) {
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    e.status, textPayload(e.getMessage()));
        } catch (IOException e) {
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    HardwareCodecProtocol.ERROR_IO, textPayload(safe(e)));
        } catch (RuntimeException e) {
            HardwareCodecProbe.recordBrokerEvent(context, "REQUEST_CODEC_FAILED type="
                    + request.type + " session=" + request.sessionId + " error=" + safe(e));
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    HardwareCodecProtocol.ERROR_CODEC, textPayload(safe(e)));
        }
    }

    private void create(Request request, Map<Long, CodecSession> sessions,
                        DataOutputStream output) throws IOException, RequestException {
        if (request.sessionId != 0 || request.payload.length
                != HardwareCodecProtocol.CREATE_PAYLOAD_BYTES) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "invalid create request");
        }
        if (sessions.size() >= HardwareCodecProtocol.MAX_SESSIONS_PER_PEER
                || !reserveGlobalSession()) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "hardware codec session limit reached");
        }
        boolean reserved = true;
        try {
            ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
            int mode = values.getInt();
            int codec = values.getInt();
            int width = values.getInt();
            int height = values.getInt();
            int frameRate = values.getInt();
            int bitrate = values.getInt();
            int colorFormat = values.getInt();
            long sessionId = nextSessionId.incrementAndGet();
            CodecSession session = CodecSession.create(sessionId, mode, codec, width,
                    height, frameRate, bitrate, colorFormat);
            sessions.put(sessionId, session);
            reserved = false;
            HardwareCodecProbe.recordBrokerEvent(context, "SESSION_CREATED id="
                    + sessionId + " mode=" + mode + " mime=" + session.mime
                    + " codec=" + session.codecName + " size=" + width + "x" + height);
            writeResponse(output, request.type, sessionId, request.requestId,
                    HardwareCodecProtocol.OK, textPayload(session.description()));
        } finally {
            if (reserved) activeSessions.decrementAndGet();
        }
    }

    private void input(Request request, CodecSession session, DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length < 16) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "input payload is too short");
        }
        ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
        long presentationTimeUs = values.getLong();
        int flags = values.getInt();
        int length = values.getInt();
        if (length < 0 || length != values.remaining()) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "input payload length mismatch");
        }
        int status = session.queue(values.slice(), presentationTimeUs, flags);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                status, new byte[0]);
    }

    private void output(Request request, CodecSession session, DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length != 4) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "output request must contain timeout_ms");
        }
        int timeoutMs = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN).getInt();
        if (timeoutMs < 0 || timeoutMs > 1000) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "output timeout must be 0..1000ms");
        }
        OutputRecord record = session.dequeue(timeoutMs);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                record.status, record.payload);
    }

    private void eos(Request request, CodecSession session, DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length != 8) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "EOS request must contain pts_us");
        }
        long presentationTimeUs = ByteBuffer.wrap(request.payload)
                .order(ByteOrder.BIG_ENDIAN).getLong();
        int status = session.queueEos(presentationTimeUs);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                status, new byte[0]);
    }

    private CodecSession requireSession(Request request, Map<Long, CodecSession> sessions)
            throws RequestException {
        CodecSession session = sessions.get(request.sessionId);
        if (request.sessionId == 0 || session == null) throw sessionError("unknown session");
        return session;
    }

    private static RequestException sessionError(String message) {
        return new RequestException(HardwareCodecProtocol.ERROR_SESSION, message);
    }

    private static void requireEmpty(Request request) throws RequestException {
        if (request.payload.length != 0) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "message payload must be empty");
        }
    }

    private boolean reserveGlobalSession() {
        while (true) {
            int current = activeSessions.get();
            if (current >= HardwareCodecProtocol.MAX_SESSIONS) return false;
            if (activeSessions.compareAndSet(current, current + 1)) return true;
        }
    }

    private void closeSession(CodecSession session) {
        try {
            session.close();
        } finally {
            activeSessions.decrementAndGet();
            HardwareCodecProbe.recordBrokerEvent(context, "SESSION_CLOSED id="
                    + session.id);
        }
    }

    private byte[] helloPayload() {
        try {
            JSONObject root = new JSONObject();
            root.put("protocol", HardwareCodecProtocol.VERSION);
            root.put("socket", "@" + HardwareCodecProtocol.SOCKET_NAME);
            root.put("peer_policy", "uid_0");
            root.put("max_sessions", HardwareCodecProtocol.MAX_SESSIONS);
            root.put("max_sessions_per_peer", HardwareCodecProtocol.MAX_SESSIONS_PER_PEER);
            root.put("max_media_payload", HardwareCodecProtocol.MAX_MEDIA_PAYLOAD);
            root.put("messages", "capabilities,create,input,output,flush,eos,close");
            return textPayload(root.toString());
        } catch (JSONException e) {
            return textPayload("{\"protocol\":1}");
        }
    }

    private byte[] capabilitiesPayload() throws IOException {
        String capabilities = HardwareCodecProbe.readCapabilities(context);
        return textPayload(capabilities.isEmpty() ? "{}" : capabilities);
    }

    private static void writeResponse(DataOutputStream output, int type, long sessionId,
                                      int requestId, int status, byte[] payload)
            throws IOException {
        output.writeInt(HardwareCodecProtocol.MAGIC);
        output.writeShort(HardwareCodecProtocol.VERSION);
        output.writeShort(type | HardwareCodecProtocol.RESPONSE_BIT);
        output.writeInt(0);
        output.writeLong(sessionId);
        output.writeInt(payload.length);
        output.writeInt(requestId);
        output.writeInt(status);
        output.write(payload);
        output.flush();
    }

    private static byte[] textPayload(String value) {
        if (value == null) value = "unknown";
        byte[] bytes = value.replace('\0', ' ').getBytes(StandardCharsets.UTF_8);
        if (bytes.length <= HardwareCodecProtocol.MAX_CONTROL_PAYLOAD) return bytes;
        byte[] bounded = new byte[HardwareCodecProtocol.MAX_CONTROL_PAYLOAD];
        System.arraycopy(bytes, 0, bounded, 0, bounded.length);
        return bounded;
    }

    private static String safe(Throwable error) {
        String message = error.getClass().getSimpleName() + ": " + error.getMessage();
        String sanitized = BfuSu.sanitize(message);
        if (sanitized == null || sanitized.trim().isEmpty()) return "unknown";
        return sanitized.replace('\n', ' ').replace('\r', ' ');
    }

    @Override
    public synchronized void close() {
        if (!closed.compareAndSet(false, true)) return;
        if (server != null) {
            try {
                server.close();
            } catch (IOException e) {
                Log.w(TAG, "Could not close hardware codec broker socket", e);
            }
            server = null;
        }
        acceptExecutor.shutdownNow();
        peerExecutor.shutdownNow();
        HardwareCodecProbe.writeBrokerStatus(context, "STOPPED protocol="
                + HardwareCodecProtocol.VERSION + " socket=@"
                + HardwareCodecProtocol.SOCKET_NAME);
        HardwareCodecProbe.recordBrokerEvent(context, "STOPPED");
    }

    private static final class Request {
        final int type;
        final long sessionId;
        final int requestId;
        final byte[] payload;

        Request(int type, long sessionId, int requestId, byte[] payload) {
            this.type = type;
            this.sessionId = sessionId;
            this.requestId = requestId;
            this.payload = payload;
        }
    }

    private static final class ProtocolException extends Exception {
        final int type;
        final long sessionId;
        final int requestId;
        final int status;

        ProtocolException(int type, long sessionId, int requestId, int status,
                          String message) {
            super(message);
            this.type = type;
            this.sessionId = sessionId;
            this.requestId = requestId;
            this.status = status;
        }
    }

    private static final class RequestException extends Exception {
        final int status;

        RequestException(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    private static final class OutputRecord {
        final int status;
        final byte[] payload;

        OutputRecord(int status, byte[] payload) {
            this.status = status;
            this.payload = payload;
        }
    }

    private static final class CodecSession implements Closeable {
        final long id;
        final String mime;
        final String codecName;
        final String classification;
        final int colorFormat;
        private final MediaCodec codec;
        private boolean closed;

        private CodecSession(long id, String mime, String codecName,
                             String classification, int colorFormat, MediaCodec codec) {
            this.id = id;
            this.mime = mime;
            this.codecName = codecName;
            this.classification = classification;
            this.colorFormat = colorFormat;
            this.codec = codec;
        }

        static CodecSession create(long id, int mode, int codecId, int width,
                                   int height, int frameRate, int bitrate,
                                   int colorFormat) throws RequestException {
            if (mode != HardwareCodecProtocol.MODE_DECODE
                    && mode != HardwareCodecProtocol.MODE_ENCODE) {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "mode must be decode or encode");
            }
            String mime;
            if (codecId == HardwareCodecProtocol.CODEC_AVC) {
                mime = HardwareCodecProbe.MIME_AVC;
            } else if (codecId == HardwareCodecProtocol.CODEC_HEVC) {
                mime = HardwareCodecProbe.MIME_HEVC;
            } else {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "codec must be AVC or HEVC");
            }
            if (width < 16 || width > 4096 || height < 16 || height > 4096
                    || frameRate < 1 || frameRate > 240 || bitrate < 1_000
                    || bitrate > 100_000_000) {
                throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                        "codec parameters exceed bounded limits");
            }
            boolean encoder = mode == HardwareCodecProtocol.MODE_ENCODE;
            java.util.List<HardwareCodecProbe.CodecSelection> selections =
                    HardwareCodecProbe.selectHardwareCodecs(mime, encoder);
            if (selections.isEmpty()) {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "no conservatively classified hardware codec is available");
            }
            String lastError = "unknown";
            for (HardwareCodecProbe.CodecSelection selected : selections) {
                MediaCodec instance = null;
                try {
                    instance = MediaCodec.createByCodecName(selected.name);
                    MediaFormat format = MediaFormat.createVideoFormat(mime, width, height);
                    format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
                    format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE,
                            HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16);
                    int configuredColorFormat = 0;
                    if (encoder) {
                        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
                        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
                        configuredColorFormat = selectEncoderColorFormat(selected,
                                colorFormat);
                        format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                                configuredColorFormat);
                    }
                    instance.configure(format, null, null, encoder
                            ? MediaCodec.CONFIGURE_FLAG_ENCODE : 0);
                    instance.start();
                    return new CodecSession(id, mime, selected.name,
                            selected.classification, configuredColorFormat, instance);
                } catch (IOException | RuntimeException | RequestException e) {
                    lastError = safe(e);
                    if (instance != null) {
                        try {
                            instance.release();
                        } catch (RuntimeException ignored) {
                            // Try the next hardware candidate.
                        }
                    }
                }
            }
            throw new RequestException(HardwareCodecProtocol.ERROR_CODEC, lastError);
        }

        private static int selectEncoderColorFormat(
                HardwareCodecProbe.CodecSelection selection, int requested)
                throws RequestException {
            if (requested != 0) {
                for (int available : selection.colorFormats) {
                    if (available == requested) return requested;
                }
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "requested encoder color format is unavailable");
            }
            int[] preferred = {
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
            };
            for (int candidate : preferred) {
                for (int available : selection.colorFormats) {
                    if (available == candidate) return candidate;
                }
            }
            throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                    "hardware encoder has no supported YUV420 ByteBuffer format");
        }

        String description() {
            return "{\"codec_name\":\"" + json(codecName)
                    + "\",\"mime\":\"" + json(mime)
                    + "\",\"classification\":\"" + json(classification)
                    + "\",\"color_format\":" + colorFormat + "}";
        }

        int queue(ByteBuffer source, long presentationTimeUs, int flags)
                throws RequestException {
            ensureOpen();
            int index = codec.dequeueInputBuffer(100_000L);
            if (index < 0) return HardwareCodecProtocol.AGAIN;
            ByteBuffer destination = codec.getInputBuffer(index);
            if (destination == null || source.remaining() > destination.capacity()) {
                codec.queueInputBuffer(index, 0, 0, presentationTimeUs, 0);
                throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                        "input packet exceeds codec buffer capacity");
            }
            destination.clear();
            destination.put(source);
            codec.queueInputBuffer(index, 0, destination.position(), presentationTimeUs,
                    flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
            return HardwareCodecProtocol.OK;
        }

        int queueEos(long presentationTimeUs) throws RequestException {
            ensureOpen();
            int index = codec.dequeueInputBuffer(100_000L);
            if (index < 0) return HardwareCodecProtocol.AGAIN;
            codec.queueInputBuffer(index, 0, 0, presentationTimeUs,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            return HardwareCodecProtocol.OK;
        }

        OutputRecord dequeue(int timeoutMs) throws RequestException {
            ensureOpen();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            for (int attempt = 0; attempt < 3; attempt++) {
                int index = codec.dequeueOutputBuffer(info, timeoutMs * 1000L);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    return new OutputRecord(HardwareCodecProtocol.FORMAT_CHANGED,
                            textPayload(codec.getOutputFormat().toString()));
                }
                if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) continue;
                if (index < 0) continue;
                if (info.size > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16) {
                    codec.releaseOutputBuffer(index, false);
                    throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                            "codec output exceeds protocol limit");
                }
                ByteBuffer source = codec.getOutputBuffer(index);
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(16 + info.size);
                DataOutputStream output = new DataOutputStream(bytes);
                try {
                    output.writeLong(info.presentationTimeUs);
                    output.writeInt(info.flags);
                    output.writeInt(info.size);
                    if (info.size > 0) {
                        if (source == null) {
                            throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                                    "codec returned a null output buffer");
                        }
                        ByteBuffer copy = source.duplicate();
                        copy.position(info.offset);
                        copy.limit(info.offset + info.size);
                        byte[] chunk = new byte[Math.min(64 * 1024, info.size)];
                        while (copy.hasRemaining()) {
                            int count = Math.min(copy.remaining(), chunk.length);
                            copy.get(chunk, 0, count);
                            output.write(chunk, 0, count);
                        }
                    }
                    output.flush();
                    return new OutputRecord(HardwareCodecProtocol.OK,
                            bytes.toByteArray());
                } catch (IOException e) {
                    throw new RequestException(HardwareCodecProtocol.ERROR_IO, safe(e));
                } finally {
                    codec.releaseOutputBuffer(index, false);
                }
            }
            return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
        }

        void flush() throws RequestException {
            ensureOpen();
            codec.flush();
        }

        private void ensureOpen() throws RequestException {
            if (closed) throw sessionError("session is closed");
        }

        @Override
        public void close() {
            if (closed) return;
            closed = true;
            try {
                codec.stop();
            } catch (RuntimeException ignored) {
                // A failed vendor codec must not affect Debian or the broker.
            }
            try {
                codec.release();
            } catch (RuntimeException ignored) {
                // Process teardown remains independent from vendor cleanup.
            }
        }

        private static String json(String value) {
            return value.replace("\\", "\\\\").replace("\"", "\\\"");
        }
    }
}
