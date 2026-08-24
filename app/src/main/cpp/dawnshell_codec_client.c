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
                          uint32_t bitrate, uint64_t *session_id) {
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
        fprintf(stderr, "dawnshell-codec: output-format=%.*s\n",
                (int)response.payload_length,
                response.payload == NULL ? (uint8_t *)"" : response.payload);
        result = 2;
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

static int run_probe(int descriptor, uint32_t mode, uint32_t codec,
                     uint32_t width, uint32_t height) {
    uint64_t session_id = 0;
    if (create_session(descriptor, mode, codec, width, height, 30, 2000000,
                       &session_id) != 0) return 1;
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
                       &session_id) != 0) return 1;
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
        uint8_t eos[8];
        put_u64(eos, last_pts);
        for (;;) {
            struct response response;
            if (rpc(descriptor, DSCB_EOS, session_id, eos, sizeof(eos),
                    &response) != 0) {
                result = 1;
                break;
            }
            if (response.status == DSCB_AGAIN) {
                free_response(&response);
                usleep(2000);
                continue;
            }
            if (response.status != DSCB_OK) result = report_error("eos", &response);
            free_response(&response);
            break;
        }
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
            "  dawnshell-codec capabilities\n"
            "  dawnshell-codec probe MODE CODEC [WIDTH HEIGHT]\n"
            "  dawnshell-codec pipe MODE CODEC WIDTH HEIGHT FPS BITRATE\n\n"
            "MODE is decode or encode; CODEC is avc/h264 or hevc/h265.\n"
            "pipe stdin/stdout records are: pts_us:u64, flags:u32, length:u32, data; big-endian.\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(stderr);
        return 2;
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
    } else {
        usage(stderr);
    }
    close(descriptor);
    return result < 0 ? 3 : result;
}
