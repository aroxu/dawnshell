#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define DSCB_MAGIC 0x44534342u
#define DSCB_VERSION 1u
#define DSCB_HEADER_BYTES 32u
#define DSCB_RESPONSE_BIT 0x8000u
#define DSCB_HELLO 1u
#define DSCB_CAPABILITIES 2u
#define DSCB_CREATE 3u
#define DSCB_INPUT 4u
#define DSCB_OUTPUT 5u
#define DSCB_FLUSH 6u
#define DSCB_EOS 7u
#define DSCB_CLOSE 8u
#define DSCB_INPUT_SHARED_MEMORY 9u
#define DSCB_OUTPUT_SHARED_MEMORY 10u
#define DSCB_CREATE_TRANSCODER 11u
#define DSCB_REQUEST_KEYFRAME 12u
#define DSCB_HEALTH 13u
#define DSCB_SESSION_STATS 14u
#define DSCB_MODE_DECODE 1u
#define DSCB_MODE_ENCODE 2u
#define DSCB_CODEC_AVC 1u
#define DSCB_CODEC_HEVC 2u
#define DSCB_OK 0
#define DSCB_AGAIN 1
#define DSCB_FORMAT_CHANGED 2
#define DSCB_ERROR_PROTOCOL (-1)
#define DSCB_ERROR_UNSUPPORTED (-4)
#define DSCB_ERROR_LIMIT (-5)
#define DSCB_ERROR_SESSION (-7)
#define DSCB_MAX_PAYLOAD (8u * 1024u * 1024u)
#define DSCB_BUFFER_FLAG_EOS 4u
#define DSCB_BUFFER_FLAG_KEY_FRAME 1u
#define DSCB_PIXEL_FORMAT_I420 1u
#define DSCB_COLOR_YUV420_PLANAR 19u
#define DSCB_COLOR_YUV420_SEMIPLANAR 21u
#define DSCB_COLOR_YUV420_FLEXIBLE 0x7f420888u
#define DSCB_BUFFER_FLAG_CODEC_CONFIG 2u
#define DSCB_SOCKET_NAME "dawnshell.codec.v1"
#define DSCB_SHARED_MEMORY_THRESHOLD (64u * 1024u)

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001u
#endif

struct response {
    uint16_t type;
    uint64_t session_id;
    uint32_t request_id;
    int32_t status;
    uint32_t payload_length;
    uint8_t *payload;
};

static uint32_t next_request_id = 1;
static int shared_memory_supported = 0;

static void put_u16(uint8_t *destination, uint16_t value) {
    value = htons(value);
    memcpy(destination, &value, sizeof(value));
}

static void put_u32(uint8_t *destination, uint32_t value) {
    value = htonl(value);
    memcpy(destination, &value, sizeof(value));
}

static void put_u64(uint8_t *destination, uint64_t value) {
    put_u32(destination, (uint32_t)(value >> 32));
    put_u32(destination + 4, (uint32_t)value);
}

static uint16_t get_u16(const uint8_t *source) {
    uint16_t value;
    memcpy(&value, source, sizeof(value));
    return ntohs(value);
}

static uint32_t get_u32(const uint8_t *source) {
    uint32_t value;
    memcpy(&value, source, sizeof(value));
    return ntohl(value);
}

static uint64_t get_u64(const uint8_t *source) {
    return ((uint64_t)get_u32(source) << 32) | get_u32(source + 4);
}

static int write_all(int descriptor, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    while (length > 0) {
        ssize_t count = write(descriptor, bytes, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += (size_t)count;
        length -= (size_t)count;
    }
    return 0;
}

static int read_all(int descriptor, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    while (length > 0) {
        ssize_t count = read(descriptor, bytes, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += (size_t)count;
        length -= (size_t)count;
    }
    return 0;
}

static int pread_all(int descriptor, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    off_t offset = 0;
    while (length > 0) {
        ssize_t count = pread(descriptor, bytes, length, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += (size_t)count;
        length -= (size_t)count;
        offset += count;
    }
    return 0;
}

static int pwrite_all(int descriptor, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    off_t offset = 0;
    while (length > 0) {
        ssize_t count = pwrite(descriptor, bytes, length, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += (size_t)count;
        length -= (size_t)count;
        offset += count;
    }
    return 0;
}

static int create_shared_memory(const char *name, size_t length) {
#ifdef __NR_memfd_create
    int descriptor = (int)syscall(__NR_memfd_create, name, MFD_CLOEXEC);
    if (descriptor < 0) return -1;
    if (ftruncate(descriptor, (off_t)length) != 0) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    return descriptor;
#else
    (void)name;
    (void)length;
    errno = ENOSYS;
    return -1;
#endif
}

static int read_record_header(uint8_t header[16]) {
    size_t offset = 0;
    while (offset < 16) {
        size_t count = fread(header + offset, 1, 16 - offset, stdin);
        if (count == 0) {
            if (ferror(stdin)) return -1;
            return offset == 0 ? 0 : -1;
        }
        offset += count;
    }
    return 1;
}

static int connect_broker(void) {
    int descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (descriptor < 0) return -1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    const size_t name_length = strlen(DSCB_SOCKET_NAME);
    if (name_length + 1 >= sizeof(address.sun_path)) {
        close(descriptor);
        errno = ENAMETOOLONG;
        return -1;
    }
    address.sun_path[0] = '\0';
    memcpy(address.sun_path + 1, DSCB_SOCKET_NAME, name_length);
    const socklen_t length = (socklen_t)(offsetof(struct sockaddr_un, sun_path)
            + 1 + name_length);
    if (connect(descriptor, (struct sockaddr *)&address, length) != 0) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    return descriptor;
}

static void free_response(struct response *response) {
    free(response->payload);
    memset(response, 0, sizeof(*response));
}

static int read_response(int descriptor, uint16_t type, uint32_t request_id,
                         struct response *response) {
    uint8_t header[DSCB_HEADER_BYTES];
    if (read_all(descriptor, header, sizeof(header)) != 0) return -1;
    if (get_u32(header) != DSCB_MAGIC || get_u16(header + 4) != DSCB_VERSION
            || get_u16(header + 6) != (uint16_t)(type | DSCB_RESPONSE_BIT)
            || get_u32(header + 24) != request_id || get_u32(header + 8) != 0) {
        errno = EPROTO;
        return -1;
    }
    memset(response, 0, sizeof(*response));
    response->type = get_u16(header + 6);
    response->session_id = get_u64(header + 12);
    response->payload_length = get_u32(header + 20);
    response->request_id = get_u32(header + 24);
    response->status = (int32_t)get_u32(header + 28);
    if (response->payload_length > DSCB_MAX_PAYLOAD) {
        errno = EOVERFLOW;
        return -1;
    }
    if (response->payload_length > 0) {
        response->payload = malloc((size_t)response->payload_length + 1);
        if (response->payload == NULL) return -1;
        if (read_all(descriptor, response->payload,
                     response->payload_length) != 0) {
            free_response(response);
            return -1;
        }
        response->payload[response->payload_length] = '\0';
    }
    return 0;
}

static void make_request_header(uint8_t header[DSCB_HEADER_BYTES], uint16_t type,
                                uint64_t session_id, uint32_t payload_length,
                                uint32_t request_id) {
    memset(header, 0, DSCB_HEADER_BYTES);
    put_u32(header, DSCB_MAGIC);
    put_u16(header + 4, DSCB_VERSION);
    put_u16(header + 6, type);
    put_u64(header + 12, session_id);
    put_u32(header + 20, payload_length);
    put_u32(header + 24, request_id);
}

static int rpc(int descriptor, uint16_t type, uint64_t session_id,
               const void *payload, uint32_t payload_length,
               struct response *response) {
    uint8_t header[DSCB_HEADER_BYTES];
    const uint32_t request_id = next_request_id++;
    make_request_header(header, type, session_id, payload_length, request_id);
    if (write_all(descriptor, header, sizeof(header)) != 0
            || (payload_length > 0
            && write_all(descriptor, payload, payload_length) != 0)) return -1;
    return read_response(descriptor, type, request_id, response);
}

static int rpc_with_fd(int descriptor, uint16_t type, uint64_t session_id,
                       const void *payload, uint32_t payload_length,
                       int shared_descriptor, struct response *response) {
    const size_t request_length = DSCB_HEADER_BYTES + (size_t)payload_length;
    uint8_t *request = malloc(request_length);
    if (request == NULL) return -1;
    const uint32_t request_id = next_request_id++;
    make_request_header(request, type, session_id, payload_length, request_id);
    if (payload_length > 0) {
        memcpy(request + DSCB_HEADER_BYTES, payload, payload_length);
    }
    struct iovec vector = {.iov_base = request, .iov_len = request_length};
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    struct cmsghdr *control_header = CMSG_FIRSTHDR(&message);
    control_header->cmsg_level = SOL_SOCKET;
    control_header->cmsg_type = SCM_RIGHTS;
    control_header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(control_header), &shared_descriptor, sizeof(int));
    ssize_t sent;
    do {
        sent = sendmsg(descriptor, &message, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent <= 0 || (size_t)sent > request_length) {
        free(request);
        return -1;
    }
    int result = 0;
    if ((size_t)sent < request_length
            && write_all(descriptor, request + sent, request_length - (size_t)sent) != 0) {
        result = -1;
    } else {
        result = read_response(descriptor, type, request_id, response);
    }
    free(request);
    return result;
}

static int report_error(const char *operation, const struct response *response) {
    fprintf(stderr, "dawnshell-codec: %s failed: status=%" PRId32,
            operation, response->status);
    if (response->payload_length > 0) {
        fprintf(stderr, " message=%.*s", (int)response->payload_length,
                (const char *)response->payload);
    }
    fputc('\n', stderr);
    return 1;
}

static int hello(int descriptor) {
    struct response response;
    if (rpc(descriptor, DSCB_HELLO, 0, NULL, 0, &response) != 0) return -1;
    int result = 0;
    if (response.status != DSCB_OK) {
        result = report_error("hello", &response);
    } else if ((getenv("DAWNSHELL_CODEC_DISABLE_SHM") == NULL
            || strcmp(getenv("DAWNSHELL_CODEC_DISABLE_SHM"), "1") != 0)
            && response.payload != NULL
            && strstr((const char *)response.payload,
                      "memfd_scm_rights_with_socket_fallback") != NULL) {
        shared_memory_supported = 1;
    }
    free_response(&response);
    return result;
}

static int print_capabilities(int descriptor) {
    struct response response;
    if (rpc(descriptor, DSCB_CAPABILITIES, 0, NULL, 0, &response) != 0) return -1;
    int result = 0;
    if (response.status != DSCB_OK) {
        result = report_error("capabilities", &response);
    } else {
        if (response.payload_length > 0) {
            fwrite(response.payload, 1, response.payload_length, stdout);
        }
        fputc('\n', stdout);
    }
    free_response(&response);
    return result;
}

static int print_health(int descriptor) {
    struct response response;
    if (rpc(descriptor, DSCB_HEALTH, 0, NULL, 0, &response) != 0) return -1;
    int result = 0;
    if (response.status != DSCB_OK) {
        result = report_error("health", &response);
    } else {
        if (response.payload_length > 0) {
            fwrite(response.payload, 1, response.payload_length, stdout);
        }
        fputc('\n', stdout);
    }
    free_response(&response);
    return result;
}

static int parse_mode(const char *value, uint32_t *mode) {
    if (strcmp(value, "decode") == 0) *mode = DSCB_MODE_DECODE;
    else if (strcmp(value, "encode") == 0) *mode = DSCB_MODE_ENCODE;
    else return -1;
    return 0;
}

static int parse_codec(const char *value, uint32_t *codec) {
    if (strcmp(value, "avc") == 0 || strcmp(value, "h264") == 0) {
        *codec = DSCB_CODEC_AVC;
    } else if (strcmp(value, "hevc") == 0 || strcmp(value, "h265") == 0) {
        *codec = DSCB_CODEC_HEVC;
    } else {
        return -1;
    }
    return 0;
}

static int parse_u32(const char *value, uint32_t minimum, uint32_t maximum,
                     uint32_t *result) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0'
            || parsed < minimum || parsed > maximum) return -1;
    *result = (uint32_t)parsed;
    return 0;
}

static int create_session(int descriptor, uint32_t mode, uint32_t codec,
                          uint32_t width, uint32_t height, uint32_t frame_rate,
                          uint32_t bitrate, uint64_t *session_id,
                          uint32_t *selected_color_format) {
    uint8_t payload[28];
    put_u32(payload, mode);
    put_u32(payload + 4, codec);
    put_u32(payload + 8, width);
    put_u32(payload + 12, height);
    put_u32(payload + 16, frame_rate);
    put_u32(payload + 20, bitrate);
    put_u32(payload + 24, 0);
    struct response response;
    if (rpc(descriptor, DSCB_CREATE, 0, payload, sizeof(payload), &response) != 0) {
        return -1;
    }
    int result = 0;
    if (response.status != DSCB_OK || response.session_id == 0) {
        result = report_error("create", &response);
    } else {
        *session_id = response.session_id;
        if (selected_color_format != NULL && response.payload != NULL) {
            const char *marker = strstr((const char *)response.payload,
                                        "\"color_format\":");
            if (marker != NULL) {
                marker += strlen("\"color_format\":");
                char *end = NULL;
                unsigned long parsed = strtoul(marker, &end, 10);
                if (end != marker && parsed <= UINT32_MAX) {
                    *selected_color_format = (uint32_t)parsed;
                }
            }
        }
        fprintf(stderr, "dawnshell-codec: session=%" PRIu64 " %.*s\n",
                *session_id, (int)response.payload_length,
                response.payload == NULL ? (uint8_t *)"" : response.payload);
    }
    free_response(&response);
    return result;
}

static int create_transcode_session(int descriptor, uint32_t input_codec,
                                    uint32_t output_codec, uint32_t width,
                                    uint32_t height, uint32_t frame_rate,
                                    uint32_t bitrate, uint64_t *session_id) {
    uint8_t payload[24];
    put_u32(payload, input_codec);
    put_u32(payload + 4, output_codec);
    put_u32(payload + 8, width);
    put_u32(payload + 12, height);
    put_u32(payload + 16, frame_rate);
    put_u32(payload + 20, bitrate);
    struct response response;
    if (rpc(descriptor, DSCB_CREATE_TRANSCODER, 0, payload, sizeof(payload),
            &response) != 0) return -1;
    int result = 0;
    if (response.status != DSCB_OK || response.session_id == 0) {
        result = report_error("create transcoder", &response);
    } else {
        *session_id = response.session_id;
        fprintf(stderr, "dawnshell-codec: transcoder-session=%" PRIu64 " %.*s\n",
                *session_id, (int)response.payload_length,
                response.payload == NULL ? (uint8_t *)"" : response.payload);
    }
    free_response(&response);
    return result;
}

static int simple_request(int descriptor, uint16_t type, uint64_t session_id,
                          const void *payload, uint32_t payload_length,
                          const char *name) {
    struct response response;
    if (rpc(descriptor, type, session_id, payload, payload_length, &response) != 0) {
        return -1;
    }
    int result = response.status == DSCB_OK ? 0 : report_error(name, &response);
    free_response(&response);
    return result;
}

static void close_session(int descriptor, uint64_t session_id);
static int queue_eos(int descriptor, uint64_t session_id, uint64_t pts);

static int request_keyframe(int descriptor, uint64_t session_id) {
    return simple_request(descriptor, DSCB_REQUEST_KEYFRAME, session_id,
                          NULL, 0, "request keyframe");
}

static int report_session_stats(int descriptor, uint64_t session_id) {
    struct response response;
    if (rpc(descriptor, DSCB_SESSION_STATS, session_id, NULL, 0,
            &response) != 0) return -1;
    int result = 0;
    if (response.status != DSCB_OK) {
        result = report_error("session stats", &response);
    } else {
        fprintf(stderr, "dawnshell-codec: session-stats=%.*s\n",
                (int)response.payload_length,
                response.payload == NULL ? (uint8_t *)"" : response.payload);
    }
    free_response(&response);
    return result;
}

static int expect_status(int descriptor, uint16_t type, uint64_t session_id,
                         const void *payload, uint32_t payload_length,
                         int32_t expected, const char *name) {
    struct response response;
    if (rpc(descriptor, type, session_id, payload, payload_length, &response) != 0) {
        fprintf(stderr, "dawnshell-codec: negative-test %s transport failed: %s\n",
                name, strerror(errno));
        return 1;
    }
    int result = 0;
    if (response.status != expected) {
        fprintf(stderr,
                "dawnshell-codec: negative-test %s status=%" PRId32
                " expected=%" PRId32 "\n",
                name, response.status, expected);
        result = 1;
    }
    free_response(&response);
    return result;
}

static int run_negative_test(int descriptor) {
    const uint8_t unexpected_payload = 0;
    if (expect_status(descriptor, DSCB_HEALTH, 0, &unexpected_payload, 1,
                      DSCB_ERROR_PROTOCOL, "nonempty-health") != 0
            || expect_status(descriptor, DSCB_REQUEST_KEYFRAME, UINT64_MAX,
                             NULL, 0, DSCB_ERROR_SESSION,
                             "unknown-keyframe-session") != 0
            || expect_status(descriptor, DSCB_SESSION_STATS, UINT64_MAX,
                             NULL, 0, DSCB_ERROR_SESSION,
                             "unknown-statistics-session") != 0) {
        return 1;
    }
    uint8_t invalid_create[28];
    put_u32(invalid_create, DSCB_MODE_DECODE);
    put_u32(invalid_create + 4, DSCB_CODEC_AVC);
    put_u32(invalid_create + 8, 0);
    put_u32(invalid_create + 12, 96);
    put_u32(invalid_create + 16, 10);
    put_u32(invalid_create + 20, 1000000);
    put_u32(invalid_create + 24, 0);
    if (expect_status(descriptor, DSCB_CREATE, 0, invalid_create,
                      sizeof(invalid_create), DSCB_ERROR_LIMIT,
                      "zero-width-create") != 0) {
        return 1;
    }
    put_u32(invalid_create + 8, 4096);
    put_u32(invalid_create + 12, 4096);
    if (expect_status(descriptor, DSCB_CREATE, 0, invalid_create,
                      sizeof(invalid_create), DSCB_ERROR_LIMIT,
                      "oversized-frame-create") != 0) {
        return 1;
    }
    uint64_t session_id = 0;
    if (create_session(descriptor, DSCB_MODE_DECODE, DSCB_CODEC_AVC,
            128, 96, 10, 1000000, &session_id, NULL) != 0) return 1;
    uint8_t malformed_input[17];
    put_u64(malformed_input, 0);
    put_u32(malformed_input + 8, UINT32_MAX);
    put_u32(malformed_input + 12, 1);
    malformed_input[16] = 0;
    if (expect_status(descriptor, DSCB_INPUT, session_id, malformed_input,
                      sizeof(malformed_input), DSCB_ERROR_PROTOCOL,
                      "unsupported-input-flags") != 0
            || simple_request(descriptor, DSCB_FLUSH, session_id, NULL, 0,
                              "post-error flush") != 0) {
        close_session(descriptor, session_id);
        return 1;
    }
    if (queue_eos(descriptor, session_id, 0) != 0) {
        close_session(descriptor, session_id);
        return 1;
    }
    uint8_t eos_payload[8];
    put_u64(eos_payload, 0);
    put_u32(malformed_input + 8, 0);
    if (expect_status(descriptor, DSCB_EOS, session_id, eos_payload,
                      sizeof(eos_payload), DSCB_ERROR_SESSION,
                      "duplicate-eos") != 0
            || expect_status(descriptor, DSCB_INPUT, session_id, malformed_input,
                             sizeof(malformed_input), DSCB_ERROR_SESSION,
                             "input-after-eos") != 0
            || simple_request(descriptor, DSCB_FLUSH, session_id, NULL, 0,
                              "post-eos flush") != 0) {
        close_session(descriptor, session_id);
        return 1;
    }
    close_session(descriptor, session_id);
    if (print_health(descriptor) != 0) return 1;
    fprintf(stderr,
            "dawnshell-codec: negative-test passed rejected=8"
            " session=responsive broker=responsive\n");
    return 0;
}

static void close_session(int descriptor, uint64_t session_id) {
    if (session_id == 0) return;
    (void)simple_request(descriptor, DSCB_CLOSE, session_id, NULL, 0, "close");
}

static int queue_input(int descriptor, uint64_t session_id,
                       const uint8_t header[16], const uint8_t *data,
                       uint32_t length) {
    int shared_descriptor = -1;
    if (shared_memory_supported && length >= DSCB_SHARED_MEMORY_THRESHOLD) {
        shared_descriptor = create_shared_memory("dawnshell-codec-input", length);
        if (shared_descriptor >= 0
                && pwrite_all(shared_descriptor, data, length) != 0) {
            close(shared_descriptor);
            shared_descriptor = -1;
        }
    }
    if (shared_descriptor >= 0) {
        int result;
        for (;;) {
            struct response response;
            if (rpc_with_fd(descriptor, DSCB_INPUT_SHARED_MEMORY, session_id,
                    header, 16, shared_descriptor, &response) != 0) {
                result = -1;
                break;
            }
            if (response.status == DSCB_AGAIN) {
                free_response(&response);
                usleep(2000);
                continue;
            }
            if (response.status == DSCB_ERROR_UNSUPPORTED) {
                shared_memory_supported = 0;
                result = 2;
            } else {
                result = response.status == DSCB_OK
                        ? 0 : report_error("shared input", &response);
            }
            free_response(&response);
            break;
        }
        close(shared_descriptor);
        if (result != 2) return result;
    }
    uint8_t *payload = malloc((size_t)length + 16);
    if (payload == NULL) return -1;
    memcpy(payload, header, 16);
    if (length > 0) memcpy(payload + 16, data, length);
    int result;
    for (;;) {
        struct response response;
        if (rpc(descriptor, DSCB_INPUT, session_id, payload, length + 16,
                &response) != 0) {
            result = -1;
            break;
        }
        if (response.status == DSCB_AGAIN) {
            free_response(&response);
            usleep(2000);
            continue;
        }
        result = response.status == DSCB_OK ? 0 : report_error("input", &response);
        free_response(&response);
        break;
    }
    free(payload);
    return result;
}

static int output_shared_memory(int descriptor, uint64_t session_id,
                                uint32_t timeout_ms, struct response *response) {
    if (!shared_memory_supported) return 1;
    int shared_descriptor = create_shared_memory("dawnshell-codec-output",
                                                  DSCB_MAX_PAYLOAD);
    if (shared_descriptor < 0) return 1;
    uint8_t request[8];
    put_u32(request, timeout_ms);
    put_u32(request + 4, DSCB_MAX_PAYLOAD);
    int result = rpc_with_fd(descriptor, DSCB_OUTPUT_SHARED_MEMORY, session_id,
                             request, sizeof(request), shared_descriptor, response);
    if (result != 0) {
        close(shared_descriptor);
        return -1;
    }
    if (response->status == DSCB_ERROR_UNSUPPORTED) {
        shared_memory_supported = 0;
        free_response(response);
        close(shared_descriptor);
        return 1;
    }
    if (response->status == DSCB_OK) {
        if (response->payload_length != 4) {
            free_response(response);
            close(shared_descriptor);
            errno = EPROTO;
            return -1;
        }
        uint32_t actual_length = get_u32(response->payload);
        free(response->payload);
        response->payload = NULL;
        response->payload_length = actual_length;
        if (actual_length > DSCB_MAX_PAYLOAD) {
            close(shared_descriptor);
            errno = EOVERFLOW;
            return -1;
        }
        if (actual_length > 0) {
            response->payload = malloc((size_t)actual_length + 1);
            if (response->payload == NULL
                    || pread_all(shared_descriptor, response->payload,
                                 actual_length) != 0) {
                free_response(response);
                close(shared_descriptor);
                return -1;
            }
            response->payload[actual_length] = '\0';
        }
    }
    close(shared_descriptor);
    return 0;
}

static int queue_eos(int descriptor, uint64_t session_id, uint64_t pts) {
    uint8_t payload[8];
    put_u64(payload, pts);
    for (;;) {
        struct response response;
        if (rpc(descriptor, DSCB_EOS, session_id, payload, sizeof(payload),
                &response) != 0) return -1;
        if (response.status == DSCB_AGAIN) {
            free_response(&response);
            usleep(2000);
            continue;
        }
        int result = response.status == DSCB_OK
                ? 0 : report_error("eos", &response);
        free_response(&response);
        return result;
    }
}

struct pipe_output_state {
    uint32_t frames;
    uint64_t previous_pts;
    int have_pts;
    int saw_eos;
};

static int drain_output(int descriptor, uint64_t session_id, uint32_t timeout_ms,
                        struct pipe_output_state *state) {
    uint8_t request[4];
    put_u32(request, timeout_ms);
    struct response response;
    int shared_result = output_shared_memory(descriptor, session_id, timeout_ms,
                                             &response);
    if (shared_result < 0) return -1;
    if (shared_result > 0 && rpc(descriptor, DSCB_OUTPUT, session_id, request,
            sizeof(request), &response) != 0) return -1;
    int result = 0;
    if (response.status == DSCB_AGAIN) {
        result = 1;
    } else if (response.status == DSCB_FORMAT_CHANGED) {
        if (response.payload_length == 20) {
            fprintf(stderr,
                    "dawnshell-codec: output-format width=%" PRIu32
                    " height=%" PRIu32 " stride=%" PRIu32
                    " slice-height=%" PRIu32 " pixel-format=%" PRIu32 "\n",
                    get_u32(response.payload), get_u32(response.payload + 4),
                    get_u32(response.payload + 8), get_u32(response.payload + 12),
                    get_u32(response.payload + 16));
        } else {
            fprintf(stderr, "dawnshell-codec: malformed output format\n");
            result = 3;
        }
        if (result == 0) result = 2;
    } else if (response.status != DSCB_OK) {
        result = report_error("output", &response) + 2;
    } else if (response.payload_length < 16) {
        fprintf(stderr, "dawnshell-codec: malformed output record\n");
        result = 3;
    } else {
        uint64_t pts = get_u64(response.payload);
        uint32_t flags = get_u32(response.payload + 8);
        uint32_t length = get_u32(response.payload + 12);
        if (length != response.payload_length - 16) {
            fprintf(stderr, "dawnshell-codec: output length mismatch\n");
            result = 3;
        } else if (length > 0
                && (flags & DSCB_BUFFER_FLAG_CODEC_CONFIG) == 0
                && state->have_pts && pts < state->previous_pts) {
            fprintf(stderr,
                    "dawnshell-codec: non-monotonic output PTS=%" PRIu64
                    " previous=%" PRIu64 "\n",
                    pts, state->previous_pts);
            result = 3;
        } else if (fwrite(response.payload, 1, response.payload_length, stdout)
                != response.payload_length) {
            result = -1;
        } else {
            if (length > 0 && (flags & DSCB_BUFFER_FLAG_CODEC_CONFIG) == 0) {
                state->frames++;
                state->previous_pts = pts;
                state->have_pts = 1;
            }
            if ((flags & DSCB_BUFFER_FLAG_EOS) != 0) state->saw_eos = 1;
        }
    }
    free_response(&response);
    return result;
}

struct decode_test_state {
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate;
    uint32_t frame_count;
    int format_seen;
    int saw_eos;
};

static int drain_decode_test(int descriptor, uint64_t session_id,
                             uint32_t timeout_ms, struct decode_test_state *state) {
    uint8_t request[4];
    put_u32(request, timeout_ms);
    struct response response;
    int shared_result = output_shared_memory(descriptor, session_id, timeout_ms,
                                             &response);
    if (shared_result < 0) return -1;
    if (shared_result > 0 && rpc(descriptor, DSCB_OUTPUT, session_id, request,
            sizeof(request), &response) != 0) return -1;
    int result = 0;
    if (response.status == DSCB_AGAIN) {
        result = 1;
    } else if (response.status == DSCB_FORMAT_CHANGED) {
        if (response.payload_length != 20
                || get_u32(response.payload) != state->width
                || get_u32(response.payload + 4) != state->height
                || get_u32(response.payload + 16) != DSCB_PIXEL_FORMAT_I420) {
            fprintf(stderr, "dawnshell-codec: unexpected decode output format\n");
            result = 3;
        } else {
            state->format_seen = 1;
            result = 2;
        }
    } else if (response.status != DSCB_OK) {
        result = report_error("decode-test output", &response) + 2;
    } else if (response.payload_length < 16) {
        fprintf(stderr, "dawnshell-codec: malformed decode-test output\n");
        result = 3;
    } else {
        uint64_t pts = get_u64(response.payload);
        uint32_t flags = get_u32(response.payload + 8);
        uint32_t length = get_u32(response.payload + 12);
        if (length != response.payload_length - 16) {
            fprintf(stderr, "dawnshell-codec: decode-test output length mismatch\n");
            result = 3;
        } else if (length > 0) {
            uint32_t expected_length = state->width * state->height * 3u / 2u;
            uint64_t expected_pts = (uint64_t)state->frame_count * 1000000u
                    / state->frame_rate;
            if (length != expected_length || pts != expected_pts) {
                fprintf(stderr,
                        "dawnshell-codec: frame mismatch index=%" PRIu32
                        " pts=%" PRIu64 " expected=%" PRIu64
                        " bytes=%" PRIu32 " expected-bytes=%" PRIu32 "\n",
                        state->frame_count, pts, expected_pts, length, expected_length);
                result = 3;
            } else if (fwrite(response.payload + 16, 1, length, stdout) != length) {
                result = -1;
            } else {
                state->frame_count++;
            }
        }
        if ((flags & DSCB_BUFFER_FLAG_EOS) != 0) state->saw_eos = 1;
    }
    free_response(&response);
    return result;
}

static int find_aud(const uint8_t *data, size_t length, size_t from,
                    size_t *position) {
    for (size_t index = from; index + 4 < length; index++) {
        size_t prefix = 0;
        if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
            prefix = 3;
        } else if (index + 5 < length && data[index] == 0
                && data[index + 1] == 0 && data[index + 2] == 0
                && data[index + 3] == 1) {
            prefix = 4;
        }
        if (prefix > 0 && (data[index + prefix] & 0x1fu) == 9u) {
            *position = index;
            return 1;
        }
    }
    return 0;
}

static int read_file(const char *path, uint8_t **data, size_t *length) {
    FILE *input = fopen(path, "rb");
    if (input == NULL) return -1;
    if (fseek(input, 0, SEEK_END) != 0) {
        fclose(input);
        return -1;
    }
    long size = ftell(input);
    if (size <= 0 || (unsigned long)size > DSCB_MAX_PAYLOAD) {
        fclose(input);
        errno = EFBIG;
        return -1;
    }
    rewind(input);
    uint8_t *bytes = malloc((size_t)size);
    if (bytes == NULL || fread(bytes, 1, (size_t)size, input) != (size_t)size) {
        free(bytes);
        fclose(input);
        return -1;
    }
    fclose(input);
    *data = bytes;
    *length = (size_t)size;
    return 0;
}

static int load_access_units(const char *path, uint32_t expected_frames,
                             uint8_t **vector, size_t *vector_length,
                             size_t boundaries[1025], size_t *boundary_count) {
    if (read_file(path, vector, vector_length) != 0) {
        fprintf(stderr, "dawnshell-codec: read %s failed: %s\n", path,
                strerror(errno));
        return 1;
    }
    *boundary_count = 0;
    size_t search = 0;
    size_t aud;
    while (*boundary_count < 1024
            && find_aud(*vector, *vector_length, search, &aud)) {
        boundaries[(*boundary_count)++] = aud;
        search = aud + 4;
    }
    if (*boundary_count == 0 || *boundary_count != expected_frames) {
        fprintf(stderr,
                "dawnshell-codec: Annex-B AUD count=%zu expected=%" PRIu32 "\n",
                *boundary_count, expected_frames);
        free(*vector);
        *vector = NULL;
        return 1;
    }
    if (boundaries[0] != 0) boundaries[0] = 0;
    boundaries[*boundary_count] = *vector_length;
    return 0;
}

static int run_decode_test(int descriptor, const char *path, uint32_t width,
                           uint32_t height, uint32_t frame_rate,
                           uint32_t expected_frames) {
    uint8_t *vector = NULL;
    size_t vector_length = 0;
    size_t boundaries[1025];
    size_t boundary_count = 0;
    if (load_access_units(path, expected_frames, &vector, &vector_length,
                          boundaries, &boundary_count) != 0) return 1;

    uint64_t session_id = 0;
    if (create_session(descriptor, DSCB_MODE_DECODE, DSCB_CODEC_AVC, width,
                       height, frame_rate, 2000000, &session_id, NULL) != 0) {
        free(vector);
        return 1;
    }
    struct decode_test_state state = {
            .width = width,
            .height = height,
            .frame_rate = frame_rate,
            .frame_count = 0,
            .format_seen = 0,
            .saw_eos = 0
    };
    int result = 0;
    for (size_t index = 0; index < boundary_count; index++) {
        size_t packet_length = boundaries[index + 1] - boundaries[index];
        uint8_t header[16];
        put_u64(header, (uint64_t)index * 1000000u / frame_rate);
        put_u32(header + 8, 0);
        put_u32(header + 12, (uint32_t)packet_length);
        if (queue_input(descriptor, session_id, header, vector + boundaries[index],
                        (uint32_t)packet_length) != 0) {
            result = 1;
            break;
        }
        for (;;) {
            int drained = drain_decode_test(descriptor, session_id, 0, &state);
            if (drained == 1) break;
            if (drained < 0 || drained > 2) {
                result = 1;
                break;
            }
        }
        if (result != 0) break;
    }
    free(vector);
    if (result == 0) {
        result = queue_eos(descriptor, session_id,
                (uint64_t)expected_frames * 1000000u / frame_rate);
    }
    for (int idle = 0; result == 0 && !state.saw_eos && idle < 50;) {
        int drained = drain_decode_test(descriptor, session_id, 100, &state);
        if (drained == 1) idle++;
        else if (drained < 0 || drained > 2) result = 1;
    }
    if (result == 0 && (!state.format_seen || !state.saw_eos
            || state.frame_count != expected_frames)) {
        fprintf(stderr,
                "dawnshell-codec: decode-test incomplete format=%d eos=%d"
                " frames=%" PRIu32 " expected=%" PRIu32 "\n",
                state.format_seen, state.saw_eos, state.frame_count, expected_frames);
        result = 1;
    }
    if (result == 0) {
        fprintf(stderr, "dawnshell-codec: decode-test passed frames=%" PRIu32
                " pts=exact pixel-format=I420\n", state.frame_count);
    }
    if (report_session_stats(descriptor, session_id) != 0) result = 1;
    close_session(descriptor, session_id);
    return result;
}

static int inspect_vector(const char *path, uint32_t expected_frames) {
    uint8_t *vector = NULL;
    size_t length = 0;
    if (read_file(path, &vector, &length) != 0) {
        fprintf(stderr, "dawnshell-codec: read %s failed: %s\n", path,
                strerror(errno));
        return 1;
    }
    uint32_t count = 0;
    size_t search = 0;
    size_t aud;
    while (find_aud(vector, length, search, &aud)) {
        count++;
        search = aud + 4;
    }
    free(vector);
    if (count != expected_frames) {
        fprintf(stderr, "dawnshell-codec: vector AUD count=%" PRIu32
                " expected=%" PRIu32 "\n", count, expected_frames);
        return 1;
    }
    printf("annex_b_bytes=%zu access_units=%" PRIu32 "\n", length, count);
    return 0;
}

struct encode_test_state {
    uint32_t frame_rate;
    uint32_t frame_count;
    uint64_t output_bytes;
    int format_seen;
    int saw_eos;
    int first_frame_key;
};

static int drain_encode_test(int descriptor, uint64_t session_id,
                             uint32_t timeout_ms, struct encode_test_state *state) {
    uint8_t request[4];
    put_u32(request, timeout_ms);
    struct response response;
    if (rpc(descriptor, DSCB_OUTPUT, session_id, request, sizeof(request),
            &response) != 0) return -1;
    int result = 0;
    if (response.status == DSCB_AGAIN) {
        result = 1;
    } else if (response.status == DSCB_FORMAT_CHANGED) {
        if (response.payload_length != 20
                || get_u32(response.payload + 16) != 0) {
            fprintf(stderr, "dawnshell-codec: unexpected encode output format\n");
            result = 3;
        } else {
            state->format_seen = 1;
            result = 2;
        }
    } else if (response.status != DSCB_OK) {
        result = report_error("encode-test output", &response) + 2;
    } else if (response.payload_length < 16) {
        fprintf(stderr, "dawnshell-codec: malformed encode-test output\n");
        result = 3;
    } else {
        uint64_t pts = get_u64(response.payload);
        uint32_t flags = get_u32(response.payload + 8);
        uint32_t length = get_u32(response.payload + 12);
        if (length != response.payload_length - 16) {
            fprintf(stderr, "dawnshell-codec: encode-test output length mismatch\n");
            result = 3;
        } else if (length > 0) {
            if ((flags & DSCB_BUFFER_FLAG_CODEC_CONFIG) == 0) {
                if (state->frame_count == 0
                        && (flags & DSCB_BUFFER_FLAG_KEY_FRAME) != 0) {
                    state->first_frame_key = 1;
                }
                uint64_t expected_pts = (uint64_t)state->frame_count * 1000000u
                        / state->frame_rate;
                if (pts != expected_pts) {
                    fprintf(stderr,
                            "dawnshell-codec: encoded PTS mismatch index=%" PRIu32
                            " pts=%" PRIu64 " expected=%" PRIu64 "\n",
                            state->frame_count, pts, expected_pts);
                    result = 3;
                } else {
                    state->frame_count++;
                }
            }
            if (result == 0 && fwrite(response.payload + 16, 1, length, stdout)
                    != length) {
                result = -1;
            } else if (result == 0) {
                state->output_bytes += length;
            }
        }
        if ((flags & DSCB_BUFFER_FLAG_EOS) != 0) state->saw_eos = 1;
    }
    free_response(&response);
    return result;
}

static void fill_i420_pattern(uint8_t *frame, uint32_t width, uint32_t height,
                              uint32_t frame_index) {
    size_t y_size = (size_t)width * height;
    size_t chroma_size = y_size / 4;
    for (uint32_t y = 0; y < height; y++) {
        for (uint32_t x = 0; x < width; x++) {
            frame[(size_t)y * width + x] =
                    (uint8_t)((x * 3u + y * 5u + frame_index * 11u) & 0xffu);
        }
    }
    for (size_t index = 0; index < chroma_size; index++) {
        frame[y_size + index] = (uint8_t)(64u + (index + frame_index * 3u) % 96u);
        frame[y_size + chroma_size + index] =
                (uint8_t)(192u - (index + frame_index * 5u) % 96u);
    }
}

static int convert_i420_for_encoder(uint32_t color_format, uint32_t width,
                                    uint32_t height, const uint8_t *i420,
                                    uint8_t *converted,
                                    const uint8_t **encoder_input) {
    size_t y_size = (size_t)width * height;
    size_t chroma_size = y_size / 4;
    *encoder_input = i420;
    if (color_format == DSCB_COLOR_YUV420_SEMIPLANAR) {
        memcpy(converted, i420, y_size);
        for (size_t index = 0; index < chroma_size; index++) {
            converted[y_size + index * 2] = i420[y_size + index];
            converted[y_size + index * 2 + 1] =
                    i420[y_size + chroma_size + index];
        }
        *encoder_input = converted;
    } else if (color_format != DSCB_COLOR_YUV420_PLANAR
            && color_format != DSCB_COLOR_YUV420_FLEXIBLE) {
        fprintf(stderr, "dawnshell-codec: unsupported encoder color format=%" PRIu32
                "\n", color_format);
        return 1;
    }
    return 0;
}

static int queue_encoder_frame(int descriptor, uint64_t session_id,
                               uint32_t color_format, uint32_t width,
                               uint32_t height, uint32_t frame_rate,
                               uint32_t frame_index, uint8_t *i420,
                               uint8_t *converted) {
    size_t y_size = (size_t)width * height;
    size_t chroma_size = y_size / 4;
    fill_i420_pattern(i420, width, height, frame_index);
    const uint8_t *input;
    if (convert_i420_for_encoder(color_format, width, height, i420, converted,
                                 &input) != 0) return 1;
    uint8_t header[16];
    put_u64(header, (uint64_t)frame_index * 1000000u / frame_rate);
    put_u32(header + 8, 0);
    put_u32(header + 12, (uint32_t)(y_size + chroma_size * 2));
    return queue_input(descriptor, session_id, header, input,
                       (uint32_t)(y_size + chroma_size * 2));
}

static uint64_t elapsed_microseconds(const struct timespec *start,
                                     const struct timespec *end) {
    int64_t seconds = end->tv_sec - start->tv_sec;
    int64_t nanoseconds = end->tv_nsec - start->tv_nsec;
    return (uint64_t)(seconds * 1000000 + nanoseconds / 1000);
}

static int run_transcode_test(int descriptor, const char *path, uint32_t width,
                              uint32_t height, uint32_t frame_rate,
                              uint32_t expected_frames, uint32_t bitrate) {
    uint8_t *vector = NULL;
    size_t vector_length = 0;
    size_t boundaries[1025];
    size_t boundary_count = 0;
    if (load_access_units(path, expected_frames, &vector, &vector_length,
                          boundaries, &boundary_count) != 0) return 1;

    uint64_t session_id = 0;
    if (create_transcode_session(descriptor, DSCB_CODEC_AVC, DSCB_CODEC_AVC,
            width, height, frame_rate, bitrate, &session_id) != 0) {
        free(vector);
        return 1;
    }
    if (request_keyframe(descriptor, session_id) != 0) {
        free(vector);
        close_session(descriptor, session_id);
        return 1;
    }
    struct encode_test_state state = {
            .frame_rate = frame_rate,
            .frame_count = 0,
            .output_bytes = 0,
            .format_seen = 0,
            .saw_eos = 0,
            .first_frame_key = 0
    };
    struct timespec started;
    struct timespec finished;
    clock_gettime(CLOCK_MONOTONIC, &started);
    int result = 0;
    for (size_t index = 0; index < boundary_count; index++) {
        size_t packet_length = boundaries[index + 1] - boundaries[index];
        uint8_t header[16];
        put_u64(header, (uint64_t)index * 1000000u / frame_rate);
        put_u32(header + 8, 0);
        put_u32(header + 12, (uint32_t)packet_length);
        if (queue_input(descriptor, session_id, header,
                        vector + boundaries[index],
                        (uint32_t)packet_length) != 0) {
            result = 1;
            break;
        }
        for (;;) {
            int drained = drain_encode_test(descriptor, session_id, 0, &state);
            if (drained == 1) break;
            if (drained < 0 || drained > 2) {
                result = 1;
                break;
            }
        }
        if (result != 0) break;
    }
    free(vector);
    if (result == 0) {
        result = queue_eos(descriptor, session_id,
                (uint64_t)expected_frames * 1000000u / frame_rate);
    }
    for (int idle = 0; result == 0 && !state.saw_eos && idle < 50;) {
        int drained = drain_encode_test(descriptor, session_id, 100, &state);
        if (drained == 1) idle++;
        else if (drained < 0 || drained > 2) result = 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &finished);
    uint64_t elapsed_us = elapsed_microseconds(&started, &finished);
    uint64_t media_duration_us = (uint64_t)expected_frames * 1000000u
            / frame_rate;
    if (result == 0 && (!state.format_seen || !state.saw_eos
            || state.frame_count != expected_frames || state.output_bytes == 0
            || !state.first_frame_key || elapsed_us > media_duration_us)) {
        fprintf(stderr,
                "dawnshell-codec: transcode-test incomplete format=%d eos=%d"
                " frames=%" PRIu32 "/%" PRIu32 " keyframe=%d bytes=%" PRIu64
                " elapsed-us=%" PRIu64 " media-us=%" PRIu64 "\n",
                state.format_seen, state.saw_eos, state.frame_count,
                expected_frames, state.first_frame_key, state.output_bytes,
                elapsed_us, media_duration_us);
        result = 1;
    }
    if (result == 0) {
        fprintf(stderr,
                "dawnshell-codec: transcode-test passed size=%" PRIu32 "x%" PRIu32
                " frames=%" PRIu32 " pts=exact first-frame=key"
                " elapsed-us=%" PRIu64 " media-us=%" PRIu64 " realtime=true\n",
                width, height, state.frame_count, elapsed_us, media_duration_us);
    }
    if (report_session_stats(descriptor, session_id) != 0) result = 1;
    close_session(descriptor, session_id);
    return result;
}

static int run_orphan_test(int descriptor, const char *kind) {
    uint64_t session_id = 0;
    int result;
    if (strcmp(kind, "decode") == 0) {
        result = create_session(descriptor, DSCB_MODE_DECODE, DSCB_CODEC_AVC,
                128, 96, 10, 1000000, &session_id, NULL);
    } else if (strcmp(kind, "transcode") == 0) {
        result = create_transcode_session(descriptor, DSCB_CODEC_AVC,
                DSCB_CODEC_AVC, 128, 96, 10, 1000000, &session_id);
    } else {
        return 2;
    }
    if (result != 0) return 1;
    fprintf(stderr,
            "dawnshell-codec: orphan-test abandoning %s session=%" PRIu64 "\n",
            kind, session_id);
    fflush(NULL);
    _exit(0);
}

static int run_hold_test(int descriptor, const char *kind,
                          uint32_t duration_ms) {
    uint64_t session_id = 0;
    int result;
    if (strcmp(kind, "decode") == 0) {
        result = create_session(descriptor, DSCB_MODE_DECODE, DSCB_CODEC_AVC,
                128, 96, 10, 1000000, &session_id, NULL);
    } else if (strcmp(kind, "encode") == 0) {
        result = create_session(descriptor, DSCB_MODE_ENCODE, DSCB_CODEC_AVC,
                128, 96, 10, 1000000, &session_id, NULL);
    } else if (strcmp(kind, "transcode") == 0) {
        result = create_transcode_session(descriptor, DSCB_CODEC_AVC,
                DSCB_CODEC_AVC, 128, 96, 10, 1000000, &session_id);
    } else {
        return 2;
    }
    if (result != 0) return 1;
    fprintf(stderr,
            "dawnshell-codec: hold-test ready kind=%s session=%" PRIu64
            " duration-ms=%" PRIu32 "\n",
            kind, session_id, duration_ms);
    fflush(NULL);
    struct timespec remaining = {
            .tv_sec = (time_t)(duration_ms / 1000u),
            .tv_nsec = (long)(duration_ms % 1000u) * 1000000L
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) {
            result = 1;
            break;
        }
    }
    if (result == 0 && report_session_stats(descriptor, session_id) != 0) {
        result = 1;
    }
    close_session(descriptor, session_id);
    return result;
}

static int run_idle_timeout_test(int descriptor, uint32_t duration_ms) {
    fprintf(stderr,
            "dawnshell-codec: idle-test waiting duration-ms=%" PRIu32 "\n",
            duration_ms);
    fflush(NULL);
    struct timespec remaining = {
            .tv_sec = (time_t)(duration_ms / 1000u),
            .tv_nsec = (long)(duration_ms % 1000u) * 1000000L
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) {
            fprintf(stderr, "dawnshell-codec: idle-test sleep failed: %s\n",
                    strerror(errno));
            return 1;
        }
    }
    struct response response;
    if (rpc(descriptor, DSCB_HEALTH, 0, NULL, 0, &response) == 0) {
        free_response(&response);
        fprintf(stderr,
                "dawnshell-codec: idle-test peer remained connected unexpectedly\n");
        return 1;
    }
    fprintf(stderr,
            "dawnshell-codec: idle-test passed broker closed idle peer\n");
    return 0;
}

static int run_slow_output_test(int descriptor) {
    const uint32_t width = 128;
    const uint32_t height = 96;
    const uint32_t frame_rate = 10;
    const uint32_t frame_size = width * height * 3u / 2u;
    uint64_t session_id = 0;
    if (create_session(descriptor, DSCB_MODE_ENCODE, DSCB_CODEC_AVC,
                       width, height, frame_rate, 1000000,
                       &session_id, NULL) != 0) return 1;
    uint8_t *payload = calloc(1, 16u + frame_size);
    if (payload == NULL) {
        close_session(descriptor, session_id);
        return 1;
    }
    put_u32(payload + 8, 0);
    put_u32(payload + 12, frame_size);
    uint32_t accepted = 0;
    int reached_backpressure = 0;
    int result = 0;
    for (uint32_t frame = 0; frame < 64; frame++) {
        put_u64(payload, (uint64_t)frame * 1000000u / frame_rate);
        struct response response;
        if (rpc(descriptor, DSCB_INPUT, session_id, payload,
                16u + frame_size, &response) != 0) {
            result = 1;
            break;
        }
        if (response.status == DSCB_OK) {
            accepted++;
        } else if (response.status == DSCB_AGAIN) {
            reached_backpressure = 1;
            free_response(&response);
            break;
        } else {
            result = report_error("slow-output input", &response);
            free_response(&response);
            break;
        }
        free_response(&response);
    }
    free(payload);
    if (result == 0 && (!reached_backpressure || accepted == 0)) {
        fprintf(stderr,
                "dawnshell-codec: slow-output-test missing backpressure"
                " accepted=%" PRIu32 "\n", accepted);
        result = 1;
    }
    if (result == 0 && report_session_stats(descriptor, session_id) != 0) {
        result = 1;
    }
    close_session(descriptor, session_id);
    if (result == 0) {
        fprintf(stderr,
                "dawnshell-codec: slow-output-test passed"
                " accepted=%" PRIu32 " backpressure=again\n", accepted);
    }
    return result;
}

static int run_encode_test(int descriptor, uint32_t width, uint32_t height,
                           uint32_t frame_rate, uint32_t frames,
                           uint32_t bitrate) {
    uint64_t session_id = 0;
    uint32_t color_format = 0;
    if (create_session(descriptor, DSCB_MODE_ENCODE, DSCB_CODEC_AVC, width,
                       height, frame_rate, bitrate, &session_id,
                       &color_format) != 0) return 1;
    if (request_keyframe(descriptor, session_id) != 0) {
        close_session(descriptor, session_id);
        return 1;
    }
    size_t frame_size = (size_t)width * height * 3u / 2u;
    uint8_t *i420 = malloc(frame_size);
    uint8_t *converted = malloc(frame_size);
    if (i420 == NULL || converted == NULL) {
        free(i420);
        free(converted);
        close_session(descriptor, session_id);
        return 1;
    }
    struct encode_test_state state = {
            .frame_rate = frame_rate,
            .frame_count = 0,
            .output_bytes = 0,
            .format_seen = 0,
            .saw_eos = 0,
            .first_frame_key = 0
    };
    struct timespec started;
    struct timespec finished;
    clock_gettime(CLOCK_MONOTONIC, &started);
    int result = 0;
    for (uint32_t frame = 0; frame < frames; frame++) {
        if (queue_encoder_frame(descriptor, session_id, color_format, width,
                                height, frame_rate, frame, i420, converted) != 0) {
            result = 1;
            break;
        }
        for (;;) {
            int drained = drain_encode_test(descriptor, session_id, 0, &state);
            if (drained == 1) break;
            if (drained < 0 || drained > 2) {
                result = 1;
                break;
            }
        }
        if (result != 0) break;
    }
    free(i420);
    free(converted);
    if (result == 0) {
        result = queue_eos(descriptor, session_id,
                (uint64_t)frames * 1000000u / frame_rate);
    }
    for (int idle = 0; result == 0 && !state.saw_eos && idle < 50;) {
        int drained = drain_encode_test(descriptor, session_id, 100, &state);
        if (drained == 1) idle++;
        else if (drained < 0 || drained > 2) result = 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &finished);
    uint64_t elapsed_us = elapsed_microseconds(&started, &finished);
    uint64_t media_duration_us = (uint64_t)frames * 1000000u / frame_rate;
    if (result == 0 && (!state.format_seen || !state.saw_eos
            || state.frame_count != frames || state.output_bytes == 0
            || !state.first_frame_key
            || elapsed_us > media_duration_us)) {
        fprintf(stderr,
                "dawnshell-codec: encode-test incomplete format=%d eos=%d"
                " frames=%" PRIu32 "/%" PRIu32 " keyframe=%d bytes=%" PRIu64
                " elapsed-us=%" PRIu64 " media-us=%" PRIu64 "\n",
                state.format_seen, state.saw_eos, state.frame_count, frames,
                state.first_frame_key, state.output_bytes, elapsed_us,
                media_duration_us);
        result = 1;
    }
    if (result == 0) {
        fprintf(stderr,
                "dawnshell-codec: encode-test passed frames=%" PRIu32
                " pts=exact first-frame=key bytes=%" PRIu64
                " elapsed-us=%" PRIu64 "\n",
                state.frame_count, state.output_bytes, elapsed_us);
    }
    if (report_session_stats(descriptor, session_id) != 0) result = 1;
    close_session(descriptor, session_id);
    return result;
}

static int run_probe(int descriptor, uint32_t mode, uint32_t codec,
                     uint32_t width, uint32_t height) {
    uint64_t session_id = 0;
    if (create_session(descriptor, mode, codec, width, height, 30, 2000000,
                       &session_id, NULL) != 0) return 1;
    int result = 0;
    if (mode == DSCB_MODE_ENCODE) {
        result = request_keyframe(descriptor, session_id);
    }
    if (result == 0) {
        result = simple_request(descriptor, DSCB_FLUSH, session_id, NULL, 0,
                                "flush");
    }
    if (result == 0) {
        printf("hardware_session=%" PRIu64 " protocol=%u\n",
               session_id, DSCB_VERSION);
    }
    if (report_session_stats(descriptor, session_id) != 0) result = 1;
    close_session(descriptor, session_id);
    return result;
}

static int run_pipe_session(int descriptor, uint64_t session_id, uint32_t mode,
                            uint32_t color_format, uint32_t width,
                            uint32_t height, int request_sync_frame) {
    int result = 0;
    if (request_sync_frame && request_keyframe(descriptor, session_id) != 0) {
        close_session(descriptor, session_id);
        return 1;
    }
    uint64_t last_pts = 0;
    uint32_t input_frames = 0;
    struct pipe_output_state output_state = {0};
    for (;;) {
        uint8_t header[16];
        int header_result = read_record_header(header);
        if (header_result < 0) {
            fprintf(stderr, "dawnshell-codec: truncated input record\n");
            result = 1;
            break;
        }
        if (header_result == 0) break;
        last_pts = get_u64(header);
        uint32_t flags = get_u32(header + 8);
        uint32_t length = get_u32(header + 12);
        if (length > DSCB_MAX_PAYLOAD - 16) {
            fprintf(stderr, "dawnshell-codec: input record exceeds protocol limit\n");
            result = 1;
            break;
        }
        uint8_t *data = length == 0 ? NULL : malloc(length);
        if (length > 0 && (data == NULL || fread(data, 1, length, stdin) != length)) {
            free(data);
            fprintf(stderr, "dawnshell-codec: truncated input payload\n");
            result = 1;
            break;
        }
        if ((flags & DSCB_BUFFER_FLAG_EOS) != 0) {
            free(data);
            break;
        }
        if (length > 0 && (flags & DSCB_BUFFER_FLAG_CODEC_CONFIG) == 0) {
            input_frames++;
        }
        const uint8_t *codec_input = data;
        uint8_t *converted = NULL;
        if (mode == DSCB_MODE_ENCODE) {
            size_t expected = (size_t)width * height * 3u / 2u;
            if (length != expected) {
                free(data);
                fprintf(stderr, "dawnshell-codec: encoder input must be packed I420\n");
                result = 1;
                break;
            }
            converted = malloc(length);
            if (converted == NULL || convert_i420_for_encoder(color_format,
                    width, height, data, converted, &codec_input) != 0) {
                free(converted);
                free(data);
                result = 1;
                break;
            }
        }
        if (queue_input(descriptor, session_id, header, codec_input, length) != 0) {
            free(converted);
            free(data);
            result = 1;
            break;
        }
        free(converted);
        free(data);
        for (;;) {
            int drained = drain_output(descriptor, session_id, 0, &output_state);
            if (drained == 1) break;
            if (drained < 0 || drained > 2) {
                result = 1;
                break;
            }
        }
        if (result != 0) break;
    }
    if (result == 0) {
        result = queue_eos(descriptor, session_id, last_pts);
    }
    for (int idle = 0; result == 0 && !output_state.saw_eos && idle < 50;) {
        int drained = drain_output(descriptor, session_id, 100, &output_state);
        if (drained == 1) idle++;
        else if (drained < 0 || drained > 2) result = 1;
    }
    if (result == 0 && !output_state.saw_eos) {
        fprintf(stderr, "dawnshell-codec: timed out waiting for output EOS\n");
        result = 1;
    }
    if (result == 0 && (input_frames == 0 || output_state.frames != input_frames)) {
        fprintf(stderr,
                "dawnshell-codec: pipe frame count mismatch input=%" PRIu32
                " output=%" PRIu32 "\n",
                input_frames, output_state.frames);
        result = 1;
    }
    if (report_session_stats(descriptor, session_id) != 0) result = 1;
    close_session(descriptor, session_id);
    return result;
}

static int run_pipe(int descriptor, uint32_t mode, uint32_t codec,
                    uint32_t width, uint32_t height, uint32_t frame_rate,
                    uint32_t bitrate) {
    uint64_t session_id = 0;
    uint32_t color_format = 0;
    if (create_session(descriptor, mode, codec, width, height, frame_rate, bitrate,
                       &session_id, &color_format) != 0) return 1;
    return run_pipe_session(descriptor, session_id, mode, color_format,
                            width, height, mode == DSCB_MODE_ENCODE);
}

static int run_transcode(int descriptor, uint32_t input_codec,
                         uint32_t output_codec, uint32_t width, uint32_t height,
                         uint32_t frame_rate, uint32_t bitrate) {
    uint64_t session_id = 0;
    if (create_transcode_session(descriptor, input_codec, output_codec, width,
            height, frame_rate, bitrate, &session_id) != 0) return 1;
    return run_pipe_session(descriptor, session_id, DSCB_MODE_DECODE, 0,
                            width, height, 1);
}

static void usage(FILE *stream) {
    fprintf(stream,
            "usage:\n"
            "  dawnshell-codec inspect-vector FILE FRAMES\n"
            "  dawnshell-codec capabilities\n"
            "  dawnshell-codec health [--format json]\n"
            "  dawnshell-codec negative-test\n"
            "  dawnshell-codec probe MODE CODEC [WIDTH HEIGHT]\n"
            "  dawnshell-codec decode-test FILE WIDTH HEIGHT FPS FRAMES\n"
            "  dawnshell-codec encode-test WIDTH HEIGHT FPS FRAMES BITRATE\n"
            "  dawnshell-codec transcode-test FILE WIDTH HEIGHT FPS FRAMES BITRATE\n"
            "  dawnshell-codec orphan-test decode|transcode\n"
            "  dawnshell-codec hold-test decode|encode|transcode DURATION_MS\n"
            "  dawnshell-codec idle-test DURATION_MS\n"
            "  dawnshell-codec slow-output-test\n"
            "  dawnshell-codec pipe MODE CODEC WIDTH HEIGHT FPS BITRATE\n"
            "  dawnshell-codec transcode INPUT_CODEC OUTPUT_CODEC WIDTH HEIGHT FPS BITRATE\n\n"
            "MODE is decode or encode; CODEC is avc/h264 or hevc/h265.\n"
            "pipe stdin/stdout records are: pts_us:u64, flags:u32, length:u32, data; big-endian.\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(stderr);
        return 2;
    }
    if (strcmp(argv[1], "inspect-vector") == 0 && argc == 4) {
        uint32_t frames;
        if (parse_u32(argv[3], 1, 1024, &frames) != 0) {
            usage(stderr);
            return 2;
        }
        return inspect_vector(argv[2], frames);
    }
    int descriptor = connect_broker();
    if (descriptor < 0) {
        fprintf(stderr, "dawnshell-codec: connect @%s failed: %s\n",
                DSCB_SOCKET_NAME, strerror(errno));
        return 3;
    }
    if (hello(descriptor) != 0) {
        fprintf(stderr, "dawnshell-codec: protocol handshake failed: %s\n",
                strerror(errno));
        close(descriptor);
        return 3;
    }
    int result = 2;
    if (strcmp(argv[1], "capabilities") == 0 && argc == 2) {
        result = print_capabilities(descriptor);
    } else if (strcmp(argv[1], "health") == 0
            && (argc == 2 || (argc == 4 && strcmp(argv[2], "--format") == 0
            && strcmp(argv[3], "json") == 0))) {
        result = print_health(descriptor);
    } else if (strcmp(argv[1], "negative-test") == 0 && argc == 2) {
        result = run_negative_test(descriptor);
    } else if (strcmp(argv[1], "probe") == 0 && (argc == 4 || argc == 6)) {
        uint32_t mode, codec, width = 128, height = 128;
        if (parse_mode(argv[2], &mode) == 0 && parse_codec(argv[3], &codec) == 0
                && (argc == 4 || (parse_u32(argv[4], 16, 4096, &width) == 0
                && parse_u32(argv[5], 16, 4096, &height) == 0))) {
            result = run_probe(descriptor, mode, codec, width, height);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "pipe") == 0 && argc == 8) {
        uint32_t mode, codec, width, height, frame_rate, bitrate;
        if (parse_mode(argv[2], &mode) == 0 && parse_codec(argv[3], &codec) == 0
                && parse_u32(argv[4], 16, 4096, &width) == 0
                && parse_u32(argv[5], 16, 4096, &height) == 0
                && parse_u32(argv[6], 1, 240, &frame_rate) == 0
                && parse_u32(argv[7], 1000, 100000000, &bitrate) == 0) {
            result = run_pipe(descriptor, mode, codec, width, height,
                              frame_rate, bitrate);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "transcode") == 0 && argc == 8) {
        uint32_t input_codec, output_codec, width, height, frame_rate, bitrate;
        if (parse_codec(argv[2], &input_codec) == 0
                && parse_codec(argv[3], &output_codec) == 0
                && parse_u32(argv[4], 16, 4096, &width) == 0
                && parse_u32(argv[5], 16, 4096, &height) == 0
                && parse_u32(argv[6], 1, 240, &frame_rate) == 0
                && parse_u32(argv[7], 1000, 100000000, &bitrate) == 0) {
            result = run_transcode(descriptor, input_codec, output_codec, width,
                                   height, frame_rate, bitrate);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "transcode-test") == 0 && argc == 8) {
        uint32_t width, height, frame_rate, frames, bitrate;
        if (parse_u32(argv[3], 16, 4096, &width) == 0
                && parse_u32(argv[4], 16, 4096, &height) == 0
                && parse_u32(argv[5], 1, 240, &frame_rate) == 0
                && parse_u32(argv[6], 1, 1024, &frames) == 0
                && parse_u32(argv[7], 1000, 100000000, &bitrate) == 0) {
            result = run_transcode_test(descriptor, argv[2], width, height,
                                        frame_rate, frames, bitrate);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "orphan-test") == 0 && argc == 3) {
        result = run_orphan_test(descriptor, argv[2]);
    } else if (strcmp(argv[1], "hold-test") == 0 && argc == 4) {
        uint32_t duration_ms;
        if (parse_u32(argv[3], 100, 900000, &duration_ms) == 0) {
            result = run_hold_test(descriptor, argv[2], duration_ms);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "idle-test") == 0 && argc == 3) {
        uint32_t duration_ms;
        if (parse_u32(argv[2], 31000, 60000, &duration_ms) == 0) {
            result = run_idle_timeout_test(descriptor, duration_ms);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "slow-output-test") == 0 && argc == 2) {
        result = run_slow_output_test(descriptor);
    } else if (strcmp(argv[1], "decode-test") == 0 && argc == 7) {
        uint32_t width, height, frame_rate, frames;
        if (parse_u32(argv[3], 16, 4096, &width) == 0
                && parse_u32(argv[4], 16, 4096, &height) == 0
                && parse_u32(argv[5], 1, 240, &frame_rate) == 0
                && parse_u32(argv[6], 1, 1024, &frames) == 0) {
            result = run_decode_test(descriptor, argv[2], width, height,
                                     frame_rate, frames);
        } else {
            usage(stderr);
        }
    } else if (strcmp(argv[1], "encode-test") == 0 && argc == 7) {
        uint32_t width, height, frame_rate, frames, bitrate;
        if (parse_u32(argv[2], 16, 4096, &width) == 0
                && parse_u32(argv[3], 16, 4096, &height) == 0
                && parse_u32(argv[4], 1, 240, &frame_rate) == 0
                && parse_u32(argv[5], 1, 1024, &frames) == 0
                && parse_u32(argv[6], 1000, 100000000, &bitrate) == 0) {
            result = run_encode_test(descriptor, width, height, frame_rate,
                                     frames, bitrate);
        } else {
            usage(stderr);
        }
    } else {
        usage(stderr);
    }
    close(descriptor);
    return result < 0 ? 3 : result;
}
