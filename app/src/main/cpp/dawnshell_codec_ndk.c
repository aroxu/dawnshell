#define _GNU_SOURCE

#include "dawnshell_codec_ndk.h"
#include "dawnshell_codec_transport.h"

#include <android/native_window.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaError.h>
#include <media/NdkMediaFormat.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define COLOR_YUV420_PLANAR 19u
#define COLOR_YUV420_SEMIPLANAR 21u
#define COLOR_YUV420_FLEXIBLE 0x7f420888u
#define COLOR_SURFACE 0x7f000789u
#define BUFFER_FLAG_KEY_FRAME 1u
#define BUFFER_FLAG_CODEC_CONFIG 2u
#define BUFFER_FLAG_END_OF_STREAM 4u
#define PIXEL_FORMAT_BITSTREAM 0u
#define PIXEL_FORMAT_I420 1u
#define MAX_CANDIDATES 24u
#define MAX_CODEC_NAME 128u

typedef media_status_t (*get_codec_name_fn)(AMediaCodec *, char **);
typedef void (*release_codec_name_fn)(AMediaCodec *, char *);
typedef media_status_t (*find_codec_fn)(const AMediaFormat *, const void **);
typedef const char *(*codec_info_name_fn)(const void *);
typedef int32_t (*codec_info_type_fn)(const void *);
typedef media_status_t (*create_input_surface_fn)(AMediaCodec *, ANativeWindow **);
typedef media_status_t (*signal_input_eos_fn)(AMediaCodec *);
typedef media_status_t (*set_parameters_fn)(AMediaCodec *, const AMediaFormat *);

struct latency_counters {
    uint64_t samples;
    uint64_t total_us;
    uint64_t max_us;
};

struct dscw_codec_session {
    bool transcoder;
    bool encoder;
    bool input_eos;
    bool encoder_eos_signaled;
    bool pending_image;
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate;
    uint32_t color_format;
    uint64_t started_ns;
    uint64_t pending_image_pts;
    uint32_t pending_image_flags;
    uint64_t last_encoder_pts;
    bool have_encoder_pts;
    char codec_name[MAX_CODEC_NAME];
    char decoder_name[MAX_CODEC_NAME];
    char encoder_name[MAX_CODEC_NAME];
    AMediaCodec *codec;
    AImageReader *image_reader;
    AMediaCodec *decoder;
    AMediaCodec *transcode_encoder;
    ANativeWindow *encoder_input_surface;
    uint64_t input_records;
    uint64_t input_frames;
    uint64_t input_bytes;
    uint64_t input_eos_count;
    uint64_t output_records;
    uint64_t output_frames;
    uint64_t output_bytes;
    uint64_t output_eos_count;
    uint64_t cpu_yuv_frames;
    uint64_t surface_frames;
    uint64_t input_again;
    uint64_t output_again;
    uint64_t errors;
    uint64_t format_changes;
    struct latency_counters input_latency;
    struct latency_counters output_latency;
};

struct codec_candidate {
    char name[MAX_CODEC_NAME];
    bool hardware_proven;
};

struct optional_api {
    void *library;
    get_codec_name_fn get_name;
    release_codec_name_fn release_name;
    find_codec_fn find_decoder;
    find_codec_fn find_encoder;
    codec_info_name_fn info_name;
    codec_info_type_fn info_type;
    create_input_surface_fn create_input_surface;
    signal_input_eos_fn signal_input_eos;
    set_parameters_fn set_parameters;
};

static struct optional_api optional_api;
static bool optional_api_loaded;

static uint64_t monotonic_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000u + (uint64_t)value.tv_nsec;
}

static uint64_t process_cpu_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000u + (uint64_t)value.tv_nsec / 1000000u;
}

static void record_latency(struct latency_counters *counters, uint64_t started) {
    uint64_t elapsed = (monotonic_ns() - started) / 1000u;
    counters->samples++;
    counters->total_us += elapsed;
    if (elapsed > counters->max_us) counters->max_us = elapsed;
}

static void set_error(char *output, size_t size, const char *format, ...)
        __attribute__((format(printf, 3, 4)));

static void set_error(char *output, size_t size, const char *format, ...) {
    if (output == NULL || size == 0) return;
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(output, size, format, arguments);
    va_end(arguments);
    if (count < 0) output[0] = '\0';
    output[size - 1] = '\0';
}

static void load_optional_api(void) {
    if (optional_api_loaded) return;
    optional_api_loaded = true;
    optional_api.library = dlopen("libmediandk.so", RTLD_NOW | RTLD_LOCAL);
    if (optional_api.library == NULL) return;
    optional_api.get_name = (get_codec_name_fn)dlsym(
            optional_api.library, "AMediaCodec_getName");
    optional_api.release_name = (release_codec_name_fn)dlsym(
            optional_api.library, "AMediaCodec_releaseName");
    optional_api.find_decoder = (find_codec_fn)dlsym(
            optional_api.library, "AMediaCodecStore_findNextDecoderForFormat");
    optional_api.find_encoder = (find_codec_fn)dlsym(
            optional_api.library, "AMediaCodecStore_findNextEncoderForFormat");
    optional_api.info_name = (codec_info_name_fn)dlsym(
            optional_api.library, "AMediaCodecInfo_getCanonicalName");
    optional_api.info_type = (codec_info_type_fn)dlsym(
            optional_api.library, "AMediaCodecInfo_getMediaCodecInfoType");
    optional_api.create_input_surface = (create_input_surface_fn)dlsym(
            optional_api.library, "AMediaCodec_createInputSurface");
    optional_api.signal_input_eos = (signal_input_eos_fn)dlsym(
            optional_api.library, "AMediaCodec_signalEndOfInputStream");
    optional_api.set_parameters = (set_parameters_fn)dlsym(
            optional_api.library, "AMediaCodec_setParameters");
}

static bool starts_with(const char *value, const char *prefix) {
    return strncmp(value, prefix, strlen(prefix)) == 0;
}

static bool hardware_name(const char *name) {
    if (name == NULL) return false;
    char lower[MAX_CODEC_NAME];
    size_t length = strlen(name);
    if (length >= sizeof(lower)) length = sizeof(lower) - 1;
    for (size_t index = 0; index < length; index++) {
        char value = name[index];
        lower[index] = value >= 'A' && value <= 'Z'
                ? (char)(value - 'A' + 'a') : value;
    }
    lower[length] = '\0';
    return starts_with(lower, "omx.exynos.")
            || starts_with(lower, "omx.sec.")
            || starts_with(lower, "c2.exynos.")
            || starts_with(lower, "omx.qcom.")
            || starts_with(lower, "c2.qti.")
            || starts_with(lower, "omx.intel.")
            || starts_with(lower, "omx.nvidia.")
            || starts_with(lower, "omx.rk.")
            || starts_with(lower, "omx.amlogic.")
            || starts_with(lower, "omx.allwinner.");
}

static bool duplicate_candidate(const struct codec_candidate *candidates,
                                size_t count, const char *name) {
    for (size_t index = 0; index < count; index++) {
        if (strcmp(candidates[index].name, name) == 0) return true;
    }
    return false;
}

static void add_candidate(struct codec_candidate *candidates, size_t *count,
                          const char *name, bool hardware_proven) {
    if (*count >= MAX_CANDIDATES || name == NULL
            || strlen(name) >= MAX_CODEC_NAME
            || duplicate_candidate(candidates, *count, name)) return;
    snprintf(candidates[*count].name, MAX_CODEC_NAME, "%s", name);
    candidates[*count].hardware_proven = hardware_proven;
    (*count)++;
}

static const char *mime_for_codec(uint32_t codec) {
    if (codec == DSCW_CODEC_AVC) return "video/avc";
    if (codec == DSCW_CODEC_HEVC) return "video/hevc";
    return NULL;
}

static void add_legacy_candidates(struct codec_candidate *candidates,
                                  size_t *count, uint32_t codec,
                                  bool encoder) {
    if (codec == DSCW_CODEC_AVC && encoder) {
        add_candidate(candidates, count, "OMX.Exynos.AVC.Encoder", true);
        add_candidate(candidates, count, "c2.exynos.h264.encoder", true);
        add_candidate(candidates, count, "c2.qti.avc.encoder", true);
        add_candidate(candidates, count, "OMX.qcom.video.encoder.avc", true);
    } else if (codec == DSCW_CODEC_AVC) {
        add_candidate(candidates, count, "OMX.Exynos.avc.dec", true);
        add_candidate(candidates, count, "OMX.Exynos.AVC.Decoder", true);
        add_candidate(candidates, count, "c2.exynos.h264.decoder", true);
        add_candidate(candidates, count, "c2.qti.avc.decoder", true);
        add_candidate(candidates, count, "OMX.qcom.video.decoder.avc", true);
    } else if (codec == DSCW_CODEC_HEVC && encoder) {
        add_candidate(candidates, count, "OMX.Exynos.HEVC.Encoder", true);
        add_candidate(candidates, count, "c2.exynos.hevc.encoder", true);
        add_candidate(candidates, count, "c2.qti.hevc.encoder", true);
        add_candidate(candidates, count, "OMX.qcom.video.encoder.hevc", true);
    } else if (codec == DSCW_CODEC_HEVC) {
        add_candidate(candidates, count, "OMX.Exynos.HEVC.Decoder", true);
        add_candidate(candidates, count, "OMX.Exynos.hevc.dec", true);
        add_candidate(candidates, count, "c2.exynos.hevc.decoder", true);
        add_candidate(candidates, count, "c2.qti.hevc.decoder", true);
        add_candidate(candidates, count, "OMX.qcom.video.decoder.hevc", true);
    }
}

static size_t collect_candidates(uint32_t codec, bool encoder,
                                 struct codec_candidate *candidates) {
    size_t count = 0;
    const char *mime = mime_for_codec(codec);
    load_optional_api();
    find_codec_fn find = encoder ? optional_api.find_encoder
                                 : optional_api.find_decoder;
    if (mime != NULL && find != NULL && optional_api.info_name != NULL
            && optional_api.info_type != NULL) {
        AMediaFormat *format = AMediaFormat_new();
        if (format != NULL) {
            AMediaFormat_setString(format, "mime", mime);
            const void *info = NULL;
            while (count < MAX_CANDIDATES && find(format, &info) == AMEDIA_OK
                    && info != NULL) {
                const char *name = optional_api.info_name(info);
                /* API 36 value 2 is HARDWARE_ACCELERATED. */
                if (optional_api.info_type(info) == 2) {
                    add_candidate(candidates, &count, name, true);
                }
            }
            AMediaFormat_delete(format);
        }
    }
    add_legacy_candidates(candidates, &count, codec, encoder);
    /* Empty name asks the platform selector. It is accepted only when the
       selected component name can subsequently prove hardware acceleration. */
    add_candidate(candidates, &count, "", false);
    return count;
}

static AMediaCodec *new_codec(const struct codec_candidate *candidate,
                              bool encoder, const char *mime,
                              char *selected_name, size_t selected_name_size) {
    AMediaCodec *codec = candidate->name[0] == '\0'
            ? (encoder ? AMediaCodec_createEncoderByType(mime)
                       : AMediaCodec_createDecoderByType(mime))
            : AMediaCodec_createCodecByName(candidate->name);
    if (codec == NULL) return NULL;
    const char *proven_name = candidate->name;
    char *runtime_name = NULL;
    load_optional_api();
    if (optional_api.get_name != NULL && optional_api.release_name != NULL
            && optional_api.get_name(codec, &runtime_name) == AMEDIA_OK
            && runtime_name != NULL) {
        proven_name = runtime_name;
    }
    bool proven = candidate->hardware_proven || hardware_name(proven_name);
    if (!proven) {
        if (runtime_name != NULL) optional_api.release_name(codec, runtime_name);
        AMediaCodec_delete(codec);
        return NULL;
    }
    snprintf(selected_name, selected_name_size, "%s",
             proven_name == NULL ? "unknown" : proven_name);
    if (runtime_name != NULL) optional_api.release_name(codec, runtime_name);
    return codec;
}

static AMediaFormat *video_format(const char *mime, uint32_t width,
                                  uint32_t height, uint32_t frame_rate) {
    AMediaFormat *format = AMediaFormat_new();
    if (format == NULL) return NULL;
    AMediaFormat_setString(format, "mime", mime);
    AMediaFormat_setInt32(format, "width", (int32_t)width);
    AMediaFormat_setInt32(format, "height", (int32_t)height);
    AMediaFormat_setInt32(format, "frame-rate", (int32_t)frame_rate);
    return format;
}

static bool valid_parameters(uint32_t width, uint32_t height,
                             uint32_t frame_rate, uint32_t bitrate) {
    uint64_t frame_bytes = (uint64_t)width * height * 3u / 2u;
    return width >= 16 && width <= 4096 && height >= 16 && height <= 4096
            && (width & 1u) == 0 && (height & 1u) == 0
            && frame_rate >= 1 && frame_rate <= 240
            && bitrate >= 1000 && bitrate <= 100000000
            && frame_bytes <= DSCW_MAX_PAYLOAD - 16u;
}

static void stop_delete_codec(AMediaCodec **codec) {
    if (codec == NULL || *codec == NULL) return;
    (void)AMediaCodec_stop(*codec);
    (void)AMediaCodec_delete(*codec);
    *codec = NULL;
}

static int create_encoder(uint32_t codec_id, uint32_t width, uint32_t height,
                          uint32_t frame_rate, uint32_t bitrate,
                          uint32_t requested_color,
                          struct dscw_codec_session *session,
                          char *error, size_t error_size) {
    const char *mime = mime_for_codec(codec_id);
    struct codec_candidate candidates[MAX_CANDIDATES];
    size_t candidate_count = collect_candidates(codec_id, true, candidates);
    uint32_t colors[] = {COLOR_YUV420_PLANAR, COLOR_YUV420_SEMIPLANAR,
                         COLOR_YUV420_FLEXIBLE};
    for (size_t candidate_index = 0; candidate_index < candidate_count;
            candidate_index++) {
        for (size_t color_index = 0; color_index < 3; color_index++) {
            uint32_t color = requested_color == 0 ? colors[color_index]
                                                  : requested_color;
            char selected[MAX_CODEC_NAME];
            AMediaCodec *codec = new_codec(&candidates[candidate_index], true,
                                           mime, selected, sizeof(selected));
            if (codec == NULL) {
                if (requested_color != 0) break;
                continue;
            }
            AMediaFormat *format = video_format(mime, width, height, frame_rate);
            if (format == NULL) {
                AMediaCodec_delete(codec);
                set_error(error, error_size, "could not allocate encoder format");
                return DSCW_CODEC_ERROR_CODEC;
            }
            AMediaFormat_setInt32(format, "max-input-size",
                    (int32_t)((uint64_t)width * height * 3u / 2u));
            AMediaFormat_setInt32(format, "bitrate", (int32_t)bitrate);
            AMediaFormat_setInt32(format, "i-frame-interval", 2);
            AMediaFormat_setInt32(format, "color-format", (int32_t)color);
            media_status_t configured = AMediaCodec_configure(codec, format,
                    NULL, NULL, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
            AMediaFormat_delete(format);
            if (configured == AMEDIA_OK && AMediaCodec_start(codec) == AMEDIA_OK) {
                session->codec = codec;
                session->encoder = true;
                session->color_format = color;
                snprintf(session->codec_name, sizeof(session->codec_name), "%s",
                         selected);
                return DSCW_CODEC_OK;
            }
            AMediaCodec_delete(codec);
            if (requested_color != 0) break;
        }
    }
    set_error(error, error_size,
              "no proven hardware encoder accepted a YUV420 ByteBuffer format");
    return DSCW_CODEC_ERROR_CODEC;
}

static int create_decoder(uint32_t codec_id, uint32_t width, uint32_t height,
                          uint32_t frame_rate,
                          struct dscw_codec_session *session,
                          char *error, size_t error_size) {
    const char *mime = mime_for_codec(codec_id);
    struct codec_candidate candidates[MAX_CANDIDATES];
    size_t candidate_count = collect_candidates(codec_id, false, candidates);
    for (size_t index = 0; index < candidate_count; index++) {
        AImageReader *reader = NULL;
        if (AImageReader_new((int32_t)width, (int32_t)height,
                AIMAGE_FORMAT_YUV_420_888, 4, &reader) != AMEDIA_OK
                || reader == NULL) continue;
        ANativeWindow *window = NULL;
        if (AImageReader_getWindow(reader, &window) != AMEDIA_OK
                || window == NULL) {
            AImageReader_delete(reader);
            continue;
        }
        char selected[MAX_CODEC_NAME];
        AMediaCodec *codec = new_codec(&candidates[index], false, mime,
                                       selected, sizeof(selected));
        if (codec == NULL) {
            AImageReader_delete(reader);
            continue;
        }
        AMediaFormat *format = video_format(mime, width, height, frame_rate);
        if (format == NULL) {
            AMediaCodec_delete(codec);
            AImageReader_delete(reader);
            set_error(error, error_size, "could not allocate decoder format");
            return DSCW_CODEC_ERROR_CODEC;
        }
        AMediaFormat_setInt32(format, "max-input-size",
                              (int32_t)(DSCW_MAX_PAYLOAD - 16u));
        media_status_t configured = AMediaCodec_configure(codec, format,
                                                          window, NULL, 0);
        AMediaFormat_delete(format);
        if (configured == AMEDIA_OK && AMediaCodec_start(codec) == AMEDIA_OK) {
            session->codec = codec;
            session->image_reader = reader;
            snprintf(session->codec_name, sizeof(session->codec_name), "%s",
                     selected);
            return DSCW_CODEC_OK;
        }
        AMediaCodec_delete(codec);
        AImageReader_delete(reader);
    }
    set_error(error, error_size,
              "no proven hardware decoder accepted a YUV ImageReader surface");
    return DSCW_CODEC_ERROR_CODEC;
}

int dscw_codec_create(uint32_t mode, uint32_t codec, uint32_t width,
                      uint32_t height, uint32_t frame_rate, uint32_t bitrate,
                      uint32_t requested_color_format,
                      struct dscw_codec_session **result,
                      char *description, size_t description_size,
                      char *error, size_t error_size) {
    if (result == NULL || description == NULL || mime_for_codec(codec) == NULL
            || (mode != DSCW_MODE_DECODE && mode != DSCW_MODE_ENCODE)) {
        set_error(error, error_size, "unsupported codec create parameters");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    if (!valid_parameters(width, height, frame_rate, bitrate)) {
        set_error(error, error_size, "codec parameters exceed bounded limits");
        return DSCW_CODEC_ERROR_LIMIT;
    }
    struct dscw_codec_session *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        set_error(error, error_size, "could not allocate codec session");
        return DSCW_CODEC_ERROR_IO;
    }
    session->width = width;
    session->height = height;
    session->frame_rate = frame_rate;
    session->last_encoder_pts = 0;
    session->started_ns = monotonic_ns();
    int status = mode == DSCW_MODE_ENCODE
            ? create_encoder(codec, width, height, frame_rate, bitrate,
                             requested_color_format, session, error, error_size)
            : create_decoder(codec, width, height, frame_rate, session,
                             error, error_size);
    if (status != DSCW_CODEC_OK) {
        dscw_codec_destroy(session);
        return status;
    }
    int count = snprintf(description, description_size,
            "{\"codec_name\":\"%s\",\"mime\":\"%s\",\"classification\":\"ndk_hardware_proven\",\"transport\":\"inherited_memfd_eventfd\",\"color_format\":%u}",
            session->codec_name, mime_for_codec(codec), session->color_format);
    if (count < 0 || (size_t)count >= description_size) {
        dscw_codec_destroy(session);
        set_error(error, error_size, "codec description exceeds limit");
        return DSCW_CODEC_ERROR_IO;
    }
    *result = session;
    return DSCW_CODEC_OK;
}

static int configure_surface_encoder(const struct codec_candidate *candidate,
                                     const char *mime, uint32_t width,
                                     uint32_t height, uint32_t frame_rate,
                                     uint32_t bitrate, AMediaCodec **result,
                                     ANativeWindow **surface, char *name,
                                     size_t name_size) {
    load_optional_api();
    if (optional_api.create_input_surface == NULL) return -1;
    AMediaCodec *codec = new_codec(candidate, true, mime, name, name_size);
    if (codec == NULL) return -1;
    AMediaFormat *format = video_format(mime, width, height, frame_rate);
    if (format == NULL) {
        AMediaCodec_delete(codec);
        return -1;
    }
    AMediaFormat_setInt32(format, "color-format", (int32_t)COLOR_SURFACE);
    AMediaFormat_setInt32(format, "bitrate", (int32_t)bitrate);
    AMediaFormat_setInt32(format, "i-frame-interval", 2);
    media_status_t status = AMediaCodec_configure(codec, format, NULL, NULL,
                                                  AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
    AMediaFormat_delete(format);
    if (status != AMEDIA_OK
            || optional_api.create_input_surface(codec, surface) != AMEDIA_OK
            || *surface == NULL || AMediaCodec_start(codec) != AMEDIA_OK) {
        if (*surface != NULL) {
            ANativeWindow_release(*surface);
            *surface = NULL;
        }
        AMediaCodec_delete(codec);
        return -1;
    }
    *result = codec;
    return 0;
}

int dscw_codec_create_transcoder(uint32_t input_codec, uint32_t output_codec,
                                 uint32_t width, uint32_t height,
                                 uint32_t frame_rate, uint32_t bitrate,
                                 struct dscw_codec_session **result,
                                 char *description, size_t description_size,
                                 char *error, size_t error_size) {
    const char *input_mime = mime_for_codec(input_codec);
    const char *output_mime = mime_for_codec(output_codec);
    load_optional_api();
    if (result == NULL || input_mime == NULL || output_mime == NULL) {
        set_error(error, error_size, "unsupported transcoder codec");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    if (!valid_parameters(width, height, frame_rate, bitrate)) {
        set_error(error, error_size, "transcoder parameters exceed bounded limits");
        return DSCW_CODEC_ERROR_LIMIT;
    }
    if (optional_api.create_input_surface == NULL
            || optional_api.signal_input_eos == NULL) {
        set_error(error, error_size,
                  "Surface transcoding requires Android API 26 or newer");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    struct codec_candidate encoders[MAX_CANDIDATES];
    struct codec_candidate decoders[MAX_CANDIDATES];
    size_t encoder_count = collect_candidates(output_codec, true, encoders);
    size_t decoder_count = collect_candidates(input_codec, false, decoders);
    struct dscw_codec_session *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        set_error(error, error_size, "could not allocate transcoder session");
        return DSCW_CODEC_ERROR_IO;
    }
    session->transcoder = true;
    session->encoder = true;
    session->width = width;
    session->height = height;
    session->frame_rate = frame_rate;
    session->started_ns = monotonic_ns();
    for (size_t encoder_index = 0; encoder_index < encoder_count;
            encoder_index++) {
        AMediaCodec *encoder = NULL;
        ANativeWindow *surface = NULL;
        char encoder_name[MAX_CODEC_NAME];
        if (configure_surface_encoder(&encoders[encoder_index], output_mime,
                width, height, frame_rate, bitrate, &encoder, &surface,
                encoder_name, sizeof(encoder_name)) != 0) continue;
        for (size_t decoder_index = 0; decoder_index < decoder_count;
                decoder_index++) {
            char decoder_name[MAX_CODEC_NAME];
            AMediaCodec *decoder = new_codec(&decoders[decoder_index], false,
                    input_mime, decoder_name, sizeof(decoder_name));
            if (decoder == NULL) continue;
            AMediaFormat *format = video_format(input_mime, width, height,
                                                frame_rate);
            if (format == NULL) {
                AMediaCodec_delete(decoder);
                continue;
            }
            AMediaFormat_setInt32(format, "max-input-size",
                                  (int32_t)(DSCW_MAX_PAYLOAD - 16u));
            media_status_t configured = AMediaCodec_configure(decoder, format,
                                                              surface, NULL, 0);
            AMediaFormat_delete(format);
            if (configured == AMEDIA_OK
                    && AMediaCodec_start(decoder) == AMEDIA_OK) {
                session->decoder = decoder;
                session->transcode_encoder = encoder;
                session->encoder_input_surface = surface;
                snprintf(session->decoder_name, sizeof(session->decoder_name),
                         "%s", decoder_name);
                snprintf(session->encoder_name, sizeof(session->encoder_name),
                         "%s", encoder_name);
                int count = snprintf(description, description_size,
                        "{\"transport\":\"surface_zero_copy\",\"control_transport\":\"inherited_memfd_eventfd\",\"decoder_name\":\"%s\",\"encoder_name\":\"%s\",\"input_mime\":\"%s\",\"output_mime\":\"%s\"}",
                        session->decoder_name, session->encoder_name,
                        input_mime, output_mime);
                if (count >= 0 && (size_t)count < description_size) {
                    *result = session;
                    return DSCW_CODEC_OK;
                }
                dscw_codec_destroy(session);
                set_error(error, error_size,
                          "transcoder description exceeds limit");
                return DSCW_CODEC_ERROR_IO;
            }
            AMediaCodec_delete(decoder);
        }
        stop_delete_codec(&encoder);
        if (surface != NULL) ANativeWindow_release(surface);
    }
    dscw_codec_destroy(session);
    set_error(error, error_size,
              "no proven hardware decoder/encoder Surface pair is available");
    return DSCW_CODEC_ERROR_CODEC;
}

static int pump_transcoder(struct dscw_codec_session *session,
                           uint32_t timeout_ms, char *error,
                           size_t error_size) {
    AMediaCodecBufferInfo info;
    for (int attempt = 0; attempt < 16 && !session->encoder_eos_signaled;
            attempt++) {
        ssize_t index = AMediaCodec_dequeueOutputBuffer(session->decoder, &info,
                attempt == 0 ? (int64_t)timeout_ms * 1000 : 0);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return DSCW_CODEC_OK;
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED
                || index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
        if (index < 0) continue;
        bool eos = ((uint32_t)info.flags & BUFFER_FLAG_END_OF_STREAM) != 0;
        bool render = info.size > 0;
        if (render) session->surface_frames++;
        if (AMediaCodec_releaseOutputBuffer(session->decoder, (size_t)index,
                                            render) != AMEDIA_OK) {
            set_error(error, error_size, "could not render decoder output");
            return DSCW_CODEC_ERROR_CODEC;
        }
        if (eos) {
            if (optional_api.signal_input_eos == NULL
                    || optional_api.signal_input_eos(
                            session->transcode_encoder) != AMEDIA_OK) {
                set_error(error, error_size,
                          "could not signal Surface encoder EOS");
                return DSCW_CODEC_ERROR_CODEC;
            }
            session->encoder_eos_signaled = true;
            break;
        }
    }
    return DSCW_CODEC_OK;
}

static int queue_internal(struct dscw_codec_session *session,
                          const uint8_t *data, size_t length,
                          uint64_t presentation_time_us, uint32_t flags,
                          char *error, size_t error_size) {
    if (session == NULL || session->input_eos) {
        set_error(error, error_size, "codec input is closed after EOS");
        return DSCW_CODEC_ERROR_SESSION;
    }
    if (length == 0 || length > DSCW_MAX_PAYLOAD - 16u
            || (flags & ~BUFFER_FLAG_CODEC_CONFIG) != 0) {
        set_error(error, error_size, "invalid codec input record");
        return DSCW_CODEC_ERROR_PROTOCOL;
    }
    if (session->encoder && !session->transcoder
            && (flags & BUFFER_FLAG_CODEC_CONFIG) == 0
            && session->have_encoder_pts
            && presentation_time_us <= session->last_encoder_pts) {
        set_error(error, error_size, "encoder frame PTS must increase monotonically");
        return DSCW_CODEC_ERROR_PROTOCOL;
    }
    AMediaCodec *codec = session->transcoder ? session->decoder : session->codec;
    if (session->transcoder) {
        int pumped = pump_transcoder(session, 0, error, error_size);
        if (pumped != DSCW_CODEC_OK) return pumped;
    }
    ssize_t index = AMediaCodec_dequeueInputBuffer(codec, 100000);
    if (index < 0) return DSCW_CODEC_AGAIN;
    size_t capacity = 0;
    uint8_t *destination = AMediaCodec_getInputBuffer(codec, (size_t)index,
                                                      &capacity);
    if (destination == NULL || length > capacity) {
        (void)AMediaCodec_queueInputBuffer(codec, (size_t)index, 0, 0,
                                           presentation_time_us, 0);
        set_error(error, error_size,
                  "input packet exceeds MediaCodec buffer capacity");
        return DSCW_CODEC_ERROR_LIMIT;
    }
    memcpy(destination, data, length);
    media_status_t queued = AMediaCodec_queueInputBuffer(codec, (size_t)index,
            0, length, presentation_time_us, flags & BUFFER_FLAG_CODEC_CONFIG);
    if (queued != AMEDIA_OK) {
        set_error(error, error_size, "AMediaCodec_queueInputBuffer failed: %d",
                  queued);
        return DSCW_CODEC_ERROR_CODEC;
    }
    session->input_records++;
    session->input_bytes += length;
    if ((flags & BUFFER_FLAG_CODEC_CONFIG) == 0) {
        session->input_frames++;
        if (session->encoder && !session->transcoder) {
            session->have_encoder_pts = true;
            session->last_encoder_pts = presentation_time_us;
        }
    }
    if (session->transcoder) {
        int pumped = pump_transcoder(session, 0, error, error_size);
        if (pumped != DSCW_CODEC_OK) return pumped;
    }
    return DSCW_CODEC_OK;
}

int dscw_codec_queue(struct dscw_codec_session *session, const uint8_t *data,
                     size_t length, uint64_t presentation_time_us,
                     uint32_t flags, char *error, size_t error_size) {
    uint64_t started = monotonic_ns();
    int result = queue_internal(session, data, length, presentation_time_us,
                                flags, error, error_size);
    if (session != NULL) {
        record_latency(&session->input_latency, started);
        if (result == DSCW_CODEC_AGAIN) session->input_again++;
        else if (result < DSCW_CODEC_OK) session->errors++;
    }
    return result;
}

int dscw_codec_queue_eos(struct dscw_codec_session *session,
                         uint64_t presentation_time_us,
                         char *error, size_t error_size) {
    uint64_t started = monotonic_ns();
    if (session == NULL || session->input_eos) {
        set_error(error, error_size, "codec EOS was already queued");
        if (session != NULL) session->errors++;
        return DSCW_CODEC_ERROR_SESSION;
    }
    AMediaCodec *codec = session->transcoder ? session->decoder : session->codec;
    if (session->transcoder) {
        int pumped = pump_transcoder(session, 0, error, error_size);
        if (pumped != DSCW_CODEC_OK) return pumped;
    }
    ssize_t index = AMediaCodec_dequeueInputBuffer(codec, 100000);
    if (index < 0) {
        session->input_again++;
        record_latency(&session->input_latency, started);
        return DSCW_CODEC_AGAIN;
    }
    media_status_t queued = AMediaCodec_queueInputBuffer(codec, (size_t)index,
            0, 0, presentation_time_us, BUFFER_FLAG_END_OF_STREAM);
    record_latency(&session->input_latency, started);
    if (queued != AMEDIA_OK) {
        session->errors++;
        set_error(error, error_size, "could not queue codec EOS: %d", queued);
        return DSCW_CODEC_ERROR_CODEC;
    }
    session->input_eos = true;
    session->input_eos_count++;
    if (session->transcoder) {
        return pump_transcoder(session, 0, error, error_size);
    }
    return DSCW_CODEC_OK;
}

static void put_u32(uint8_t *destination, uint32_t value) {
    value = htonl(value);
    memcpy(destination, &value, sizeof(value));
}

static void put_u64(uint8_t *destination, uint64_t value) {
    put_u32(destination, (uint32_t)(value >> 32));
    put_u32(destination + 4, (uint32_t)value);
}

static int format_record(struct dscw_codec_session *session, AMediaCodec *codec,
                         uint8_t *output, size_t capacity) {
    if (capacity < 20) return DSCW_CODEC_ERROR_LIMIT;
    AMediaFormat *format = AMediaCodec_getOutputFormat(codec);
    int32_t width = (int32_t)session->width;
    int32_t height = (int32_t)session->height;
    int32_t stride = width;
    int32_t slice_height = height;
    if (format != NULL) {
        (void)AMediaFormat_getInt32(format, "width", &width);
        (void)AMediaFormat_getInt32(format, "height", &height);
        (void)AMediaFormat_getInt32(format, "stride", &stride);
        (void)AMediaFormat_getInt32(format, "slice-height", &slice_height);
        AMediaFormat_delete(format);
    }
    put_u32(output, (uint32_t)width);
    put_u32(output + 4, (uint32_t)height);
    put_u32(output + 8, (uint32_t)stride);
    put_u32(output + 12, (uint32_t)slice_height);
    put_u32(output + 16, session->encoder || session->transcoder
            ? PIXEL_FORMAT_BITSTREAM : PIXEL_FORMAT_I420);
    return 20;
}

static int acquire_image(struct dscw_codec_session *session,
                         uint32_t timeout_ms, AImage **image) {
    uint64_t deadline = monotonic_ns()
            + (uint64_t)(timeout_ms == 0 ? 100 : timeout_ms) * 1000000u;
    do {
        media_status_t status = AImageReader_acquireNextImage(
                session->image_reader, image);
        if (status == AMEDIA_OK && *image != NULL) return DSCW_CODEC_OK;
        if (status != AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE) {
            return DSCW_CODEC_ERROR_CODEC;
        }
        usleep(1000);
    } while (monotonic_ns() < deadline);
    return DSCW_CODEC_AGAIN;
}

static int normalize_image(AImage *image, uint8_t *output, size_t capacity,
                           size_t *length, char *error, size_t error_size) {
    int32_t format = 0;
    int32_t planes = 0;
    AImageCropRect crop;
    if (AImage_getFormat(image, &format) != AMEDIA_OK
            || format != AIMAGE_FORMAT_YUV_420_888
            || AImage_getNumberOfPlanes(image, &planes) != AMEDIA_OK
            || planes != 3 || AImage_getCropRect(image, &crop) != AMEDIA_OK) {
        set_error(error, error_size, "decoder image is not three-plane YUV_420_888");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    int32_t width = crop.right - crop.left;
    int32_t height = crop.bottom - crop.top;
    uint64_t frame_length = (uint64_t)width * (uint64_t)height * 3u / 2u;
    if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0
            || frame_length > capacity) {
        set_error(error, error_size, "decoder image crop exceeds output bounds");
        return DSCW_CODEC_ERROR_LIMIT;
    }
    size_t destination = 0;
    for (int plane = 0; plane < 3; plane++) {
        uint8_t *data = NULL;
        int data_length = 0;
        int32_t row_stride = 0;
        int32_t pixel_stride = 0;
        if (AImage_getPlaneData(image, plane, &data, &data_length) != AMEDIA_OK
                || AImage_getPlaneRowStride(image, plane, &row_stride) != AMEDIA_OK
                || AImage_getPlanePixelStride(image, plane, &pixel_stride) != AMEDIA_OK
                || data == NULL || data_length <= 0 || row_stride <= 0
                || pixel_stride <= 0) {
            set_error(error, error_size, "could not map decoder YUV plane %d", plane);
            return DSCW_CODEC_ERROR_CODEC;
        }
        int shift = plane == 0 ? 0 : 1;
        int plane_width = width >> shift;
        int plane_height = height >> shift;
        int crop_left = crop.left >> shift;
        int crop_top = crop.top >> shift;
        for (int row = 0; row < plane_height; row++) {
            int64_t first = (int64_t)(crop_top + row) * row_stride
                    + (int64_t)crop_left * pixel_stride;
            int64_t last = first + (int64_t)(plane_width - 1) * pixel_stride;
            if (first < 0 || last < first || last >= data_length) {
                set_error(error, error_size, "decoder YUV plane bounds are invalid");
                return DSCW_CODEC_ERROR_CODEC;
            }
            if (pixel_stride == 1) {
                memcpy(output + destination, data + first, (size_t)plane_width);
                destination += (size_t)plane_width;
            } else {
                for (int column = 0; column < plane_width; column++) {
                    output[destination++] = data[first
                            + (int64_t)column * pixel_stride];
                }
            }
        }
    }
    *length = destination;
    return DSCW_CODEC_OK;
}

static int output_pending_image(struct dscw_codec_session *session,
                                uint32_t timeout_ms, uint8_t *output,
                                size_t capacity, size_t *output_length,
                                char *error, size_t error_size) {
    AImage *image = NULL;
    int acquired = acquire_image(session, timeout_ms, &image);
    if (acquired != DSCW_CODEC_OK) return acquired;
    size_t image_length = 0;
    int normalized = normalize_image(image, output + 16,
            capacity >= 16 ? capacity - 16 : 0, &image_length,
            error, error_size);
    AImage_delete(image);
    if (normalized != DSCW_CODEC_OK) return normalized;
    put_u64(output, session->pending_image_pts);
    put_u32(output + 8, session->pending_image_flags);
    put_u32(output + 12, (uint32_t)image_length);
    *output_length = 16 + image_length;
    session->pending_image = false;
    session->output_records++;
    session->output_frames++;
    session->output_bytes += image_length;
    session->cpu_yuv_frames++;
    return DSCW_CODEC_OK;
}

static int dequeue_internal(struct dscw_codec_session *session,
                            uint32_t timeout_ms, uint8_t *output,
                            size_t capacity, size_t *output_length,
                            char *error, size_t error_size) {
    if (session == NULL || output == NULL || output_length == NULL
            || capacity < 20) {
        set_error(error, error_size, "invalid codec output buffer");
        return DSCW_CODEC_ERROR_PROTOCOL;
    }
    if (session->pending_image) {
        return output_pending_image(session, timeout_ms, output, capacity,
                                    output_length, error, error_size);
    }
    AMediaCodec *codec;
    if (session->transcoder) {
        int pumped = pump_transcoder(session, timeout_ms, error, error_size);
        if (pumped != DSCW_CODEC_OK) return pumped;
        codec = session->transcode_encoder;
    } else {
        codec = session->codec;
    }
    AMediaCodecBufferInfo info;
    for (int attempt = 0; attempt < 3; attempt++) {
        ssize_t index = AMediaCodec_dequeueOutputBuffer(codec, &info,
                (int64_t)timeout_ms * 1000);
        if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return DSCW_CODEC_AGAIN;
        if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            int length = format_record(session, codec, output, capacity);
            if (length < 0) {
                set_error(error, error_size, "output format exceeds limit");
                return length;
            }
            *output_length = (size_t)length;
            session->format_changes++;
            return DSCW_CODEC_FORMAT_CHANGED;
        }
        if (index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED || index < 0) continue;
        bool decoder_image = !session->encoder && !session->transcoder;
        bool eos = ((uint32_t)info.flags & BUFFER_FLAG_END_OF_STREAM) != 0;
        if (decoder_image && info.size > 0) {
            session->pending_image = true;
            session->pending_image_pts = info.presentationTimeUs;
            session->pending_image_flags = (uint32_t)info.flags;
            media_status_t released = AMediaCodec_releaseOutputBuffer(
                    codec, (size_t)index, true);
            if (released != AMEDIA_OK) {
                session->pending_image = false;
                set_error(error, error_size, "could not render decoder image");
                return DSCW_CODEC_ERROR_CODEC;
            }
            return output_pending_image(session, timeout_ms, output, capacity,
                                        output_length, error, error_size);
        }
        if ((uint64_t)info.size + 16u > capacity || info.offset < 0) {
            (void)AMediaCodec_releaseOutputBuffer(codec, (size_t)index, false);
            set_error(error, error_size, "codec output exceeds shared slot");
            return DSCW_CODEC_ERROR_LIMIT;
        }
        size_t buffer_capacity = 0;
        uint8_t *source = AMediaCodec_getOutputBuffer(codec, (size_t)index,
                                                      &buffer_capacity);
        if (info.size > 0 && (source == NULL
                || (uint64_t)info.offset + (uint64_t)info.size > buffer_capacity)) {
            (void)AMediaCodec_releaseOutputBuffer(codec, (size_t)index, false);
            set_error(error, error_size, "MediaCodec output buffer is invalid");
            return DSCW_CODEC_ERROR_CODEC;
        }
        put_u64(output, info.presentationTimeUs);
        put_u32(output + 8, (uint32_t)info.flags);
        put_u32(output + 12, (uint32_t)info.size);
        if (info.size > 0) {
            memcpy(output + 16, source + info.offset, (size_t)info.size);
        }
        (void)AMediaCodec_releaseOutputBuffer(codec, (size_t)index, false);
        *output_length = 16u + (size_t)info.size;
        if (info.size > 0) {
            session->output_records++;
            session->output_bytes += (uint64_t)info.size;
            if (((uint32_t)info.flags & BUFFER_FLAG_CODEC_CONFIG) == 0) {
                session->output_frames++;
            }
        }
        if (eos) session->output_eos_count++;
        return DSCW_CODEC_OK;
    }
    return DSCW_CODEC_AGAIN;
}

int dscw_codec_dequeue(struct dscw_codec_session *session, uint32_t timeout_ms,
                       uint8_t *output, size_t output_capacity,
                       size_t *output_length, char *error, size_t error_size) {
    uint64_t started = monotonic_ns();
    int result = dequeue_internal(session, timeout_ms, output, output_capacity,
                                  output_length, error, error_size);
    if (session != NULL) {
        record_latency(&session->output_latency, started);
        if (result == DSCW_CODEC_AGAIN) session->output_again++;
        else if (result < DSCW_CODEC_OK) session->errors++;
    }
    return result;
}

static void drain_images(AImageReader *reader) {
    if (reader == NULL) return;
    for (;;) {
        AImage *image = NULL;
        if (AImageReader_acquireNextImage(reader, &image) != AMEDIA_OK
                || image == NULL) break;
        AImage_delete(image);
    }
}

int dscw_codec_flush(struct dscw_codec_session *session,
                     char *error, size_t error_size) {
    if (session == NULL) return DSCW_CODEC_ERROR_SESSION;
    media_status_t status;
    if (session->transcoder) {
        status = AMediaCodec_flush(session->decoder);
        if (status == AMEDIA_OK) {
            status = AMediaCodec_flush(session->transcode_encoder);
        }
    } else {
        status = AMediaCodec_flush(session->codec);
    }
    if (status != AMEDIA_OK) {
        session->errors++;
        set_error(error, error_size, "AMediaCodec_flush failed: %d", status);
        return DSCW_CODEC_ERROR_CODEC;
    }
    drain_images(session->image_reader);
    session->input_eos = false;
    session->encoder_eos_signaled = false;
    session->pending_image = false;
    session->have_encoder_pts = false;
    return DSCW_CODEC_OK;
}

int dscw_codec_request_keyframe(struct dscw_codec_session *session,
                                char *error, size_t error_size) {
    load_optional_api();
    if (session == NULL || (!session->encoder && !session->transcoder)) {
        set_error(error, error_size, "keyframe request requires an encoder");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    if (optional_api.set_parameters == NULL) {
        set_error(error, error_size,
                  "keyframe request requires Android API 26 or newer");
        return DSCW_CODEC_ERROR_UNSUPPORTED;
    }
    AMediaFormat *parameters = AMediaFormat_new();
    if (parameters == NULL) return DSCW_CODEC_ERROR_IO;
    AMediaFormat_setInt32(parameters, "request-sync", 0);
    AMediaCodec *codec = session->transcoder ? session->transcode_encoder
                                             : session->codec;
    media_status_t status = optional_api.set_parameters(codec, parameters);
    AMediaFormat_delete(parameters);
    if (status != AMEDIA_OK) {
        session->errors++;
        set_error(error, error_size, "AMediaCodec_setParameters failed: %d",
                  status);
        return DSCW_CODEC_ERROR_CODEC;
    }
    return DSCW_CODEC_OK;
}

int dscw_codec_statistics(struct dscw_codec_session *session, uint64_t session_id,
                          char *output, size_t output_size) {
    if (session == NULL || output == NULL || output_size == 0) return -1;
    const char *kind = session->transcoder ? "surface_transcoder"
            : (session->encoder ? "bytebuffer_encoder" : "bytebuffer_decoder");
    const char *transport = session->transcoder ? "surface_zero_copy"
                                                : "bytebuffer";
    uint64_t input_average = session->input_latency.samples == 0 ? 0
            : session->input_latency.total_us / session->input_latency.samples;
    uint64_t output_average = session->output_latency.samples == 0 ? 0
            : session->output_latency.total_us / session->output_latency.samples;
    int count = snprintf(output, output_size,
            "{\"session_id\":%" PRIu64 ",\"kind\":\"%s\",\"transport\":\"%s\",\"media_transport\":\"inherited_memfd_eventfd\",\"input_frames\":%" PRIu64 ",\"output_frames\":%" PRIu64 ",\"surface_frames\":%" PRIu64 ",\"cpu_yuv_frames\":%" PRIu64 ",\"input_records\":%" PRIu64 ",\"output_records\":%" PRIu64 ",\"input_bytes\":%" PRIu64 ",\"output_bytes\":%" PRIu64 ",\"shared_input_bytes\":%" PRIu64 ",\"shared_output_bytes\":%" PRIu64 ",\"input_eos\":%" PRIu64 ",\"output_eos\":%" PRIu64 ",\"input_dequeue_timeouts\":%" PRIu64 ",\"output_dequeue_timeouts\":%" PRIu64 ",\"errors\":%" PRIu64 ",\"dropped_frames\":0,\"uptime_ms\":%" PRIu64 ",\"process_cpu_time_ms\":%" PRIu64 ",\"input_call_latency_samples\":%" PRIu64 ",\"input_call_latency_avg_us\":%" PRIu64 ",\"input_call_latency_max_us\":%" PRIu64 ",\"output_call_latency_samples\":%" PRIu64 ",\"output_call_latency_avg_us\":%" PRIu64 ",\"output_call_latency_max_us\":%" PRIu64 "}",
            session_id, kind, transport, session->input_frames,
            session->output_frames, session->surface_frames,
            session->cpu_yuv_frames, session->input_records,
            session->output_records, session->input_bytes,
            session->output_bytes, session->input_bytes, session->output_bytes,
            session->input_eos_count, session->output_eos_count,
            session->input_again, session->output_again, session->errors,
            (monotonic_ns() - session->started_ns) / 1000000u,
            process_cpu_ms(), session->input_latency.samples, input_average,
            session->input_latency.max_us, session->output_latency.samples,
            output_average, session->output_latency.max_us);
    if (count < 0 || (size_t)count >= output_size) return -1;
    return count;
}

void dscw_codec_destroy(struct dscw_codec_session *session) {
    if (session == NULL) return;
    stop_delete_codec(&session->decoder);
    stop_delete_codec(&session->transcode_encoder);
    if (session->encoder_input_surface != NULL) {
        ANativeWindow_release(session->encoder_input_surface);
        session->encoder_input_surface = NULL;
    }
    stop_delete_codec(&session->codec);
    if (session->image_reader != NULL) {
        AImageReader_delete(session->image_reader);
        session->image_reader = NULL;
    }
    free(session);
}

const char *dscw_codec_worker_capabilities(void) {
    return "{\"protocol\":1,\"worker\":\"ndk_mediacodec\",\"transport\":\"inherited_memfd_eventfd\",\"public_listener\":false,\"descriptor_transfer\":false,\"decode_output\":\"AImageReader_YUV_420_888_to_I420\",\"encode_input\":\"YUV420_ByteBuffer\",\"transcode\":\"decoder_Surface_to_encoder_Surface\",\"codecs\":[\"video/avc\",\"video/hevc\"],\"software_fallback\":false}";
}
