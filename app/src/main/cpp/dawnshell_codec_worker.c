#define _GNU_SOURCE

#include "dawnshell_codec_ndk.h"
#include "dawnshell_codec_transport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DSCB_MAGIC 0x44534342u
#define DSCB_VERSION 1u
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
#define DSCB_MAX_SESSIONS 2u
#define DSCB_BUFFER_FLAG_CODEC_CONFIG 2u

struct worker_session {
    uint64_t id;
    struct dscw_codec_session *codec;
};

struct worker_state {
    struct worker_session sessions[DSCB_MAX_SESSIONS];
    uint64_t next_session_id;
    uint64_t started_ns;
    uint64_t requests;
    uint64_t errors;
};

struct dispatch_result {
    int32_t status;
    uint64_t session_id;
    size_t payload_length;
};

static volatile sig_atomic_t stop_requested;

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

static uint64_t monotonic_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000u + (uint64_t)value.tv_nsec;
}

static void signal_handler(int signal_number) {
    (void)signal_number;
    stop_requested = 1;
}

static size_t copy_text(uint8_t *output, size_t capacity, const char *text) {
    size_t length = strlen(text);
    if (length > capacity) length = capacity;
    if (length > 0) memcpy(output, text, length);
    return length;
}

static struct dispatch_result failure(int32_t status, uint64_t session_id,
                                      uint8_t *output, size_t capacity,
                                      const char *message) {
    struct dispatch_result result = {status, session_id,
            copy_text(output, capacity, message)};
    return result;
}

static struct worker_session *find_session(struct worker_state *state,
                                           uint64_t id) {
    for (size_t index = 0; index < DSCB_MAX_SESSIONS; index++) {
        if (state->sessions[index].id == id) return &state->sessions[index];
    }
    return NULL;
}

static struct worker_session *reserve_session(struct worker_state *state) {
    for (size_t index = 0; index < DSCB_MAX_SESSIONS; index++) {
        if (state->sessions[index].id == 0) return &state->sessions[index];
    }
    return NULL;
}

static void close_session(struct worker_session *session) {
    if (session == NULL || session->id == 0) return;
    dscw_codec_destroy(session->codec);
    memset(session, 0, sizeof(*session));
}

static struct dispatch_result dispatch_create(
        struct worker_state *state, const uint8_t *payload, size_t length,
        uint8_t *output, size_t capacity) {
    if (length != 28) {
        return failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                       "invalid create request");
    }
    struct worker_session *slot = reserve_session(state);
    if (slot == NULL) {
        return failure(DSCW_CODEC_ERROR_LIMIT, 0, output, capacity,
                       "worker codec session limit reached");
    }
    char description[512];
    char error[256];
    struct dscw_codec_session *codec = NULL;
    int status = dscw_codec_create(get_u32(payload), get_u32(payload + 4),
            get_u32(payload + 8), get_u32(payload + 12),
            get_u32(payload + 16), get_u32(payload + 20),
            get_u32(payload + 24), &codec, description, sizeof(description),
            error, sizeof(error));
    if (status != DSCW_CODEC_OK) {
        return failure(status, 0, output, capacity, error);
    }
    slot->id = ++state->next_session_id;
    if (slot->id == 0) slot->id = ++state->next_session_id;
    slot->codec = codec;
    struct dispatch_result result = {DSCW_CODEC_OK, slot->id,
            copy_text(output, capacity, description)};
    return result;
}

static struct dispatch_result dispatch_create_transcoder(
        struct worker_state *state, const uint8_t *payload, size_t length,
        uint8_t *output, size_t capacity) {
    if (length != 24) {
        return failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                       "invalid create transcoder request");
    }
    struct worker_session *slot = reserve_session(state);
    if (slot == NULL) {
        return failure(DSCW_CODEC_ERROR_LIMIT, 0, output, capacity,
                       "worker codec session limit reached");
    }
    char description[512];
    char error[256];
    struct dscw_codec_session *codec = NULL;
    int status = dscw_codec_create_transcoder(get_u32(payload),
            get_u32(payload + 4), get_u32(payload + 8),
            get_u32(payload + 12), get_u32(payload + 16),
            get_u32(payload + 20), &codec, description, sizeof(description),
            error, sizeof(error));
    if (status != DSCW_CODEC_OK) {
        return failure(status, 0, output, capacity, error);
    }
    slot->id = ++state->next_session_id;
    if (slot->id == 0) slot->id = ++state->next_session_id;
    slot->codec = codec;
    struct dispatch_result result = {DSCW_CODEC_OK, slot->id,
            copy_text(output, capacity, description)};
    return result;
}

static struct dispatch_result dispatch_session(
        struct worker_state *state, uint16_t type, uint64_t session_id,
        const uint8_t *payload, size_t length, uint8_t *output,
        size_t capacity) {
    struct worker_session *slot = find_session(state, session_id);
    if (slot == NULL || session_id == 0) {
        return failure(DSCW_CODEC_ERROR_SESSION, session_id, output, capacity,
                       "unknown codec session");
    }
    char error[256] = "codec operation failed";
    int status;
    size_t output_length = 0;
    switch (type) {
        case DSCB_INPUT:
            if (length < 16 || get_u32(payload + 12) != length - 16) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "input payload length mismatch");
            }
            if ((get_u32(payload + 8) & ~DSCB_BUFFER_FLAG_CODEC_CONFIG) != 0) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "unsupported input flags");
            }
            status = dscw_codec_queue(slot->codec, payload + 16, length - 16,
                    get_u64(payload), get_u32(payload + 8), error,
                    sizeof(error));
            break;
        case DSCB_OUTPUT:
            if (length != 4 || get_u32(payload) > 1000) {
                return failure(DSCW_CODEC_ERROR_LIMIT, session_id, output,
                               capacity, "output timeout must be 0..1000ms");
            }
            status = dscw_codec_dequeue(slot->codec, get_u32(payload), output,
                    capacity, &output_length, error, sizeof(error));
            if (status >= DSCW_CODEC_OK) {
                struct dispatch_result result = {status, session_id,
                                                  output_length};
                return result;
            }
            break;
        case DSCB_EOS:
            if (length != 8) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "EOS request must contain pts_us");
            }
            status = dscw_codec_queue_eos(slot->codec, get_u64(payload), error,
                                          sizeof(error));
            break;
        case DSCB_FLUSH:
            if (length != 0) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "flush payload must be empty");
            }
            status = dscw_codec_flush(slot->codec, error, sizeof(error));
            break;
        case DSCB_REQUEST_KEYFRAME:
            if (length != 0) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "keyframe payload must be empty");
            }
            status = dscw_codec_request_keyframe(slot->codec, error,
                                                 sizeof(error));
            break;
        case DSCB_SESSION_STATS:
            if (length != 0) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "statistics payload must be empty");
            }
            status = dscw_codec_statistics(slot->codec, session_id,
                    (char *)output, capacity);
            if (status < 0) {
                return failure(DSCW_CODEC_ERROR_IO, session_id, output,
                               capacity, "could not serialize statistics");
            }
            {
                struct dispatch_result result = {DSCW_CODEC_OK, session_id,
                                                  (size_t)status};
                return result;
            }
        case DSCB_CLOSE:
            if (length != 0) {
                return failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                               capacity, "close payload must be empty");
            }
            close_session(slot);
            status = DSCW_CODEC_OK;
            break;
        default:
            return failure(DSCW_CODEC_ERROR_UNSUPPORTED, session_id, output,
                           capacity, "unsupported session operation");
    }
    if (status < DSCW_CODEC_OK) {
        return failure(status, session_id, output, capacity, error);
    }
    struct dispatch_result result = {status, session_id, 0};
    return result;
}

static struct dispatch_result dispatch_request(
        struct worker_state *state, const uint8_t *request,
        size_t request_length, uint8_t *output, size_t capacity,
        uint16_t *response_type, uint32_t *response_id) {
    state->requests++;
    if (request_length < DSCW_PROTOCOL_HEADER_BYTES) {
        state->errors++;
        return failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                       "truncated protocol header");
    }
    uint32_t magic = get_u32(request);
    uint16_t version = get_u16(request + 4);
    uint16_t type = get_u16(request + 6);
    uint32_t flags = get_u32(request + 8);
    uint64_t session_id = get_u64(request + 12);
    uint32_t payload_length = get_u32(request + 20);
    uint32_t request_id = get_u32(request + 24);
    uint32_t reserved = get_u32(request + 28);
    *response_type = type;
    *response_id = request_id;
    if (magic != DSCB_MAGIC || version != DSCB_VERSION
            || (type & DSCB_RESPONSE_BIT) != 0 || flags != 0 || reserved != 0
            || request_id == 0 || payload_length > DSCW_MAX_PAYLOAD
            || request_length != DSCW_PROTOCOL_HEADER_BYTES + payload_length) {
        state->errors++;
        return failure(version != DSCB_VERSION ? -2 : DSCW_CODEC_ERROR_PROTOCOL,
                       session_id, output, capacity,
                       "invalid codec protocol request");
    }
    const uint8_t *payload = request + DSCW_PROTOCOL_HEADER_BYTES;
    struct dispatch_result result;
    switch (type) {
        case DSCB_HELLO:
            if (payload_length != 0) {
                result = failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                                 "hello payload must be empty");
            } else {
                const char *hello = "{\"protocol\":1,\"transport\":\"inherited_memfd_eventfd\",\"worker\":\"ndk_mediacodec\",\"public_listener\":false,\"descriptor_transfer\":false,\"max_sessions\":2}";
                result = (struct dispatch_result){DSCW_CODEC_OK, 0,
                        copy_text(output, capacity, hello)};
            }
            break;
        case DSCB_CAPABILITIES:
            if (payload_length != 0) {
                result = failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                                 "capabilities payload must be empty");
            } else {
                result = (struct dispatch_result){DSCW_CODEC_OK, 0,
                        copy_text(output, capacity,
                                  dscw_codec_worker_capabilities())};
            }
            break;
        case DSCB_HEALTH:
            if (payload_length != 0 || session_id != 0) {
                result = failure(DSCW_CODEC_ERROR_PROTOCOL, 0, output, capacity,
                                 "health request must be empty and use session 0");
            } else {
                char health[512];
                unsigned active = 0;
                for (size_t index = 0; index < DSCB_MAX_SESSIONS; index++) {
                    if (state->sessions[index].id != 0) active++;
                }
                int count = snprintf(health, sizeof(health),
                        "{\"protocol\":1,\"worker_state\":\"ready\",\"transport\":\"inherited_memfd_eventfd\",\"pid\":%ld,\"uptime_ms\":%" PRIu64 ",\"active_sessions\":%u,\"requests\":%" PRIu64 ",\"request_errors\":%" PRIu64 ",\"public_listener\":false,\"software_fallback\":false}",
                        (long)getpid(), (monotonic_ns() - state->started_ns) /
                        1000000u, active, state->requests, state->errors);
                if (count < 0 || (size_t)count >= sizeof(health)) {
                    result = failure(DSCW_CODEC_ERROR_IO, 0, output, capacity,
                                     "health serialization failed");
                } else {
                    result = (struct dispatch_result){DSCW_CODEC_OK, 0,
                            copy_text(output, capacity, health)};
                }
            }
            break;
        case DSCB_CREATE:
            if (session_id != 0) {
                result = failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                                 capacity, "create must use session 0");
            } else {
                result = dispatch_create(state, payload, payload_length,
                                         output, capacity);
            }
            break;
        case DSCB_CREATE_TRANSCODER:
            if (session_id != 0) {
                result = failure(DSCW_CODEC_ERROR_PROTOCOL, session_id, output,
                                 capacity, "create transcoder must use session 0");
            } else {
                result = dispatch_create_transcoder(state, payload,
                        payload_length, output, capacity);
            }
            break;
        case DSCB_INPUT_SHARED_MEMORY:
        case DSCB_OUTPUT_SHARED_MEMORY:
            result = failure(DSCW_CODEC_ERROR_UNSUPPORTED, session_id, output,
                    capacity, "legacy descriptor transfer is unsupported; use the inherited shared slot");
            break;
        default:
            result = dispatch_session(state, type, session_id, payload,
                                      payload_length, output, capacity);
            break;
    }
    if (result.status < DSCW_CODEC_OK) state->errors++;
    return result;
}

static void write_response_header(uint8_t *response, uint16_t type,
                                  uint64_t session_id, uint32_t payload_length,
                                  uint32_t request_id, int32_t status) {
    memset(response, 0, DSCW_PROTOCOL_HEADER_BYTES);
    put_u32(response, DSCB_MAGIC);
    put_u16(response + 4, DSCB_VERSION);
    put_u16(response + 6, (uint16_t)(type | DSCB_RESPONSE_BIT));
    put_u64(response + 12, session_id);
    put_u32(response + 20, payload_length);
    put_u32(response + 24, request_id);
    put_u32(response + 28, (uint32_t)status);
}

static int eventfd_read_one(int descriptor) {
    uint64_t value;
    ssize_t count;
    do {
        count = read(descriptor, &value, sizeof(value));
    } while (count < 0 && errno == EINTR && !stop_requested);
    return count == (ssize_t)sizeof(value) ? 0 : -1;
}

static int eventfd_write_one(int descriptor) {
    const uint64_t value = 1;
    ssize_t count;
    do {
        count = write(descriptor, &value, sizeof(value));
    } while (count < 0 && errno == EINTR && !stop_requested);
    return count == (ssize_t)sizeof(value) ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--inherited-transport") != 0) {
        fprintf(stderr, "dawnshell-codec-worker: private worker; use dawnshell-codec\n");
        return 2;
    }
    if (signal(SIGTERM, signal_handler) == SIG_ERR
            || signal(SIGINT, signal_handler) == SIG_ERR
            || signal(SIGHUP, signal_handler) == SIG_ERR
            || signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        return 3;
    }
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) return 3;
    void *mapping = mmap(NULL, DSCW_MAPPING_BYTES, PROT_READ | PROT_WRITE,
                         MAP_SHARED, DSCW_WORKER_MEMFD, 0);
    if (mapping == MAP_FAILED) return 4;
    struct dscw_transport_control *control = mapping;
    if (control->magic != DSCW_TRANSPORT_MAGIC
            || control->version != DSCW_TRANSPORT_VERSION
            || control->mapping_bytes != DSCW_MAPPING_BYTES
            || control->slot_bytes != DSCW_SLOT_BYTES
            || control->parent_pid == 0
            || (pid_t)control->parent_pid != getppid()) {
        munmap(mapping, DSCW_MAPPING_BYTES);
        return 5;
    }
    control->worker_pid = (uint32_t)getpid();
    __atomic_fetch_or(&control->flags, DSCW_FLAG_WORKER_READY, __ATOMIC_RELEASE);
    if (eventfd_write_one(DSCW_WORKER_RESPONSE_EVENTFD) != 0) {
        munmap(mapping, DSCW_MAPPING_BYTES);
        return 6;
    }
    struct worker_state state;
    memset(&state, 0, sizeof(state));
    state.next_session_id = monotonic_ns();
    state.started_ns = monotonic_ns();
    while (!stop_requested) {
        struct pollfd wait = {.fd = DSCW_WORKER_REQUEST_EVENTFD, .events = POLLIN};
        int polled;
        do {
            polled = poll(&wait, 1, 1000);
        } while (polled < 0 && errno == EINTR && !stop_requested);
        if (stop_requested) break;
        if (polled == 0) {
            if (kill((pid_t)control->parent_pid, 0) != 0 && errno == ESRCH) break;
            continue;
        }
        if (polled < 0 || eventfd_read_one(DSCW_WORKER_REQUEST_EVENTFD) != 0) break;
        uint32_t flags = __atomic_load_n(&control->flags, __ATOMIC_ACQUIRE);
        if ((flags & DSCW_FLAG_SHUTDOWN) != 0) break;
        uint32_t sequence = __atomic_load_n(&control->request_sequence,
                                            __ATOMIC_ACQUIRE);
        uint32_t request_bytes = __atomic_load_n(&control->request_bytes,
                                                 __ATOMIC_ACQUIRE);
        uint8_t *request = dscw_request_slot(mapping);
        uint8_t *response = dscw_response_slot(mapping);
        uint16_t response_type = request_bytes >= 8 ? get_u16(request + 6) : 0;
        uint32_t response_id = request_bytes >= 28 ? get_u32(request + 24) : 0;
        struct dispatch_result result;
        if (request_bytes > DSCW_SLOT_BYTES) {
            result = failure(DSCW_CODEC_ERROR_LIMIT, 0,
                    response + DSCW_PROTOCOL_HEADER_BYTES, DSCW_MAX_PAYLOAD,
                    "transport request exceeds shared slot");
        } else {
            result = dispatch_request(&state, request, request_bytes,
                    response + DSCW_PROTOCOL_HEADER_BYTES, DSCW_MAX_PAYLOAD,
                    &response_type, &response_id);
        }
        write_response_header(response, response_type, result.session_id,
                (uint32_t)result.payload_length, response_id, result.status);
        __atomic_store_n(&control->response_bytes,
                (uint32_t)(DSCW_PROTOCOL_HEADER_BYTES + result.payload_length),
                __ATOMIC_RELEASE);
        __atomic_store_n(&control->response_sequence, sequence, __ATOMIC_RELEASE);
        if (eventfd_write_one(DSCW_WORKER_RESPONSE_EVENTFD) != 0) break;
    }
    for (size_t index = 0; index < DSCB_MAX_SESSIONS; index++) {
        close_session(&state.sessions[index]);
    }
    munmap(mapping, DSCW_MAPPING_BYTES);
    return 0;
}
