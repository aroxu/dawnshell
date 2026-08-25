#ifndef DAWNSHELL_CODEC_NDK_H
#define DAWNSHELL_CODEC_NDK_H

#include <stddef.h>
#include <stdint.h>

#define DSCW_CODEC_OK 0
#define DSCW_CODEC_AGAIN 1
#define DSCW_CODEC_FORMAT_CHANGED 2
#define DSCW_CODEC_ERROR_PROTOCOL (-1)
#define DSCW_CODEC_ERROR_UNSUPPORTED (-4)
#define DSCW_CODEC_ERROR_LIMIT (-5)
#define DSCW_CODEC_ERROR_CODEC (-6)
#define DSCW_CODEC_ERROR_SESSION (-7)
#define DSCW_CODEC_ERROR_IO (-8)

#define DSCW_MODE_DECODE 1u
#define DSCW_MODE_ENCODE 2u
#define DSCW_CODEC_AVC 1u
#define DSCW_CODEC_HEVC 2u

struct dscw_codec_session;

int dscw_codec_create(uint32_t mode, uint32_t codec, uint32_t width,
                      uint32_t height, uint32_t frame_rate, uint32_t bitrate,
                      uint32_t requested_color_format,
                      struct dscw_codec_session **session,
                      char *description, size_t description_size,
                      char *error, size_t error_size);

int dscw_codec_create_transcoder(uint32_t input_codec, uint32_t output_codec,
                                 uint32_t width, uint32_t height,
                                 uint32_t frame_rate, uint32_t bitrate,
                                 struct dscw_codec_session **session,
                                 char *description, size_t description_size,
                                 char *error, size_t error_size);

int dscw_codec_queue(struct dscw_codec_session *session, const uint8_t *data,
                     size_t length, uint64_t presentation_time_us,
                     uint32_t flags, char *error, size_t error_size);
int dscw_codec_queue_eos(struct dscw_codec_session *session,
                         uint64_t presentation_time_us,
                         char *error, size_t error_size);
int dscw_codec_dequeue(struct dscw_codec_session *session, uint32_t timeout_ms,
                       uint8_t *output, size_t output_capacity,
                       size_t *output_length, char *error, size_t error_size);
int dscw_codec_flush(struct dscw_codec_session *session,
                     char *error, size_t error_size);
int dscw_codec_request_keyframe(struct dscw_codec_session *session,
                                char *error, size_t error_size);
int dscw_codec_statistics(struct dscw_codec_session *session, uint64_t session_id,
                          char *output, size_t output_size);
void dscw_codec_destroy(struct dscw_codec_session *session);

const char *dscw_codec_worker_capabilities(void);

#endif
