#ifndef DAWNSHELL_CODEC_TRANSPORT_H
#define DAWNSHELL_CODEC_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

/*
 * Private transport inherited by one NDK worker from one Debian client.
 *
 * There is deliberately no pathname, listening socket, Binder registration,
 * or descriptor transfer.  The parent creates this memfd and two eventfds,
 * maps the memfd, and then execs the worker with fixed inherited descriptors.
 * One request is outstanding at a time, which matches the synchronous codec
 * protocol and provides bounded backpressure without another queue.
 */
#define DSCW_TRANSPORT_MAGIC 0x44534357u /* "DSCW" */
#define DSCW_TRANSPORT_VERSION 1u
#define DSCW_CONTROL_BYTES 4096u
#define DSCW_PROTOCOL_HEADER_BYTES 32u
#define DSCW_MAX_PAYLOAD (8u * 1024u * 1024u)
#define DSCW_SLOT_BYTES (DSCW_PROTOCOL_HEADER_BYTES + DSCW_MAX_PAYLOAD)
#define DSCW_REQUEST_OFFSET DSCW_CONTROL_BYTES
#define DSCW_RESPONSE_OFFSET (DSCW_REQUEST_OFFSET + DSCW_SLOT_BYTES)
#define DSCW_MAPPING_BYTES (DSCW_RESPONSE_OFFSET + DSCW_SLOT_BYTES)

#define DSCW_WORKER_MEMFD 3
#define DSCW_WORKER_REQUEST_EVENTFD 4
#define DSCW_WORKER_RESPONSE_EVENTFD 5

#define DSCW_FLAG_SHUTDOWN 0x00000001u
#define DSCW_FLAG_WORKER_READY 0x00000002u
#define DSCW_FLAG_WORKER_FAILED 0x00000004u

struct dscw_transport_control {
    uint32_t magic;
    uint32_t version;
    uint32_t mapping_bytes;
    uint32_t slot_bytes;
    uint32_t parent_pid;
    uint32_t worker_pid;
    uint32_t flags;
    int32_t worker_error;
    uint32_t request_sequence;
    uint32_t request_bytes;
    uint32_t response_sequence;
    uint32_t response_bytes;
    uint64_t started_monotonic_ns;
    uint8_t reserved[DSCW_CONTROL_BYTES - 56u];
};

_Static_assert(sizeof(struct dscw_transport_control) == DSCW_CONTROL_BYTES,
               "codec transport control page must remain exactly one page");

static inline uint8_t *dscw_request_slot(void *mapping) {
    return (uint8_t *)mapping + DSCW_REQUEST_OFFSET;
}

static inline uint8_t *dscw_response_slot(void *mapping) {
    return (uint8_t *)mapping + DSCW_RESPONSE_OFFSET;
}

#endif
