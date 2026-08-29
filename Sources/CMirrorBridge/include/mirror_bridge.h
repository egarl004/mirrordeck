/* mirror_bridge.h — minimal C API over the UxPlay AirPlay receiver core.
 *
 * Hides all raop/dnssd internals behind a start/stop + callbacks surface
 * so the Swift app only ever sees decrypted media frames and events.
 */
#ifndef MIRROR_BRIDGE_H
#define MIRROR_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MB_EVENT_CONN_INIT = 0,     /* a client opened a connection */
    MB_EVENT_CONN_DESTROY = 1,  /* client connection closed */
    MB_EVENT_CONN_RESET = 2,    /* value = reason */
    MB_EVENT_VIDEO_PAUSE = 3,
    MB_EVENT_VIDEO_RESUME = 4,
    MB_EVENT_VIDEO_FLUSH = 5,
    MB_EVENT_AUDIO_FLUSH = 6,
    MB_EVENT_VIDEO_RESET = 7,   /* value = reset_type */
    MB_EVENT_CLIENT_INFO = 8,   /* info = "deviceid\tmodel\tname" */
    MB_EVENT_SOURCE_SIZE = 9,   /* info = "<width>x<height>" (source pixels) */
    MB_EVENT_AUDIO_FORMAT = 10, /* value = compression type (ct) */
    MB_EVENT_MIRROR_RUNNING = 11 /* value = 0/1 */
} mb_event_t;

/* Annex-B H.264/H.265 frame data (may contain several NAL units). */
typedef void (*mb_video_cb)(void *ctx, const uint8_t *data, int len,
                            uint64_t ntp_local, uint64_t ntp_remote, int is_h265);
/* Compressed audio frame; ct: 2=ALAC 4=AAC-LC 8=AAC-ELD. */
typedef void (*mb_audio_cb)(void *ctx, const uint8_t *data, int len,
                            unsigned char ct, uint64_t ntp_local);
typedef void (*mb_event_cb)(void *ctx, int event, int value, const char *info);
/* level follows syslog-ish ordering used by the lib logger (higher = chattier). */
typedef void (*mb_log_cb)(void *ctx, int level, const char *msg);

typedef struct {
    void *ctx;
    mb_video_cb on_video;
    mb_audio_cb on_audio;
    mb_event_cb on_event;
    mb_log_cb on_log;
} mb_callbacks_t;

/* Start the receiver: advertises `name` over Bonjour so it appears in the
 * iOS Control Center Screen Mirroring list, and serves AirPlay mirroring.
 * `debug_log` != 0 enables verbose protocol logging.
 * Returns 0 on success, negative on failure. Only one instance may run. */
int mb_start(const char *name, const mb_callbacks_t *cbs, int debug_log);

/* Stop the receiver and unregister the Bonjour services. */
void mb_stop(void);

#ifdef __cplusplus
}
#endif
#endif
