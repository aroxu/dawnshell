// Broker-side socket transport for the DawnShell codec bridge.
//
// Android's LocalSocket exposes ancillary descriptors only through its own
// stream wrapper, and reading a message that carries an SCM_RIGHTS descriptor
// through that wrapper fails with EMSGSIZE ("Message too long"). The broker
// therefore owns a plain AF_UNIX socket and performs recvmsg/sendmsg here.

#include <errno.h>
#include <jni.h>
#include <android/log.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_RECEIVED_DESCRIPTORS 1

static void throw_errno(JNIEnv *env, const char *operation, int code) {
    jclass exception = (*env)->FindClass(env, "java/io/IOException");
    if (exception == NULL) return;
    char message[192];
    snprintf(message, sizeof(message), "%s failed: %s", operation,
             strerror(code));
    (*env)->ThrowNew(env, exception, message);
}

JNIEXPORT jint JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeCreateServer(JNIEnv *env, jclass clazz,
                                                       jstring name,
                                                       jint backlog) {
    (void)clazz;
    const char *chars = (*env)->GetStringUTFChars(env, name, NULL);
    if (chars == NULL) return -1;
    size_t length = strlen(chars);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (length + 1 > sizeof(address.sun_path)) {
        (*env)->ReleaseStringUTFChars(env, name, chars);
        throw_errno(env, "abstract socket name", ENAMETOOLONG);
        return -1;
    }
    // A leading NUL selects the Linux abstract namespace, matching the name
    // the client already connects to.
    memcpy(address.sun_path + 1, chars, length);
    (*env)->ReleaseStringUTFChars(env, name, chars);

    int descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (descriptor < 0) {
        throw_errno(env, "socket", errno);
        return -1;
    }
    socklen_t address_length = (socklen_t)(offsetof(struct sockaddr_un, sun_path)
            + 1 + length);
    if (bind(descriptor, (struct sockaddr *)&address, address_length) != 0
            || listen(descriptor, backlog) != 0) {
        int saved = errno;
        close(descriptor);
        throw_errno(env, "bind/listen", saved);
        return -1;
    }
    return descriptor;
}

JNIEXPORT jint JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeAccept(JNIEnv *env, jclass clazz,
                                                 jint server,
                                                 jintArray credentials) {
    (void)clazz;
    int peer;
    do {
        peer = accept4(server, NULL, NULL, SOCK_CLOEXEC);
    } while (peer < 0 && errno == EINTR);
    if (peer < 0) {
        throw_errno(env, "accept", errno);
        return -1;
    }
    struct ucred peer_credentials;
    socklen_t credentials_length = sizeof(peer_credentials);
    if (getsockopt(peer, SOL_SOCKET, SO_PEERCRED, &peer_credentials,
                   &credentials_length) != 0) {
        int saved = errno;
        close(peer);
        throw_errno(env, "SO_PEERCRED", saved);
        return -1;
    }
    jint values[2] = {(jint)peer_credentials.uid, (jint)peer_credentials.pid};
    (*env)->SetIntArrayRegion(env, credentials, 0, 2, values);
    return peer;
}

JNIEXPORT jint JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeSetTimeoutMs(JNIEnv *env, jclass clazz,
                                                       jint descriptor,
                                                       jint timeoutMs) {
    (void)clazz;
    struct timeval timeout;
    timeout.tv_sec = timeoutMs / 1000;
    timeout.tv_usec = (timeoutMs % 1000) * 1000;
    if (setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout)) != 0
            || setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                          sizeof(timeout)) != 0) {
        throw_errno(env, "socket timeout", errno);
        return -1;
    }
    return 0;
}

// Reads exactly `length` bytes and reports any ancillary descriptor that
// arrived with them. Returning the descriptor separately keeps the caller from
// having to know which message carried it.
JNIEXPORT jint JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeReceive(JNIEnv *env, jclass clazz,
                                                  jint descriptor,
                                                  jbyteArray buffer,
                                                  jint offset, jint length,
                                                  jintArray receivedDescriptor) {
    (void)clazz;
    if (length <= 0) return 0;
    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) return -1;

    jint claimed = -1;
    int copied = 0;
    int result = 0;
    while (copied < length) {
        struct iovec vector;
        vector.iov_base = (char *)bytes + offset + copied;
        vector.iov_len = (size_t)(length - copied);
        char control[CMSG_SPACE(sizeof(int) * MAX_RECEIVED_DESCRIPTORS)];
        memset(control, 0, sizeof(control));
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        message.msg_iov = &vector;
        message.msg_iovlen = 1;
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        ssize_t count;
        do {
            count = recvmsg(descriptor, &message, 0);
        } while (count < 0 && errno == EINTR);
        if (count == 0) {
            result = -2;
            break;
        }
        if (count < 0) {
            throw_errno(env, "recvmsg", errno);
            result = -1;
            break;
        }
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL;
                header = CMSG_NXTHDR(&message, header)) {
            __android_log_print(ANDROID_LOG_INFO, "DawnShellCodec",
                    "recvmsg cmsg level=%d type=%d len=%u bytes=%zd flags=%d",
                    header->cmsg_level, header->cmsg_type,
                    (unsigned)header->cmsg_len, count, message.msg_flags);
            if (header->cmsg_level != SOL_SOCKET
                    || header->cmsg_type != SCM_RIGHTS) continue;
            size_t payload = header->cmsg_len - CMSG_LEN(0);
            size_t count_of_fds = payload / sizeof(int);
            for (size_t index = 0; index < count_of_fds; index++) {
                int received;
                memcpy(&received, CMSG_DATA(header) + index * sizeof(int),
                       sizeof(received));
                // Exactly one descriptor is expected; close any extra so a
                // malicious peer cannot exhaust the broker's table.
                if (claimed < 0) claimed = received;
                else close(received);
            }
        }
        copied += (int)count;
    }
    __android_log_print(ANDROID_LOG_INFO, "DawnShellCodec",
            "recvmsg done requested=%d copied=%d claimed=%d", length, copied,
            (int)claimed);
    (*env)->ReleaseByteArrayElements(env, buffer, bytes, 0);
    if (claimed >= 0) {
        if (result == 0) {
            (*env)->SetIntArrayRegion(env, receivedDescriptor, 0, 1, &claimed);
        } else {
            close(claimed);
        }
    }
    return result == 0 ? copied : result;
}

JNIEXPORT jint JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeSend(JNIEnv *env, jclass clazz,
                                               jint descriptor,
                                               jbyteArray buffer,
                                               jint offset, jint length) {
    (void)clazz;
    if (length <= 0) return 0;
    jbyte *bytes = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (bytes == NULL) return -1;
    int written = 0;
    int result = 0;
    while (written < length) {
        ssize_t count;
        do {
            count = send(descriptor, (const char *)bytes + offset + written,
                         (size_t)(length - written), MSG_NOSIGNAL);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            throw_errno(env, "send", count == 0 ? EPIPE : errno);
            result = -1;
            break;
        }
        written += (int)count;
    }
    (*env)->ReleaseByteArrayElements(env, buffer, bytes, JNI_ABORT);
    return result == 0 ? written : result;
}

JNIEXPORT void JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeClose(JNIEnv *env, jclass clazz,
                                                jint descriptor) {
    (void)env;
    (void)clazz;
    if (descriptor >= 0) close(descriptor);
}

JNIEXPORT void JNICALL
Java_me_aroxu_dawnshell_CodecSocket_nativeShutdown(JNIEnv *env, jclass clazz,
                                                   jint descriptor) {
    (void)env;
    (void)clazz;
    if (descriptor >= 0) shutdown(descriptor, SHUT_RDWR);
}
