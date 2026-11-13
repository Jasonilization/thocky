/*
 * audio_engine.h - low-latency Core Audio playback engine.
 *
 * Design notes:
 *  - Clips are decoded to deinterleaved FLOAT32 and kept resident in RAM ("pre-loaded
 *    audio buffers"), one buffer per (key-group, press/release, force-tier, variant).
 *  - The mixer runs inside a Core Audio render callback on a real-time thread. No
 *    allocation, locking of unbounded scope, or I/O happens there; voices are a fixed
 *    pool and play requests land in a lock-free ring buffer.
 *  - mix (0..1) blends the lower tier into the upper tier so force is continuous
 *    rather than 4 hard steps.
 */
#ifndef KS_AUDIO_ENGINE_H
#define KS_AUDIO_ENGINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KS_GROUP_COUNT 4
#define KS_TIER_COUNT  4
#define KS_MAX_VARIANTS 8

/* key groups (matches file names on disk) */
#define KS_GROUP_GENERIC    0
#define KS_GROUP_ENTER      1
#define KS_GROUP_SPACE      2
#define KS_GROUP_BACKSPACE  3

/* events */
#define KS_EVENT_PRESS   0
#define KS_EVENT_RELEASE 1

typedef struct ks_pack ks_pack_t;

/* ---- engine lifecycle ---- */
int         ks_audio_init(void);            /* 1 = ready, 0 = failed (ks_audio_error) */
int         ks_audio_start(void);           /* init + start the render loop */
void        ks_audio_stop(void);            /* stop rendering (keeps buffers) */
void        ks_audio_shutdown(void);
int         ks_audio_is_running(void);
double      ks_audio_sample_rate(void);     /* Hz of the render callback */
int         ks_audio_buffer_frames(void);   /* requested IO buffer size */
double      ks_audio_latency_ms(void);      /* device + buffer latency estimate */
void        ks_audio_set_volume(float v);   /* 0..1 linear master */
float       ks_audio_get_volume(void);
void        ks_audio_idle_pause(void);      /* stop the unit after sustained silence */
void        ks_audio_idle_resume(void);
const char *ks_audio_error(void);
void        ks_audio_stats(unsigned long long *voices_started,
                           unsigned long long *underruns,
                           unsigned long long *active_voices,
                           unsigned long long *render_calls);

/* ---- packs ---- */
ks_pack_t  *ks_pack_load(const char *dir);      /* cached by path; NULL on failure */
void        ks_pack_release(ks_pack_t *p);      /* drops a reference; cached packs stay */
int         ks_pack_clip_count(const ks_pack_t *p);
void        ks_pack_cache_set_limit(int packs); /* keep at most N packs resident */
void        ks_pack_cache_clear(void);

/* ---- playback ---- */
/* Play one keystroke clip.
 *
 * pan is -1 (full left) .. +1 (full right): equal-power placement, plus a
 * fraction of a millisecond of interaural delay so a left-hand key reaches
 * the left ear first.
 * dist is 0 (front row) .. 1 (back row): further keys are a little quieter.
 */
void ks_play(const ks_pack_t *pack, int group, int tier_lo, int tier_hi,
             float mix, int event, float gain, float pan, float dist);
void ks_audio_render_into(float *out, unsigned int frames);  /* offline render (tests) */

#ifdef __cplusplus
}
#endif

#endif /* KS_AUDIO_ENGINE_H */
