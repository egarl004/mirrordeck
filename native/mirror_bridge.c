/* mirror_bridge.c — wires the UxPlay raop/dnssd core to the mb_* API.
 * Initialization sequence mirrors uxplay.cpp's start_dnssd/start_raop_server.
 */
#include "mirror_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>

#include "raop.h"
#include "dnssd.h"
#include "logger.h"
#include "stream.h"

static raop_t *g_raop = NULL;
static dnssd_t *g_dnssd = NULL;
static mb_callbacks_t g_cbs;
static char g_device_id[18];

/* ---- raop callbacks ------------------------------------------------- */

static void cb_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void)cls; (void)ntp;
    if (g_cbs.on_video && data && data->data && data->data_len > 0) {
        g_cbs.on_video(g_cbs.ctx, data->data, data->data_len,
                       data->ntp_time_local, data->ntp_time_remote,
                       data->is_h265 ? 1 : 0);
    }
}

static void cb_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void)cls; (void)ntp;
    if (g_cbs.on_audio && data && data->data && data->data_len > 0) {
        g_cbs.on_audio(g_cbs.ctx, data->data, data->data_len,
                       data->ct, data->ntp_time_local);
    }
}

static void emit(int event, int value, const char *info) {
    if (g_cbs.on_event) g_cbs.on_event(g_cbs.ctx, event, value, info);
}

static void cb_conn_init(void *cls)    { (void)cls; emit(MB_EVENT_CONN_INIT, 0, NULL); }
static void cb_conn_destroy(void *cls) { (void)cls; emit(MB_EVENT_CONN_DESTROY, 0, NULL); }
static void cb_conn_reset(void *cls, int reason) { (void)cls; emit(MB_EVENT_CONN_RESET, reason, NULL); }
static void cb_conn_feedback(void *cls) { (void)cls; }
static void cb_video_pause(void *cls)  { (void)cls; emit(MB_EVENT_VIDEO_PAUSE, 0, NULL); }
static void cb_video_resume(void *cls) { (void)cls; emit(MB_EVENT_VIDEO_RESUME, 0, NULL); }
static void cb_video_flush(void *cls)  { (void)cls; emit(MB_EVENT_VIDEO_FLUSH, 0, NULL); }
static void cb_audio_flush(void *cls)  { (void)cls; emit(MB_EVENT_AUDIO_FLUSH, 0, NULL); }
static void cb_video_reset(void *cls, reset_type_t t) { (void)cls; emit(MB_EVENT_VIDEO_RESET, (int)t, NULL); }
static void cb_mirror_video_running(void *cls, bool running) { (void)cls; emit(MB_EVENT_MIRROR_RUNNING, running ? 1 : 0, NULL); }

static void cb_report_client_request(void *cls, char *deviceid, char *model,
                                     char *name, bool *admit) {
    (void)cls;
    char info[512];
    snprintf(info, sizeof(info), "%s\t%s\t%s",
             deviceid ? deviceid : "", model ? model : "", name ? name : "");
    emit(MB_EVENT_CLIENT_INFO, 0, info);
    if (admit) *admit = true;
}

static void cb_video_report_size(void *cls, float *width_source, float *height_source,
                                 float *width, float *height) {
    (void)cls; (void)width; (void)height;
    if (width_source && height_source) {
        char info[64];
        snprintf(info, sizeof(info), "%dx%d", (int)*width_source, (int)*height_source);
        emit(MB_EVENT_SOURCE_SIZE, 0, info);
    }
}

static void cb_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf,
                                bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    (void)cls; (void)spf; (void)usingScreen; (void)isMedia; (void)audioFormat;
    if (ct) emit(MB_EVENT_AUDIO_FORMAT, (int)*ct, NULL);
}

static double cb_audio_set_client_volume(void *cls) { (void)cls; return 0.0; }
static void cb_audio_set_volume(void *cls, float volume) { (void)cls; (void)volume; }
static bool cb_check_register(void *cls, const char *pk_str) { (void)cls; (void)pk_str; return true; }
static const char *cb_passwd(void *cls, int *len) { (void)cls; if (len) *len = 0; return NULL; }
static int cb_video_set_codec(void *cls, video_codec_t codec) { (void)cls; (void)codec; return 0; }

static void cb_log(void *cls, int level, const char *msg) {
    (void)cls;
    if (g_cbs.on_log) g_cbs.on_log(g_cbs.ctx, level, msg);
}

/* ---- stable, locally-administered MAC derived from the hostname ------ */

static void derive_hw_addr(const char *seed, unsigned char out[6]) {
    uint64_t h = 1469598103934665603ULL; /* FNV-1a */
    for (const char *p = seed; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 1099511628211ULL;
    }
    for (int i = 0; i < 6; i++) {
        out[i] = (unsigned char)(h >> (8 * i));
    }
    out[0] = (out[0] & 0xFE) | 0x02; /* locally administered, unicast */
}

/* ---- public API ------------------------------------------------------ */

int mb_start(const char *name, const mb_callbacks_t *cbs, int debug_log) {
    if (g_raop || g_dnssd) return -1;
    if (!name || !cbs || !cbs->on_video || !cbs->on_audio) return -2;
    memcpy(&g_cbs, cbs, sizeof(g_cbs));

    ntp_global_init();

    char hostname[256] = "mirrordeck";
    gethostname(hostname, sizeof(hostname) - 1);
    char seed[512];
    snprintf(seed, sizeof(seed), "%s|%s", hostname, name);
    unsigned char hw_addr[6];
    derive_hw_addr(seed, hw_addr);
    snprintf(g_device_id, sizeof(g_device_id), "%02X:%02X:%02X:%02X:%02X:%02X",
             hw_addr[0], hw_addr[1], hw_addr[2], hw_addr[3], hw_addr[4], hw_addr[5]);

    int dnssd_error = 0;
    g_dnssd = dnssd_init(name, (int)strlen(name), (const char *)hw_addr,
                         sizeof(hw_addr), 0 /* no pin/password */, &dnssd_error);
    if (dnssd_error || !g_dnssd) {
        g_dnssd = NULL;
        return -3;
    }

    /* Feature bits: same set uxplay advertises (mirroring, FairPlay, audio;
     * no HLS, no H.265, no rotation). */
    dnssd_set_airplay_features(g_dnssd, 0, 0);
    dnssd_set_airplay_features(g_dnssd, 1, 1);
    dnssd_set_airplay_features(g_dnssd, 2, 1);
    dnssd_set_airplay_features(g_dnssd, 3, 0);
    dnssd_set_airplay_features(g_dnssd, 4, 0);
    dnssd_set_airplay_features(g_dnssd, 5, 1);
    dnssd_set_airplay_features(g_dnssd, 6, 1);
    dnssd_set_airplay_features(g_dnssd, 7, 1);
    dnssd_set_airplay_features(g_dnssd, 8, 0);
    dnssd_set_airplay_features(g_dnssd, 9, 1);
    dnssd_set_airplay_features(g_dnssd, 10, 1);
    dnssd_set_airplay_features(g_dnssd, 11, 1);
    dnssd_set_airplay_features(g_dnssd, 12, 1);
    dnssd_set_airplay_features(g_dnssd, 13, 1);
    dnssd_set_airplay_features(g_dnssd, 14, 1);
    dnssd_set_airplay_features(g_dnssd, 15, 1);
    dnssd_set_airplay_features(g_dnssd, 16, 1);
    dnssd_set_airplay_features(g_dnssd, 17, 1);
    dnssd_set_airplay_features(g_dnssd, 18, 1);
    dnssd_set_airplay_features(g_dnssd, 19, 1);
    dnssd_set_airplay_features(g_dnssd, 20, 1);
    dnssd_set_airplay_features(g_dnssd, 21, 1);
    dnssd_set_airplay_features(g_dnssd, 22, 1);
    dnssd_set_airplay_features(g_dnssd, 23, 0);
    dnssd_set_airplay_features(g_dnssd, 24, 0);
    dnssd_set_airplay_features(g_dnssd, 25, 1);
    dnssd_set_airplay_features(g_dnssd, 26, 0);
    dnssd_set_airplay_features(g_dnssd, 27, 1);
    dnssd_set_airplay_features(g_dnssd, 28, 1);
    dnssd_set_airplay_features(g_dnssd, 29, 0);
    dnssd_set_airplay_features(g_dnssd, 30, 1);
    dnssd_set_airplay_features(g_dnssd, 31, 0);

    raop_callbacks_t raop_cbs;
    memset(&raop_cbs, 0, sizeof(raop_cbs));
    raop_cbs.cls = NULL;
    raop_cbs.audio_process = cb_audio_process;
    raop_cbs.video_process = cb_video_process;
    raop_cbs.conn_init = cb_conn_init;
    raop_cbs.conn_destroy = cb_conn_destroy;
    raop_cbs.conn_reset = cb_conn_reset;
    raop_cbs.conn_feedback = cb_conn_feedback;
    raop_cbs.audio_flush = cb_audio_flush;
    raop_cbs.video_flush = cb_video_flush;
    raop_cbs.video_pause = cb_video_pause;
    raop_cbs.video_resume = cb_video_resume;
    raop_cbs.video_reset = cb_video_reset;
    raop_cbs.audio_set_client_volume = cb_audio_set_client_volume;
    raop_cbs.audio_set_volume = cb_audio_set_volume;
    raop_cbs.audio_get_format = cb_audio_get_format;
    raop_cbs.video_report_size = cb_video_report_size;
    raop_cbs.report_client_request = cb_report_client_request;
    raop_cbs.check_register = cb_check_register;
    raop_cbs.passwd = cb_passwd;
    raop_cbs.video_set_codec = cb_video_set_codec;
    raop_cbs.mirror_video_running = cb_mirror_video_running;

    g_raop = raop_init(&raop_cbs);
    if (!g_raop) {
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        return -4;
    }

    raop_set_log_callback(g_raop, cb_log, NULL);
    raop_set_log_level(g_raop, debug_log ? LOGGER_DEBUG : LOGGER_INFO);

    if (raop_init2(g_raop, 1 /* nohold: new client displaces old */, g_device_id, "")) {
        raop_destroy(g_raop);
        g_raop = NULL;
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
        return -5;
    }

    unsigned short tcp[3] = {0, 0, 0};
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(g_raop, tcp);
    raop_set_udp_ports(g_raop, udp);

    unsigned short raop_port = raop_get_port(g_raop);
    raop_start_httpd(g_raop, &raop_port);
    raop_set_port(g_raop, raop_port);
    raop_set_dnssd(g_raop, g_dnssd);

    if (dnssd_register_raop(g_dnssd, raop_port) ||
        dnssd_register_airplay(g_dnssd, raop_port)) {
        mb_stop();
        return -6;
    }
    return 0;
}

void mb_stop(void) {
    if (g_raop) {
        raop_destroy(g_raop);
        g_raop = NULL;
    }
    if (g_dnssd) {
        dnssd_unregister_raop(g_dnssd);
        dnssd_unregister_airplay(g_dnssd);
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
    }
    memset(&g_cbs, 0, sizeof(g_cbs));
}
