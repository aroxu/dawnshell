package me.aroxu.dawnshell;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Debug;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.Image;
import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Process;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.SystemClock;
import android.os.UserManager;
import android.system.ErrnoException;
import android.system.Os;
import android.view.Surface;
import android.util.Log;
import android.graphics.Rect;

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
import java.io.FileDescriptor;
import java.io.File;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Root-authenticated, versioned local bridge between Debian and MediaCodec. */
final class HardwareCodecBroker implements Closeable {

    private static final String TAG = "DawnShellCodec";
    private static final int PEER_TIMEOUT_MS = 30_000;
    /** Holds one maximum media record plus its framing header. */
    private static final int SOCKET_BUFFER_BYTES =
            HardwareCodecProtocol.MAX_MEDIA_PAYLOAD + 64 * 1024;
    /** Bounded write size that stays below conservative socket buffers. */
    private static final int SOCKET_CHUNK_BYTES = 8 * 1024;

    private final Context context;
    private final ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService peerExecutor = Executors.newFixedThreadPool(4);
    private final Set<LocalSocket> peerSockets = ConcurrentHashMap.newKeySet();
    private final AtomicBoolean closed = new AtomicBoolean(false);
    private final AtomicInteger activeSessions = new AtomicInteger(0);
    private final AtomicInteger activeTranscoders = new AtomicInteger(0);
    private final AtomicInteger activePeers = new AtomicInteger(0);
    private final AtomicInteger peakActiveSessions = new AtomicInteger(0);
    private final AtomicInteger peakActivePeers = new AtomicInteger(0);
    private final AtomicLong acceptedPeers = new AtomicLong(0);
    private final AtomicLong rejectedPeers = new AtomicLong(0);
    private final AtomicLong totalSessionsCreated = new AtomicLong(0);
    private final AtomicLong totalSessionsClosed = new AtomicLong(0);
    private final AtomicLong totalRequestErrors = new AtomicLong(0);
    private final AtomicLong totalSharedInputBytes = new AtomicLong(0);
    private final AtomicLong totalSharedOutputBytes = new AtomicLong(0);
    private final AtomicLong peakSharedTransferBytes = new AtomicLong(0);
    private final AtomicLong totalInputRecords = new AtomicLong(0);
    private final AtomicLong totalOutputRecords = new AtomicLong(0);
    private final AtomicLong totalInputBytes = new AtomicLong(0);
    private final AtomicLong totalOutputBytes = new AtomicLong(0);
    private final AtomicLong totalInputDequeueTimeouts = new AtomicLong(0);
    private final AtomicLong totalOutputDequeueTimeouts = new AtomicLong(0);
    private final AtomicLong peakInputPayloadBytes = new AtomicLong(0);
    private final AtomicLong peakOutputPayloadBytes = new AtomicLong(0);
    private final AtomicLong peakQueueDepth = new AtomicLong(0);
    private final long startedElapsedRealtime = SystemClock.elapsedRealtime();
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
                if (closed.get()) {
                    socket.close();
                    break;
                }
                Credentials credentials = socket.getPeerCredentials();
                if (credentials == null || credentials.getUid() != 0) {
                    int rejectedUid = credentials == null ? -1 : credentials.getUid();
                    int rejectedPid = credentials == null ? -1 : credentials.getPid();
                    rejectedPeers.incrementAndGet();
                    HardwareCodecProbe.recordBrokerEvent(context, "PEER_REJECTED uid="
                            + rejectedUid + " pid=" + rejectedPid);
                    socket.close();
                    continue;
                }
                if (!reservePeer()) {
                    rejectedPeers.incrementAndGet();
                    HardwareCodecProbe.recordBrokerEvent(context,
                            "PEER_REJECTED uid=" + credentials.getUid()
                                    + " pid=" + credentials.getPid()
                                    + " reason=peer_limit");
                    socket.close();
                    continue;
                }
                acceptedPeers.incrementAndGet();
                peerSockets.add(socket);
                try {
                    peerExecutor.execute(() -> handlePeer(socket, credentials));
                } catch (RejectedExecutionException e) {
                    peerSockets.remove(socket);
                    activePeers.decrementAndGet();
                    socket.close();
                    if (!closed.get()) throw e;
                }
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
        Map<Long, CodecBridgeSession> sessions = new HashMap<>();
        int uid = credentials.getUid();
        int pid = credentials.getPid();
        try (LocalSocket peer = socket;
             DataInputStream input = new DataInputStream(new BufferedInputStream(
                     peer.getInputStream()));
             DataOutputStream output = new DataOutputStream(new BufferedOutputStream(
                     peer.getOutputStream()))) {
            peer.setSoTimeout(PEER_TIMEOUT_MS);
            // LocalSocket defaults to a small kernel buffer, so a single large
            // media record fails with EMSGSIZE ("Message too long"). Raise both
            // directions to hold one maximum-size framed record.
            configureSocketBuffers(peer);
            HardwareCodecProbe.recordBrokerEvent(context, "PEER_CONNECTED uid="
                    + uid + " pid=" + pid);
            while (!closed.get()) {
                Request request;
                try {
                    request = readRequest(peer, input);
                } catch (EOFException e) {
                    break;
                } catch (ProtocolException e) {
                    writeResponse(output, e.type, e.sessionId, e.requestId,
                            e.status, textPayload(e.getMessage()));
                    break;
                }
                try {
                    dispatch(request, sessions, output);
                } finally {
                    request.closeDescriptors();
                }
            }
        } catch (IOException | RuntimeException e) {
            if (!closed.get()) {
                HardwareCodecProbe.recordBrokerEvent(context, "PEER_FAILED uid="
                        + uid + " pid=" + pid + " error=" + safe(e));
            }
        } finally {
            for (CodecBridgeSession session : sessions.values()) closeSession(session);
            peerSockets.remove(socket);
            activePeers.decrementAndGet();
            HardwareCodecProbe.recordBrokerEvent(context, "PEER_CLOSED uid="
                    + uid + " pid=" + pid);
        }
    }

    private static void configureSocketBuffers(LocalSocket peer) {
        try {
            if (peer.getSendBufferSize() < SOCKET_BUFFER_BYTES) {
                peer.setSendBufferSize(SOCKET_BUFFER_BYTES);
            }
            if (peer.getReceiveBufferSize() < SOCKET_BUFFER_BYTES) {
                peer.setReceiveBufferSize(SOCKET_BUFFER_BYTES);
            }
        } catch (IOException | RuntimeException e) {
            // A kernel that caps the buffer still works through short writes.
            Log.w(TAG, "Could not enlarge codec socket buffers", e);
        }
    }

    private Request readRequest(LocalSocket peer, DataInputStream input)
            throws IOException, ProtocolException {
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
        FileDescriptor[] descriptors = peer.getAncillaryFileDescriptors();
        boolean sharedMemoryRequest = type == HardwareCodecProtocol.INPUT_SHARED_MEMORY
                || type == HardwareCodecProtocol.OUTPUT_SHARED_MEMORY;
        if (sharedMemoryRequest) {
            if (descriptors == null || descriptors.length != 1) {
                closeDescriptors(descriptors);
                throw new ProtocolException(type, sessionId, requestId,
                        HardwareCodecProtocol.ERROR_PROTOCOL,
                        "shared-memory request requires exactly one file descriptor");
            }
        } else if (descriptors != null && descriptors.length > 0) {
            closeDescriptors(descriptors);
            throw new ProtocolException(type, sessionId, requestId,
                    HardwareCodecProtocol.ERROR_PROTOCOL,
                    "file descriptors are forbidden for this request");
        }
        return new Request(type, sessionId, requestId, payload, descriptors);
    }

    private void dispatch(Request request, Map<Long, CodecBridgeSession> sessions,
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
                case HardwareCodecProtocol.HEALTH:
                    requireEmpty(request);
                    if (request.sessionId != 0) {
                        throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                                "health request must use session 0");
                    }
                    writeResponse(output, request.type, 0, request.requestId,
                            HardwareCodecProtocol.OK, healthPayload());
                    return;
                case HardwareCodecProtocol.CREATE:
                    create(request, sessions, output);
                    return;
                case HardwareCodecProtocol.CREATE_TRANSCODER:
                    createTranscoder(request, sessions, output);
                    return;
                case HardwareCodecProtocol.INPUT:
                    input(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.OUTPUT:
                    output(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.INPUT_SHARED_MEMORY:
                    inputSharedMemory(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.OUTPUT_SHARED_MEMORY:
                    outputSharedMemory(request, requireSession(request, sessions), output);
                    return;
                case HardwareCodecProtocol.REQUEST_KEYFRAME:
                    requireEmpty(request);
                    requireSession(request, sessions).requestKeyframe();
                    writeResponse(output, request.type, request.sessionId,
                            request.requestId, HardwareCodecProtocol.OK, new byte[0]);
                    return;
                case HardwareCodecProtocol.SESSION_STATS:
                    requireEmpty(request);
                    writeResponse(output, request.type, request.sessionId,
                            request.requestId, HardwareCodecProtocol.OK,
                            textPayload(requireSession(request, sessions).statistics()));
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
                    CodecBridgeSession removed = sessions.remove(request.sessionId);
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
            totalRequestErrors.incrementAndGet();
            CodecBridgeSession failed = sessions.get(request.sessionId);
            if (failed != null) failed.recordError();
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    e.status, textPayload(e.getMessage()));
        } catch (IOException e) {
            totalRequestErrors.incrementAndGet();
            CodecBridgeSession failed = sessions.get(request.sessionId);
            if (failed != null) failed.recordError();
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    HardwareCodecProtocol.ERROR_IO, textPayload(safe(e)));
        } catch (RuntimeException e) {
            totalRequestErrors.incrementAndGet();
            CodecBridgeSession failed = sessions.get(request.sessionId);
            if (failed != null) failed.recordError();
            HardwareCodecProbe.recordBrokerEvent(context, "REQUEST_CODEC_FAILED type="
                    + request.type + " session=" + request.sessionId + " error=" + safe(e));
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    HardwareCodecProtocol.ERROR_CODEC, textPayload(safe(e)));
        }
    }

    private void create(Request request, Map<Long, CodecBridgeSession> sessions,
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
            totalSessionsCreated.incrementAndGet();
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

    private void createTranscoder(Request request,
                                  Map<Long, CodecBridgeSession> sessions,
                                  DataOutputStream output)
            throws IOException, RequestException {
        if (request.sessionId != 0 || request.payload.length
                != HardwareCodecProtocol.CREATE_TRANSCODER_PAYLOAD_BYTES) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "invalid transcoder create request");
        }
        if (sessions.size() >= HardwareCodecProtocol.MAX_SESSIONS_PER_PEER
                || !reserveGlobalSession()) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "hardware codec session limit reached");
        }
        if (!activeTranscoders.compareAndSet(0, 1)) {
            activeSessions.decrementAndGet();
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "only one Surface transcoder is allowed");
        }
        boolean reserved = true;
        try {
            ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
            int inputCodec = values.getInt();
            int outputCodec = values.getInt();
            int width = values.getInt();
            int height = values.getInt();
            int frameRate = values.getInt();
            int bitrate = values.getInt();
            long sessionId = nextSessionId.incrementAndGet();
            SurfaceTranscodeSession session = SurfaceTranscodeSession.create(sessionId,
                    inputCodec, outputCodec, width, height, frameRate, bitrate);
            sessions.put(sessionId, session);
            totalSessionsCreated.incrementAndGet();
            reserved = false;
            HardwareCodecProbe.recordBrokerEvent(context, "TRANSCODER_CREATED id="
                    + sessionId + " input=" + session.decoderName + " output="
                    + session.encoderName + " size=" + width + "x" + height);
            writeResponse(output, request.type, sessionId, request.requestId,
                    HardwareCodecProtocol.OK, textPayload(session.description()));
        } finally {
            if (reserved) {
                activeTranscoders.decrementAndGet();
                activeSessions.decrementAndGet();
            }
        }
    }

    private void input(Request request, CodecBridgeSession session, DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length < 16) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "input payload is too short");
        }
        ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
        long presentationTimeUs = values.getLong();
        int flags = values.getInt();
        int length = values.getInt();
        if (length <= 0 || length != values.remaining()) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "input payload length mismatch");
        }
        requireInputFlags(flags);
        int status = timedQueue(session, values.slice(), presentationTimeUs, flags);
        session.recordSocketInput(length);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                status, new byte[0]);
    }

    private void output(Request request, CodecBridgeSession session, DataOutputStream output)
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
        OutputRecord record = timedDequeue(session, timeoutMs);
        if (record.status == HardwareCodecProtocol.OK) {
            session.recordSocketOutput(record.payload.length);
        }
        writeResponse(output, request.type, request.sessionId, request.requestId,
                record.status, record.payload);
    }

    private void inputSharedMemory(Request request, CodecBridgeSession session,
                                   DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length != HardwareCodecProtocol.SHARED_INPUT_PAYLOAD_BYTES) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "shared input payload must contain pts_us, flags, and length");
        }
        ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
        long presentationTimeUs = values.getLong();
        int flags = values.getInt();
        int length = values.getInt();
        if (length <= 0 || length > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "shared input length exceeds limit");
        }
        requireInputFlags(flags);
        byte[] media = readSharedMemory(request.singleDescriptor(), length);
        session.recordSharedInput(length);
        totalSharedInputBytes.addAndGet(length);
        updateMaximum(peakSharedTransferBytes, length);
        int status = timedQueue(session, ByteBuffer.wrap(media),
                presentationTimeUs, flags);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                status, new byte[0]);
    }

    private void outputSharedMemory(Request request, CodecBridgeSession session,
                                    DataOutputStream output)
            throws IOException, RequestException {
        if (request.payload.length != HardwareCodecProtocol.SHARED_OUTPUT_PAYLOAD_BYTES) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "shared output payload must contain timeout_ms and capacity");
        }
        ByteBuffer values = ByteBuffer.wrap(request.payload).order(ByteOrder.BIG_ENDIAN);
        int timeoutMs = values.getInt();
        int capacity = values.getInt();
        if (timeoutMs < 0 || timeoutMs > 1000) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "output timeout must be 0..1000ms");
        }
        if (capacity < 16 || capacity > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "shared output capacity exceeds limit");
        }
        OutputRecord record = timedDequeue(session, timeoutMs);
        if (record.status != HardwareCodecProtocol.OK) {
            writeResponse(output, request.type, request.sessionId, request.requestId,
                    record.status, record.payload);
            return;
        }
        if (record.payload.length > capacity) {
            throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                    "shared output record exceeds supplied capacity");
        }
        writeSharedMemory(request.singleDescriptor(), record.payload);
        session.recordSharedOutput(record.payload.length);
        totalSharedOutputBytes.addAndGet(record.payload.length);
        updateMaximum(peakSharedTransferBytes, record.payload.length);
        ByteBuffer actualLength = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN);
        actualLength.putInt(record.payload.length);
        writeResponse(output, request.type, request.sessionId, request.requestId,
                HardwareCodecProtocol.OK, actualLength.array());
    }

    private static byte[] readSharedMemory(FileDescriptor descriptor, int length)
            throws IOException {
        byte[] result = new byte[length];
        int offset = 0;
        try {
            while (offset < length) {
                int count = Os.pread(descriptor, result, offset, length - offset, offset);
                if (count <= 0) throw new IOException("shared input ended early");
                offset += count;
            }
        } catch (ErrnoException e) {
            throw new IOException("could not read shared input", e);
        }
        return result;
    }

    private static void writeSharedMemory(FileDescriptor descriptor, byte[] value)
            throws IOException {
        int offset = 0;
        try {
            while (offset < value.length) {
                int count = Os.pwrite(descriptor, value, offset,
                        value.length - offset, offset);
                if (count <= 0) throw new IOException("shared output write stalled");
                offset += count;
            }
        } catch (ErrnoException e) {
            throw new IOException("could not write shared output", e);
        }
    }

    private void eos(Request request, CodecBridgeSession session, DataOutputStream output)
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

    private CodecBridgeSession requireSession(Request request,
                                              Map<Long, CodecBridgeSession> sessions)
            throws RequestException {
        CodecBridgeSession session = sessions.get(request.sessionId);
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

    private static void requireInputFlags(int flags) throws RequestException {
        if ((flags & ~MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
            throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                    "input contains unsupported buffer flags");
        }
    }

    private static int timedQueue(CodecBridgeSession session, ByteBuffer source,
                                  long presentationTimeUs, int flags)
            throws RequestException {
        long started = SystemClock.elapsedRealtimeNanos();
        try {
            return session.queue(source, presentationTimeUs, flags);
        } finally {
            session.counters().recordInputCallLatency(elapsedMicros(started));
        }
    }

    private static OutputRecord timedDequeue(CodecBridgeSession session, int timeoutMs)
            throws RequestException {
        long started = SystemClock.elapsedRealtimeNanos();
        try {
            return session.dequeue(timeoutMs);
        } finally {
            session.counters().recordOutputCallLatency(elapsedMicros(started));
        }
    }

    private static long elapsedMicros(long startedNanos) {
        return Math.max(0L, (SystemClock.elapsedRealtimeNanos() - startedNanos) / 1_000L);
    }

    private boolean reserveGlobalSession() {
        while (true) {
            int current = activeSessions.get();
            if (current >= HardwareCodecProtocol.MAX_SESSIONS) return false;
            if (activeSessions.compareAndSet(current, current + 1)) {
                updateMaximum(peakActiveSessions, current + 1);
                return true;
            }
        }
    }

    private boolean reservePeer() {
        while (true) {
            int current = activePeers.get();
            if (current >= HardwareCodecProtocol.MAX_PEERS) return false;
            if (activePeers.compareAndSet(current, current + 1)) {
                updateMaximum(peakActivePeers, current + 1);
                return true;
            }
        }
    }

    private static void updateMaximum(AtomicInteger target, int value) {
        while (true) {
            int current = target.get();
            if (value <= current || target.compareAndSet(current, value)) return;
        }
    }

    private static void updateMaximum(AtomicLong target, long value) {
        while (true) {
            long current = target.get();
            if (value <= current || target.compareAndSet(current, value)) return;
        }
    }

    private void closeSession(CodecBridgeSession session) {
        SessionCounters counters = session.counters();
        try {
            session.close();
        } finally {
            totalInputRecords.addAndGet(counters.inputRecords);
            totalOutputRecords.addAndGet(counters.outputRecords);
            totalInputBytes.addAndGet(counters.inputBytes);
            totalOutputBytes.addAndGet(counters.outputBytes);
            totalInputDequeueTimeouts.addAndGet(counters.inputAgain);
            totalOutputDequeueTimeouts.addAndGet(counters.outputAgain);
            updateMaximum(peakInputPayloadBytes, counters.maxInputPayloadBytes);
            updateMaximum(peakOutputPayloadBytes, counters.maxOutputPayloadBytes);
            updateMaximum(peakQueueDepth, counters.queueDepthHighWater);
            if (session instanceof SurfaceTranscodeSession) {
                activeTranscoders.decrementAndGet();
            }
            activeSessions.decrementAndGet();
            totalSessionsClosed.incrementAndGet();
            HardwareCodecProbe.recordBrokerEvent(context, "SESSION_CLOSED id="
                    + session.id());
        }
    }

    private byte[] helloPayload() {
        try {
            JSONObject root = new JSONObject();
            root.put("protocol", HardwareCodecProtocol.VERSION);
            root.put("socket", "@" + HardwareCodecProtocol.SOCKET_NAME);
            root.put("peer_policy", "uid_0");
            root.put("max_peers", HardwareCodecProtocol.MAX_PEERS);
            root.put("max_sessions", HardwareCodecProtocol.MAX_SESSIONS);
            root.put("max_sessions_per_peer", HardwareCodecProtocol.MAX_SESSIONS_PER_PEER);
            root.put("max_media_payload", HardwareCodecProtocol.MAX_MEDIA_PAYLOAD);
            root.put("messages", "capabilities,create,input,output,input_shm,output_shm,"
                    + "create_transcoder,request_keyframe,health,session_stats,"
                    + "flush,eos,close");
            root.put("shared_memory", "memfd_scm_rights_with_socket_fallback");
            return textPayload(root.toString());
        } catch (JSONException e) {
            return textPayload("{\"protocol\":1}");
        }
    }

    private byte[] capabilitiesPayload() throws IOException {
        String capabilities = HardwareCodecProbe.readCapabilities(context);
        return textPayload(capabilities.isEmpty() ? "{}" : capabilities);
    }

    private byte[] healthPayload() {
        long uptimeMs = Math.max(0L,
                SystemClock.elapsedRealtime() - startedElapsedRealtime);
        Runtime runtime = Runtime.getRuntime();
        String value = "{\"protocol\":" + HardwareCodecProtocol.VERSION
                + ",\"broker_state\":\"listening\""
                + ",\"pid\":" + Process.myPid()
                + ",\"uptime_ms\":" + uptimeMs
                + ",\"active_peers\":" + activePeers.get()
                + ",\"peak_active_peers\":" + peakActivePeers.get()
                + ",\"accepted_peers\":" + acceptedPeers.get()
                + ",\"rejected_peers\":" + rejectedPeers.get()
                + ",\"active_sessions\":" + activeSessions.get()
                + ",\"peak_active_sessions\":" + peakActiveSessions.get()
                + ",\"active_transcoders\":" + activeTranscoders.get()
                + ",\"sessions_created\":" + totalSessionsCreated.get()
                + ",\"sessions_closed\":" + totalSessionsClosed.get()
                + ",\"request_errors\":" + totalRequestErrors.get()
                + ",\"shared_input_bytes\":" + totalSharedInputBytes.get()
                + ",\"shared_output_bytes\":" + totalSharedOutputBytes.get()
                + ",\"peak_shared_transfer_bytes\":" + peakSharedTransferBytes.get()
                + ",\"input_records\":" + totalInputRecords.get()
                + ",\"output_records\":" + totalOutputRecords.get()
                + ",\"input_bytes\":" + totalInputBytes.get()
                + ",\"output_bytes\":" + totalOutputBytes.get()
                + ",\"input_dequeue_timeouts\":"
                + totalInputDequeueTimeouts.get()
                + ",\"output_dequeue_timeouts\":"
                + totalOutputDequeueTimeouts.get()
                + ",\"peak_input_payload_bytes\":" + peakInputPayloadBytes.get()
                + ",\"peak_output_payload_bytes\":" + peakOutputPayloadBytes.get()
                + ",\"queue_depth_high_water\":" + peakQueueDepth.get()
                + ",\"queue_model\":\"synchronous_bounded_backpressure\""
                + ",\"process_cpu_time_ms\":" + Process.getElapsedCpuTime()
                + ",\"process_rss_kb\":" + Debug.getPss()
                + ",\"open_fd_count\":" + openFileDescriptorCount()
                + ",\"java_heap_used_bytes\":"
                + (runtime.totalMemory() - runtime.freeMemory())
                + ",\"java_heap_max_bytes\":" + runtime.maxMemory()
                + ",\"thermal_status\":" + thermalStatus()
                + ",\"battery_temperature_deci_c\":" + batteryTemperature()
                + ",\"user_unlocked\":" + userUnlocked()
                + ",\"software_fallback\":false}"
                ;
        return textPayload(value);
    }

    private static int openFileDescriptorCount() {
        String[] descriptors = new File("/proc/self/fd").list();
        return descriptors == null ? -1 : descriptors.length;
    }

    private int thermalStatus() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return -1;
        try {
            PowerManager manager = (PowerManager) context.getSystemService(
                    Context.POWER_SERVICE);
            return manager == null ? -1 : manager.getCurrentThermalStatus();
        } catch (RuntimeException ignored) {
            return -1;
        }
    }

    private int batteryTemperature() {
        try {
            Intent battery = context.registerReceiver(null,
                    new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            return battery == null ? -1 : battery.getIntExtra(
                    BatteryManager.EXTRA_TEMPERATURE, -1);
        } catch (RuntimeException ignored) {
            return -1;
        }
    }

    private boolean userUnlocked() {
        try {
            UserManager manager = (UserManager) context.getSystemService(
                    Context.USER_SERVICE);
            return manager != null && manager.isUserUnlocked();
        } catch (RuntimeException ignored) {
            return false;
        }
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
        // A single large write can exceed the kernel socket buffer and fail
        // with EMSGSIZE, so media payloads are written in bounded chunks.
        for (int offset = 0; offset < payload.length; offset += SOCKET_CHUNK_BYTES) {
            output.write(payload, offset,
                    Math.min(SOCKET_CHUNK_BYTES, payload.length - offset));
        }
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

    private static void closeDescriptors(FileDescriptor[] descriptors) {
        if (descriptors == null) return;
        for (FileDescriptor descriptor : descriptors) {
            if (descriptor == null || !descriptor.valid()) continue;
            try {
                Os.close(descriptor);
            } catch (ErrnoException ignored) {
                // The peer lifecycle still closes the LocalSocket itself.
            }
        }
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
        awaitExecutor(acceptExecutor, "accept loop");
        for (LocalSocket peer : peerSockets) {
            try {
                peer.close();
            } catch (IOException e) {
                Log.w(TAG, "Could not close hardware codec peer socket", e);
            }
        }
        peerExecutor.shutdownNow();
        awaitExecutor(peerExecutor, "peer cleanup");
        HardwareCodecProbe.writeBrokerStatus(context, "STOPPED protocol="
                + HardwareCodecProtocol.VERSION + " socket=@"
                + HardwareCodecProtocol.SOCKET_NAME + " active_sessions="
                + activeSessions.get() + " active_peers=" + activePeers.get());
        HardwareCodecProbe.recordBrokerEvent(context, "STOPPED active_sessions="
                + activeSessions.get() + " active_peers=" + activePeers.get());
    }

    private static void awaitExecutor(ExecutorService executor, String label) {
        try {
            if (!executor.awaitTermination(2, TimeUnit.SECONDS)) {
                Log.w(TAG, "Hardware codec " + label
                        + " did not finish within 2 seconds");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.w(TAG, "Interrupted while waiting for hardware codec " + label);
        }
    }

    private static final class Request {
        final int type;
        final long sessionId;
        final int requestId;
        final byte[] payload;
        final FileDescriptor[] descriptors;

        Request(int type, long sessionId, int requestId, byte[] payload,
                FileDescriptor[] descriptors) {
            this.type = type;
            this.sessionId = sessionId;
            this.requestId = requestId;
            this.payload = payload;
            this.descriptors = descriptors;
        }

        FileDescriptor singleDescriptor() throws RequestException {
            if (descriptors == null || descriptors.length != 1
                    || descriptors[0] == null || !descriptors[0].valid()) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "shared-memory descriptor is unavailable");
            }
            return descriptors[0];
        }

        void closeDescriptors() {
            HardwareCodecBroker.closeDescriptors(descriptors);
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

    private static final class SessionCounters {
        final long createdElapsedRealtime = SystemClock.elapsedRealtime();
        final long createdProcessCpuTimeMs = Process.getElapsedCpuTime();
        long inputRecords;
        long inputBytes;
        long inputFrames;
        long outputRecords;
        long outputBytes;
        long outputFrames;
        long socketInputBytes;
        long socketOutputBytes;
        long sharedInputBytes;
        long sharedOutputBytes;
        long inputAgain;
        long outputAgain;
        long formatChanges;
        long inputEos;
        long outputEos;
        long errors;
        long cpuYuvFrames;
        long surfaceFrames;
        long maxInputPayloadBytes;
        long maxOutputPayloadBytes;
        long queueDepthHighWater;
        long inputCallLatencySamples;
        long inputCallLatencyTotalUs;
        long inputCallLatencyMaxUs;
        long outputCallLatencySamples;
        long outputCallLatencyTotalUs;
        long outputCallLatencyMaxUs;

        void recordInputCallLatency(long latencyUs) {
            inputCallLatencySamples++;
            inputCallLatencyTotalUs += latencyUs;
            inputCallLatencyMaxUs = Math.max(inputCallLatencyMaxUs, latencyUs);
        }

        void recordOutputCallLatency(long latencyUs) {
            outputCallLatencySamples++;
            outputCallLatencyTotalUs += latencyUs;
            outputCallLatencyMaxUs = Math.max(outputCallLatencyMaxUs, latencyUs);
        }

        String json(long id, String kind, String inputCodec, String outputCodec,
                    String transport) {
            long uptimeMs = Math.max(0L,
                    SystemClock.elapsedRealtime() - createdElapsedRealtime);
            long cpuTimeMs = Math.max(0L,
                    Process.getElapsedCpuTime() - createdProcessCpuTimeMs);
            String mediaTransport;
            if (sharedInputBytes + sharedOutputBytes > 0
                    && socketInputBytes + socketOutputBytes > 0) {
                mediaTransport = "mixed";
            } else if (sharedInputBytes + sharedOutputBytes > 0) {
                mediaTransport = "shared_memory";
            } else if (socketInputBytes + socketOutputBytes > 0) {
                mediaTransport = "socket";
            } else {
                mediaTransport = "none";
            }
            return "{\"session_id\":" + id
                    + ",\"kind\":\"" + CodecSession.json(kind) + "\""
                    + ",\"input_codec\":\"" + CodecSession.json(inputCodec) + "\""
                    + ",\"output_codec\":\"" + CodecSession.json(outputCodec) + "\""
                    + ",\"transport\":\"" + CodecSession.json(transport) + "\""
                    + ",\"uptime_ms\":" + uptimeMs
                    + ",\"process_cpu_time_ms\":" + cpuTimeMs
                    + ",\"media_transport\":\"" + mediaTransport + "\""
                    + ",\"input_records\":" + inputRecords
                    + ",\"input_bytes\":" + inputBytes
                    + ",\"input_frames\":" + inputFrames
                    + ",\"output_records\":" + outputRecords
                    + ",\"output_bytes\":" + outputBytes
                    + ",\"output_frames\":" + outputFrames
                    + ",\"socket_input_bytes\":" + socketInputBytes
                    + ",\"socket_output_bytes\":" + socketOutputBytes
                    + ",\"shared_input_bytes\":" + sharedInputBytes
                    + ",\"shared_output_bytes\":" + sharedOutputBytes
                    + ",\"input_again\":" + inputAgain
                    + ",\"output_again\":" + outputAgain
                    + ",\"input_dequeue_timeouts\":" + inputAgain
                    + ",\"output_dequeue_timeouts\":" + outputAgain
                    + ",\"peak_input_payload_bytes\":" + maxInputPayloadBytes
                    + ",\"peak_output_payload_bytes\":" + maxOutputPayloadBytes
                    + ",\"queue_depth_high_water\":" + queueDepthHighWater
                    + ",\"input_call_latency_samples\":" + inputCallLatencySamples
                    + ",\"input_call_latency_avg_us\":"
                    + average(inputCallLatencyTotalUs, inputCallLatencySamples)
                    + ",\"input_call_latency_max_us\":" + inputCallLatencyMaxUs
                    + ",\"output_call_latency_samples\":" + outputCallLatencySamples
                    + ",\"output_call_latency_avg_us\":"
                    + average(outputCallLatencyTotalUs, outputCallLatencySamples)
                    + ",\"output_call_latency_max_us\":" + outputCallLatencyMaxUs
                    + ",\"format_changes\":" + formatChanges
                    + ",\"input_eos\":" + inputEos
                    + ",\"output_eos\":" + outputEos
                    + ",\"errors\":" + errors
                    + ",\"dropped_frames\":0"
                    + ",\"cpu_yuv_frames\":" + cpuYuvFrames
                    + ",\"surface_frames\":" + surfaceFrames
                    + ",\"queue_model\":\"synchronous_bounded_backpressure\"}"
                    ;
        }

        private static long average(long total, long samples) {
            return samples == 0 ? 0L : total / samples;
        }
    }

    private interface CodecBridgeSession extends Closeable {
        long id();
        public int queue(ByteBuffer source, long presentationTimeUs, int flags)
                throws RequestException;
        int queueEos(long presentationTimeUs) throws RequestException;
        OutputRecord dequeue(int timeoutMs) throws RequestException;
        void flush() throws RequestException;
        void requestKeyframe() throws RequestException;
        String statistics();
        SessionCounters counters();
        void recordSocketInput(int length);
        void recordSocketOutput(int length);
        void recordSharedInput(int length);
        void recordSharedOutput(int length);
        void recordError();
        @Override void close();
    }

    /** Decoder output Surface wired directly to an encoder input Surface. */
    private static final class SurfaceTranscodeSession implements CodecBridgeSession {
        final long sessionId;
        final String inputMime;
        final String outputMime;
        final String decoderName;
        final String encoderName;
        private final MediaCodec decoder;
        private final MediaCodec encoder;
        private final Surface encoderInputSurface;
        private final SessionCounters counters = new SessionCounters();
        private boolean inputEosQueued;
        private boolean encoderEosSignaled;
        private boolean closed;

        private SurfaceTranscodeSession(long sessionId, String inputMime,
                                        String outputMime, String decoderName,
                                        String encoderName, MediaCodec decoder,
                                        MediaCodec encoder, Surface encoderInputSurface) {
            this.sessionId = sessionId;
            this.inputMime = inputMime;
            this.outputMime = outputMime;
            this.decoderName = decoderName;
            this.encoderName = encoderName;
            this.decoder = decoder;
            this.encoder = encoder;
            this.encoderInputSurface = encoderInputSurface;
        }

        static SurfaceTranscodeSession create(long sessionId, int inputCodec,
                                               int outputCodec, int width, int height,
                                               int frameRate, int bitrate)
                throws RequestException {
            validateParameters(width, height, frameRate, bitrate);
            String inputMime = mime(inputCodec);
            String outputMime = mime(outputCodec);
            java.util.List<HardwareCodecProbe.CodecSelection> decoders =
                    HardwareCodecProbe.selectHardwareCodecs(inputMime, false);
            java.util.List<HardwareCodecProbe.CodecSelection> encoders =
                    HardwareCodecProbe.selectHardwareCodecs(outputMime, true);
            if (decoders.isEmpty() || encoders.isEmpty()) {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "no hardware decoder/encoder pair is available");
            }
            String lastError = "no encoder advertises COLOR_FormatSurface";
            for (HardwareCodecProbe.CodecSelection selectedEncoder : encoders) {
                if (!supportsSurfaceInput(selectedEncoder)) continue;
                for (HardwareCodecProbe.CodecSelection selectedDecoder : decoders) {
                    MediaCodec decoder = null;
                    MediaCodec encoder = null;
                    Surface inputSurface = null;
                    try {
                        encoder = MediaCodec.createByCodecName(selectedEncoder.name);
                        MediaFormat encoderFormat = MediaFormat.createVideoFormat(
                                outputMime, width, height);
                        encoderFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                                android.media.MediaCodecInfo.CodecCapabilities
                                        .COLOR_FormatSurface);
                        encoderFormat.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
                        encoderFormat.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
                        encoderFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
                        encoder.configure(encoderFormat, null, null,
                                MediaCodec.CONFIGURE_FLAG_ENCODE);
                        inputSurface = encoder.createInputSurface();
                        encoder.start();

                        decoder = MediaCodec.createByCodecName(selectedDecoder.name);
                        MediaFormat decoderFormat = MediaFormat.createVideoFormat(
                                inputMime, width, height);
                        decoderFormat.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate);
                        decoderFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE,
                                HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16);
                        decoder.configure(decoderFormat, inputSurface, null, 0);
                        decoder.start();
                        return new SurfaceTranscodeSession(sessionId, inputMime,
                                outputMime, selectedDecoder.name, selectedEncoder.name,
                                decoder, encoder, inputSurface);
                    } catch (IOException | RuntimeException e) {
                        lastError = safe(e);
                        releaseCodec(decoder);
                        releaseCodec(encoder);
                        if (inputSurface != null) inputSurface.release();
                    }
                }
            }
            throw new RequestException(HardwareCodecProtocol.ERROR_CODEC, lastError);
        }

        private static void validateParameters(int width, int height, int frameRate,
                                               int bitrate) throws RequestException {
            if (width < 16 || width > 4096 || height < 16 || height > 4096
                    || (width & 1) != 0 || (height & 1) != 0
                    || frameRate < 1 || frameRate > 240 || bitrate < 1_000
                    || bitrate > 100_000_000) {
                throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                        "transcoder parameters exceed bounded limits");
            }
        }

        private static String mime(int codecId) throws RequestException {
            if (codecId == HardwareCodecProtocol.CODEC_AVC) {
                return HardwareCodecProbe.MIME_AVC;
            }
            if (codecId == HardwareCodecProtocol.CODEC_HEVC) {
                return HardwareCodecProbe.MIME_HEVC;
            }
            throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                    "transcoder codec must be AVC or HEVC");
        }

        private static boolean supportsSurfaceInput(
                HardwareCodecProbe.CodecSelection selection) {
            int surface = android.media.MediaCodecInfo.CodecCapabilities
                    .COLOR_FormatSurface;
            for (int available : selection.colorFormats) {
                if (available == surface) return true;
            }
            return false;
        }

        private static void releaseCodec(MediaCodec codec) {
            if (codec == null) return;
            try {
                codec.stop();
            } catch (RuntimeException ignored) {
                // A partially configured codec may not have started.
            }
            try {
                codec.release();
            } catch (RuntimeException ignored) {
                // Try the next hardware pair.
            }
        }

        String description() {
            return "{\"transport\":\"surface_zero_copy\",\"decoder_name\":\""
                    + CodecSession.json(decoderName) + "\",\"encoder_name\":\""
                    + CodecSession.json(encoderName) + "\",\"input_mime\":\""
                    + CodecSession.json(inputMime) + "\",\"output_mime\":\""
                    + CodecSession.json(outputMime) + "\"}";
        }

        @Override
        public long id() {
            return sessionId;
        }

        @Override
        public int queue(ByteBuffer source, long presentationTimeUs, int flags)
                throws RequestException {
            ensureOpen();
            if (inputEosQueued) {
                throw sessionError("transcoder input is closed after EOS");
            }
            if (presentationTimeUs < 0) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "transcoder PTS must be non-negative");
            }
            pumpDecoder(0);
            int index = decoder.dequeueInputBuffer(100_000L);
            if (index < 0) {
                counters.inputAgain++;
                return HardwareCodecProtocol.AGAIN;
            }
            ByteBuffer destination = decoder.getInputBuffer(index);
            if (destination == null || source.remaining() > destination.capacity()) {
                decoder.queueInputBuffer(index, 0, 0, presentationTimeUs, 0);
                throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                        "transcoder input exceeds decoder buffer capacity");
            }
            int inputLength = source.remaining();
            destination.clear();
            destination.put(source);
            decoder.queueInputBuffer(index, 0, destination.position(), presentationTimeUs,
                    flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
            counters.inputRecords++;
            counters.inputBytes += inputLength;
            counters.maxInputPayloadBytes = Math.max(
                    counters.maxInputPayloadBytes, inputLength);
            counters.queueDepthHighWater = Math.max(counters.queueDepthHighWater, 1);
            if (inputLength > 0
                    && (flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                counters.inputFrames++;
            }
            pumpDecoder(0);
            return HardwareCodecProtocol.OK;
        }

        @Override
        public int queueEos(long presentationTimeUs) throws RequestException {
            ensureOpen();
            if (inputEosQueued) {
                throw sessionError("transcoder EOS was already queued");
            }
            if (presentationTimeUs < 0) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "transcoder EOS PTS must be non-negative");
            }
            pumpDecoder(0);
            int index = decoder.dequeueInputBuffer(100_000L);
            if (index < 0) {
                counters.inputAgain++;
                return HardwareCodecProtocol.AGAIN;
            }
            decoder.queueInputBuffer(index, 0, 0, presentationTimeUs,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            inputEosQueued = true;
            counters.inputEos++;
            pumpDecoder(0);
            return HardwareCodecProtocol.OK;
        }

        private void pumpDecoder(int timeoutMs) throws RequestException {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            for (int attempt = 0; attempt < 16 && !encoderEosSignaled; attempt++) {
                int index = decoder.dequeueOutputBuffer(info,
                        attempt == 0 ? timeoutMs * 1000L : 0L);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return;
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
                        || index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) continue;
                if (index < 0) continue;
                boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                if (info.size > 0) counters.surfaceFrames++;
                decoder.releaseOutputBuffer(index, info.size > 0);
                if (eos) {
                    try {
                        encoder.signalEndOfInputStream();
                        encoderEosSignaled = true;
                    } catch (RuntimeException e) {
                        throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                                "could not signal transcoder EOS: " + safe(e));
                    }
                    return;
                }
            }
        }

        @Override
        public OutputRecord dequeue(int timeoutMs) throws RequestException {
            ensureOpen();
            pumpDecoder(timeoutMs);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            for (int attempt = 0; attempt < 3; attempt++) {
                int index = encoder.dequeueOutputBuffer(info, timeoutMs * 1000L);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    counters.outputAgain++;
                    return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    counters.formatChanges++;
                    return new OutputRecord(HardwareCodecProtocol.FORMAT_CHANGED,
                            CodecSession.outputFormatPayload(encoder.getOutputFormat(), true));
                }
                if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) continue;
                if (index < 0) continue;
                if (info.size > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16) {
                    encoder.releaseOutputBuffer(index, false);
                    throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                            "transcoder output exceeds protocol limit");
                }
                ByteBuffer source = encoder.getOutputBuffer(index);
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(16 + info.size);
                DataOutputStream output = new DataOutputStream(bytes);
                try {
                    output.writeLong(info.presentationTimeUs);
                    output.writeInt(info.flags);
                    output.writeInt(info.size);
                    if (info.size > 0) {
                        if (source == null) {
                            throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                                    "transcoder returned a null encoder buffer");
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
                    if (info.size > 0) {
                        counters.outputRecords++;
                        counters.outputBytes += info.size;
                        counters.maxOutputPayloadBytes = Math.max(
                                counters.maxOutputPayloadBytes, info.size);
                        counters.queueDepthHighWater = Math.max(
                                counters.queueDepthHighWater, 1);
                        if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            counters.outputFrames++;
                        }
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        counters.outputEos++;
                    }
                    return new OutputRecord(HardwareCodecProtocol.OK,
                            bytes.toByteArray());
                } catch (IOException e) {
                    throw new RequestException(HardwareCodecProtocol.ERROR_IO, safe(e));
                } finally {
                    encoder.releaseOutputBuffer(index, false);
                }
            }
            return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
        }

        @Override
        public void flush() throws RequestException {
            ensureOpen();
            try {
                decoder.flush();
                encoder.flush();
                inputEosQueued = false;
                encoderEosSignaled = false;
            } catch (RuntimeException e) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "could not flush transcoder: " + safe(e));
            }
        }

        @Override
        public void requestKeyframe() throws RequestException {
            ensureOpen();
            try {
                Bundle parameters = new Bundle();
                parameters.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                encoder.setParameters(parameters);
            } catch (RuntimeException e) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "could not request transcoder keyframe: " + safe(e));
            }
        }

        @Override
        public String statistics() {
            return counters.json(sessionId, "surface_transcoder", decoderName,
                    encoderName, "surface_zero_copy");
        }

        @Override
        public SessionCounters counters() {
            return counters;
        }

        @Override
        public void recordSocketInput(int length) {
            counters.socketInputBytes += Math.max(0, length);
        }

        @Override
        public void recordSocketOutput(int length) {
            counters.socketOutputBytes += Math.max(0, length);
        }

        @Override
        public void recordSharedInput(int length) {
            counters.sharedInputBytes += Math.max(0, length);
        }

        @Override
        public void recordSharedOutput(int length) {
            counters.sharedOutputBytes += Math.max(0, length);
        }

        @Override
        public void recordError() {
            counters.errors++;
        }

        private void ensureOpen() throws RequestException {
            if (closed) throw sessionError("transcoder session is closed");
        }

        @Override
        public void close() {
            if (closed) return;
            closed = true;
            releaseCodec(decoder);
            releaseCodec(encoder);
            encoderInputSurface.release();
        }
    }

    private static final class CodecSession implements CodecBridgeSession {
        final long id;
        final String mime;
        final String codecName;
        final String classification;
        final int colorFormat;
        final boolean encoder;
        private final MediaCodec codec;
        private final SessionCounters counters = new SessionCounters();
        private boolean inputEosQueued;
        private long lastEncoderInputPresentationTimeUs = -1L;
        private boolean closed;

        private CodecSession(long id, String mime, String codecName,
                             String classification, int colorFormat, boolean encoder,
                             MediaCodec codec) {
            this.id = id;
            this.mime = mime;
            this.codecName = codecName;
            this.classification = classification;
            this.colorFormat = colorFormat;
            this.encoder = encoder;
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
                    || (width & 1) != 0 || (height & 1) != 0
                    || frameRate < 1 || frameRate > 240 || bitrate < 1_000
                    || bitrate > 100_000_000
                    || ((long) width * height * 3L / 2L)
                    > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16L) {
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
                            selected.classification, configuredColorFormat, encoder,
                            instance);
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
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
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

        @Override
        public long id() {
            return id;
        }

        @Override
        public int queue(ByteBuffer source, long presentationTimeUs, int flags)
                throws RequestException {
            ensureOpen();
            if (inputEosQueued) {
                throw sessionError("codec input is closed after EOS");
            }
            if (presentationTimeUs < 0) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "codec PTS must be non-negative");
            }
            int inputLength = source.remaining();
            boolean frame = inputLength > 0
                    && (flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
            if (encoder && frame && lastEncoderInputPresentationTimeUs >= 0
                    && presentationTimeUs <= lastEncoderInputPresentationTimeUs) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "encoder frame PTS must increase monotonically");
            }
            int index = codec.dequeueInputBuffer(100_000L);
            if (index < 0) {
                counters.inputAgain++;
                return HardwareCodecProtocol.AGAIN;
            }
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
            counters.inputRecords++;
            counters.inputBytes += inputLength;
            counters.maxInputPayloadBytes = Math.max(
                    counters.maxInputPayloadBytes, inputLength);
            counters.queueDepthHighWater = Math.max(counters.queueDepthHighWater, 1);
            if (frame) {
                counters.inputFrames++;
                if (encoder) {
                    lastEncoderInputPresentationTimeUs = presentationTimeUs;
                }
            }
            return HardwareCodecProtocol.OK;
        }

        @Override
        public int queueEos(long presentationTimeUs) throws RequestException {
            ensureOpen();
            if (inputEosQueued) {
                throw sessionError("codec EOS was already queued");
            }
            if (presentationTimeUs < 0) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "codec EOS PTS must be non-negative");
            }
            if (encoder && lastEncoderInputPresentationTimeUs >= 0
                    && presentationTimeUs < lastEncoderInputPresentationTimeUs) {
                throw new RequestException(HardwareCodecProtocol.ERROR_PROTOCOL,
                        "encoder EOS PTS precedes the last frame");
            }
            int index = codec.dequeueInputBuffer(100_000L);
            if (index < 0) {
                counters.inputAgain++;
                return HardwareCodecProtocol.AGAIN;
            }
            codec.queueInputBuffer(index, 0, 0, presentationTimeUs,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            inputEosQueued = true;
            counters.inputEos++;
            return HardwareCodecProtocol.OK;
        }

        @Override
        public OutputRecord dequeue(int timeoutMs) throws RequestException {
            ensureOpen();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            for (int attempt = 0; attempt < 3; attempt++) {
                int index = codec.dequeueOutputBuffer(info, timeoutMs * 1000L);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    counters.outputAgain++;
                    return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    counters.formatChanges++;
                    return new OutputRecord(HardwareCodecProtocol.FORMAT_CHANGED,
                            outputFormatPayload(codec.getOutputFormat(), encoder));
                }
                if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) continue;
                if (index < 0) continue;
                if (info.size > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16) {
                    codec.releaseOutputBuffer(index, false);
                    throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                            "codec output exceeds protocol limit");
                }
                ByteBuffer source = codec.getOutputBuffer(index);
                Image image = null;
                byte[] normalized = null;
                if (!encoder && info.size > 0) {
                    try {
                        image = codec.getOutputImage(index);
                        if (image == null) {
                            throw new RequestException(
                                    HardwareCodecProtocol.ERROR_UNSUPPORTED,
                                    "hardware decoder does not expose YUV_420_888 Image output");
                        }
                        normalized = normalizeI420(image);
                    } catch (RequestException e) {
                        if (image != null) image.close();
                        codec.releaseOutputBuffer(index, false);
                        throw e;
                    } catch (RuntimeException e) {
                        if (image != null) image.close();
                        codec.releaseOutputBuffer(index, false);
                        throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                                "could not normalize decoder output: " + safe(e));
                    }
                }
                int outputSize = normalized == null ? info.size : normalized.length;
                if (outputSize > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16) {
                    if (image != null) image.close();
                    codec.releaseOutputBuffer(index, false);
                    throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                            "normalized codec output exceeds protocol limit");
                }
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(16 + outputSize);
                DataOutputStream output = new DataOutputStream(bytes);
                try {
                    output.writeLong(info.presentationTimeUs);
                    output.writeInt(info.flags);
                    output.writeInt(outputSize);
                    if (normalized != null) {
                        output.write(normalized);
                    } else if (info.size > 0) {
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
                    if (outputSize > 0) {
                        counters.outputRecords++;
                        counters.outputBytes += outputSize;
                        counters.maxOutputPayloadBytes = Math.max(
                                counters.maxOutputPayloadBytes, outputSize);
                        counters.queueDepthHighWater = Math.max(
                                counters.queueDepthHighWater, 1);
                        if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            counters.outputFrames++;
                        }
                        if (normalized != null) counters.cpuYuvFrames++;
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        counters.outputEos++;
                    }
                    return new OutputRecord(HardwareCodecProtocol.OK,
                            bytes.toByteArray());
                } catch (IOException e) {
                    throw new RequestException(HardwareCodecProtocol.ERROR_IO, safe(e));
                } finally {
                    if (image != null) image.close();
                    codec.releaseOutputBuffer(index, false);
                }
            }
            return new OutputRecord(HardwareCodecProtocol.AGAIN, new byte[0]);
        }

        @Override
        public void flush() throws RequestException {
            ensureOpen();
            try {
                codec.flush();
                inputEosQueued = false;
                lastEncoderInputPresentationTimeUs = -1L;
            } catch (RuntimeException e) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "could not flush codec: " + safe(e));
            }
        }

        @Override
        public void requestKeyframe() throws RequestException {
            ensureOpen();
            if (!encoder) {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "keyframe requests require an encoder session");
            }
            try {
                Bundle parameters = new Bundle();
                parameters.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                codec.setParameters(parameters);
            } catch (RuntimeException e) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "could not request encoder keyframe: " + safe(e));
            }
        }

        @Override
        public String statistics() {
            String kind = encoder ? "bytebuffer_encoder" : "bytebuffer_decoder";
            String input = encoder ? "video/raw" : codecName;
            String output = encoder ? codecName : "video/raw";
            return counters.json(id, kind, input, output, "bytebuffer");
        }

        @Override
        public SessionCounters counters() {
            return counters;
        }

        @Override
        public void recordSocketInput(int length) {
            counters.socketInputBytes += Math.max(0, length);
        }

        @Override
        public void recordSocketOutput(int length) {
            counters.socketOutputBytes += Math.max(0, length);
        }

        @Override
        public void recordSharedInput(int length) {
            counters.sharedInputBytes += Math.max(0, length);
        }

        @Override
        public void recordSharedOutput(int length) {
            counters.sharedOutputBytes += Math.max(0, length);
        }

        @Override
        public void recordError() {
            counters.errors++;
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

        private static byte[] outputFormatPayload(MediaFormat format, boolean encoder) {
            ByteBuffer payload = ByteBuffer.allocate(20).order(ByteOrder.BIG_ENDIAN);
            int width = integer(format, MediaFormat.KEY_WIDTH, 0);
            int height = integer(format, MediaFormat.KEY_HEIGHT, 0);
            payload.putInt(width);
            payload.putInt(height);
            payload.putInt(integer(format, "stride", width));
            payload.putInt(integer(format, "slice-height", height));
            payload.putInt(encoder ? HardwareCodecProtocol.PIXEL_FORMAT_BITSTREAM
                    : HardwareCodecProtocol.PIXEL_FORMAT_I420);
            return payload.array();
        }

        private static int integer(MediaFormat format, String key, int fallback) {
            try {
                return format.containsKey(key) ? format.getInteger(key) : fallback;
            } catch (RuntimeException e) {
                return fallback;
            }
        }

        private static byte[] normalizeI420(Image image) throws RequestException {
            if (image.getFormat() != android.graphics.ImageFormat.YUV_420_888) {
                throw new RequestException(HardwareCodecProtocol.ERROR_UNSUPPORTED,
                        "decoder output image is not YUV_420_888");
            }
            Rect crop = image.getCropRect();
            int width = crop.width();
            int height = crop.height();
            if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "decoder output crop must have positive even dimensions");
            }
            long length = (long) width * height * 3L / 2L;
            if (length > HardwareCodecProtocol.MAX_MEDIA_PAYLOAD - 16L) {
                throw new RequestException(HardwareCodecProtocol.ERROR_LIMIT,
                        "decoder frame exceeds protocol limit");
            }
            Image.Plane[] planes = image.getPlanes();
            if (planes.length != 3) {
                throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                        "decoder output must have three YUV planes");
            }
            byte[] result = new byte[(int) length];
            int destination = 0;
            for (int planeIndex = 0; planeIndex < 3; planeIndex++) {
                Image.Plane plane = planes[planeIndex];
                ByteBuffer source = plane.getBuffer().duplicate();
                int shift = planeIndex == 0 ? 0 : 1;
                int planeWidth = width >> shift;
                int planeHeight = height >> shift;
                int cropLeft = crop.left >> shift;
                int cropTop = crop.top >> shift;
                int rowStride = plane.getRowStride();
                int pixelStride = plane.getPixelStride();
                int first = source.position() + cropTop * rowStride
                        + cropLeft * pixelStride;
                for (int row = 0; row < planeHeight; row++) {
                    int rowStart = first + row * rowStride;
                    int last = rowStart + (planeWidth - 1) * pixelStride;
                    if (rowStart < source.position() || last >= source.limit()) {
                        throw new RequestException(HardwareCodecProtocol.ERROR_CODEC,
                                "decoder plane bounds are invalid");
                    }
                    if (pixelStride == 1) {
                        ByteBuffer contiguous = source.duplicate();
                        contiguous.position(rowStart);
                        contiguous.get(result, destination, planeWidth);
                        destination += planeWidth;
                    } else {
                        for (int column = 0; column < planeWidth; column++) {
                            result[destination++] = source.get(
                                    rowStart + column * pixelStride);
                        }
                    }
                }
            }
            return result;
        }
    }
}
