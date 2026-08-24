#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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
#define DSCB_MODE_DECODE 1u
#define DSCB_MODE_ENCODE 2u
#define DSCB_CODEC_AVC 1u
#define DSCB_CODEC_HEVC 2u
#define DSCB_OK 0
#define DSCB_AGAIN 1
#define DSCB_FORMAT_CHANGED 2
#define DSCB_MAX_PAYLOAD (8u * 1024u * 1024u)
#define DSCB_BUFFER_FLAG_EOS 4u
#define DSCB_PIXEL_FORMAT_I420 1u
#define DSCB_COLOR_YUV420_PLANAR 19u
#define DSCB_COLOR_YUV420_SEMIPLANAR 21u
#define DSCB_COLOR_YUV420_FLEXIBLE 0x7f420888u
#define DSCB_BUFFER_FLAG_CODEC_CONFIG 2u
#define DSCB_SOCKET_NAME "dawnshell.codec.v1"

struct response {
    uint16_t type;
    uint64_t session_id;
    uint32_t request_id;
    int32_t status;
    uint32_t payload_length;
    uint8_t *payload;
};

static uint32_t next_request_id = 1;

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

static int rpc(int descriptor, uint16_t type, uint64_t session_id,
               const void *payload, uint32_t payload_length,
               struct response *response) {
    uint8_t header[DSCB_HEADER_BYTES];
    memset(header, 0, sizeof(header));
    const uint32_t request_id = next_request_id++;
    put_u32(header, DSCB_MAGIC);
    put_u16(header + 4, DSCB_VERSION);
    put_u16(header + 6, type);
    put_u64(header + 12, session_id);
    put_u32(header + 20, payload_length);
    put_u32(header + 24, request_id);
    if (write_all(descriptor, header, sizeof(header)) != 0
            || (payload_length > 0
            && write_all(descriptor, payload, payload_length) != 0)) {
        return -1;
    }
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
    if (response.status != DSCB_OK) result = report_error("hello", &response);
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

static void close_session(int descriptor, uint64_t session_id) {
    if (session_id == 0) return;
    (void)simple_request(descriptor, DSCB_CLOSE, session_id, NULL, 0, "close");
}

static int queue_input(int descriptor, uint64_t session_id,
                       const uint8_t header[16], const uint8_t *data,
                       uint32_t length) {
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

static int drain_output(int descriptor, uint64_t session_id, uint32_t timeout_ms,
                        int *saw_eos) {
    uint8_t request[4];
    put_u32(request, timeout_ms);
    struct response response;
    if (rpc(descriptor, DSCB_OUTPUT, session_id, request, sizeof(request),
            &response) != 0) return -1;
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
        uint32_t flags = get_u32(response.payload + 8);
        uint32_t length = get_u32(response.payload + 12);
        if (length != response.payload_length - 16) {
            fprintf(stderr, "dawnshell-codec: output length mismatch\n");
            result = 3;
        } else if (fwrite(response.payload, 1, response.payload_length, stdout)
                != response.payload_length) {
            result = -1;
        } else if ((flags & DSCB_BUFFER_FLAG_EOS) != 0) {
            *saw_eos = 1;
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
    if (rpc(descriptor, DSCB_OUTPUT, session_id, request, sizeof(request),
            &response) != 0) return -1;
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

static int run_decode_test(int descriptor, const char *path, uint32_t width,
                           uint32_t height, uint32_t frame_rate,
                           uint32_t expected_frames) {
    uint8_t *vector = NULL;
    size_t vector_length = 0;
    if (read_file(path, &vector, &vector_length) != 0) {
        fprintf(stderr, "dawnshell-codec: read %s failed: %s\n", path,
                strerror(errno));
        return 1;
    }
    size_t boundaries[1025];
    size_t boundary_count = 0;
    size_t search = 0;
    size_t aud;
    while (boundary_count < 1024
            && find_aud(vector, vector_length, search, &aud)) {
        boundaries[boundary_count++] = aud;
        search = aud + 4;
    }
    if (boundary_count == 0 || boundary_count != expected_frames) {
        fprintf(stderr,
                "dawnshell-codec: Annex-B AUD count=%zu expected=%" PRIu32 "\n",
                boundary_count, expected_frames);
        free(vector);
        return 1;
    }
    if (boundaries[0] != 0) boundaries[0] = 0;
    boundaries[boundary_count] = vector_length;

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

static int queue_encoder_frame(int descriptor, uint64_t session_id,
                               uint32_t color_format, uint32_t width,
                               uint32_t height, uint32_t frame_rate,
                               uint32_t frame_index, uint8_t *i420,
                               uint8_t *converted) {
    size_t y_size = (size_t)width * height;
    size_t chroma_size = y_size / 4;
    fill_i420_pattern(i420, width, height, frame_index);
    const uint8_t *input = i420;
    if (color_format == DSCB_COLOR_YUV420_SEMIPLANAR) {
        memcpy(converted, i420, y_size);
        for (size_t index = 0; index < chroma_size; index++) {
            converted[y_size + index * 2] = i420[y_size + index];
            converted[y_size + index * 2 + 1] =
                    i420[y_size + chroma_size + index];
        }
        input = converted;
    } else if (color_format != DSCB_COLOR_YUV420_PLANAR
            && color_format != DSCB_COLOR_YUV420_FLEXIBLE) {
        fprintf(stderr, "dawnshell-codec: unsupported encoder color format=%" PRIu32
                "\n", color_format);
        return 1;
    }
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

static int run_encode_test(int descriptor, uint32_t width, uint32_t height,
                           uint32_t frame_rate, uint32_t frames,
                           uint32_t bitrate) {
    uint64_t session_id = 0;
    uint32_t color_format = 0;
    if (create_session(descriptor, DSCB_MODE_ENCODE, DSCB_CODEC_AVC, width,
                       height, frame_rate, bitrate, &session_id,
                       &color_format) != 0) return 1;
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
            .saw_eos = 0
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
            || elapsed_us > media_duration_us)) {
        fprintf(stderr,
                "dawnshell-codec: encode-test incomplete format=%d eos=%d"
                " frames=%" PRIu32 "/%" PRIu32 " bytes=%" PRIu64
                " elapsed-us=%" PRIu64 " media-us=%" PRIu64 "\n",
                state.format_seen, state.saw_eos, state.frame_count, frames,
                state.output_bytes, elapsed_us, media_duration_us);
        result = 1;
    }
    if (result == 0) {
        fprintf(stderr,
                "dawnshell-codec: encode-test passed frames=%" PRIu32
                " pts=exact bytes=%" PRIu64 " elapsed-us=%" PRIu64 "\n",
                state.frame_count, state.output_bytes, elapsed_us);
    }
    close_session(descriptor, session_id);
    return result;
}

static int run_probe(int descriptor, uint32_t mode, uint32_t codec,
                     uint32_t width, uint32_t height) {
    uint64_t session_id = 0;
    if (create_session(descriptor, mode, codec, width, height, 30, 2000000,
                       &session_id, NULL) != 0) return 1;
    int result = simple_request(descriptor, DSCB_FLUSH, session_id, NULL, 0,
                                "flush");
    if (result == 0) {
        printf("hardware_session=%" PRIu64 " protocol=%u\n",
               session_id, DSCB_VERSION);
    }
    close_session(descriptor, session_id);
    return result;
}

static int run_pipe(int descriptor, uint32_t mode, uint32_t codec,
                    uint32_t width, uint32_t height, uint32_t frame_rate,
                    uint32_t bitrate) {
    uint64_t session_id = 0;
    if (create_session(descriptor, mode, codec, width, height, frame_rate, bitrate,
                       &session_id, NULL) != 0) return 1;
    int result = 0;
    uint64_t last_pts = 0;
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
        if (queue_input(descriptor, session_id, header, data, length) != 0) {
            free(data);
            result = 1;
            break;
        }
        free(data);
        for (;;) {
            int saw_eos = 0;
            int drained = drain_output(descriptor, session_id, 0, &saw_eos);
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
    int saw_eos = 0;
    for (int idle = 0; result == 0 && !saw_eos && idle < 50;) {
        int drained = drain_output(descriptor, session_id, 100, &saw_eos);
        if (drained == 1) idle++;
        else if (drained < 0 || drained > 2) result = 1;
    }
    if (result == 0 && !saw_eos) {
        fprintf(stderr, "dawnshell-codec: timed out waiting for output EOS\n");
        result = 1;
    }
    close_session(descriptor, session_id);
    return result;
}

static void usage(FILE *stream) {
    fprintf(stream,
            "usage:\n"
            "  dawnshell-codec inspect-vector FILE FRAMES\n"
            "  dawnshell-codec capabilities\n"
            "  dawnshell-codec probe MODE CODEC [WIDTH HEIGHT]\n"
            "  dawnshell-codec decode-test FILE WIDTH HEIGHT FPS FRAMES\n"
            "  dawnshell-codec encode-test WIDTH HEIGHT FPS FRAMES BITRATE\n"
            "  dawnshell-codec pipe MODE CODEC WIDTH HEIGHT FPS BITRATE\n\n"
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
