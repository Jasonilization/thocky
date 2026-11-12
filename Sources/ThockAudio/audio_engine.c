/* audio_engine.c - native Core Audio playback engine.
 *
 * Path: AudioUnit (kAudioUnitSubType_DefaultOutput) -> render callback on a
 * real-time thread -> fixed voice pool mixing pre-loaded float buffers.
 * Requests arrive from the keyboard-tap thread through a bounded ring buffer that
 * the callback drains; no allocation or unbounded work happens in real time.
 */
#include "../include/audio_engine.h"
#include "pack.h"
#include "wav.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------- state */

#define KS_MAX_VOICES   96
#define KS_RING_SIZE    256
#define KS_FADE_FRAMES  48      /* ~1 ms: kills clicks when re-triggering a clip */
#define KS_IDLE_MS      180000  /* pause the unit after 3 minutes of silence */

typedef struct {
    const float *data;
    unsigned int frames;
    double       pos;
    double       step;          /* source frames per output frame */
    float        gain;
    float        gain_target;
    float        gain_step;
    int          active;
} ks_voice_t;

typedef struct {
    const ks_pack_t *pack;
    int   group;
    int   tier_lo, tier_hi;
    float mix;
    int   event;
    float gain;
} ks_trigger_t;

static struct {
    AudioUnit     unit;
    int           ready;
    int           started;
    double        sample_rate;
    int           channels;
    float         master;
    UInt32        buffer_frames;
    double        latency_ms;
    AudioDeviceID device;
    UInt32        saved_buffer_frames;
    int           has_saved_buffer;
    long long     last_activity_ms;
    int           idle_paused;

    ks_voice_t    voices[KS_MAX_VOICES];
    int           voice_rr;

    ks_trigger_t  ring[KS_RING_SIZE];
    _Atomic(int)  ring_head;
    _Atomic(int)  ring_tail;
    pthread_mutex_t ring_lock;

    unsigned long long voices_started;
    unsigned long long dropped;
    unsigned long long clipped;
    unsigned long long render_calls;
    _Atomic(int)      active_voices;
    unsigned int      xrng;
} g;

static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_error[256];

static int debug_on(void) {
    static int v = -1;
    if (v < 0) v = getenv("THOCK_DEBUG") ? 1 : 0;
    return v;
}

static OSStatus ks_render_cb(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                             const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                             UInt32 inNumberFrames, AudioBufferList *ioData);
static void ks_drain_triggers(void);
static void ks_spawn_voice(const ks_trigger_t *t);

const char *ks_audio_error(void) { return g_error; }

static long long now_ms(void) { return (long long)(CFAbsoluteTimeGetCurrent() * 1000.0); }

/* deterministic-ish jitter for playback (no locks, no syscalls) */
static float ks_jitter(float spread) {
    unsigned int x = g.xrng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    g.xrng = x ? x : 0x2545F491u;
    return ((float)(g.xrng & 0xFFFFFF) / (float)0xFFFFFF - 0.5f) * 2.0f * spread;
}

/* ------------------------------------------------------------ audio device */

static AudioDeviceID ks_default_output_device(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioDeviceID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL,
                                   &size, &id) != noErr)
        return kAudioObjectUnknown;
    return id;
}

static void ks_set_buffer_frames(AudioDeviceID dev, UInt32 frames) {
    if (dev == kAudioObjectUnknown) return;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(frames);
    (void)AudioObjectSetPropertyData(dev, &addr, 0, NULL, size, &frames);
}

static UInt32 ks_get_buffer_frames(AudioDeviceID dev) {
    UInt32 frames = 0;
    if (dev == kAudioObjectUnknown) return 0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(frames);
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &frames) != noErr) return 0;
    return frames;
}

static double ks_device_latency(AudioDeviceID dev) {
    double lat = 0.0;
    if (dev == kAudioObjectUnknown) return 0.0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyLatency,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(lat);
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &lat) != noErr) return 0.0;
    return lat;
}

int ks_audio_init(void) {
    pthread_mutex_lock(&g_init_lock);
    if (g.ready) { pthread_mutex_unlock(&g_init_lock); return 1; }

    g_error[0] = '\0';
    g.master = 0.8f;
    g.xrng = (unsigned int)mach_absolute_time() | 1u;
    pthread_mutex_init(&g.ring_lock, NULL);
    atomic_store(&g.ring_head, 0);
    atomic_store(&g.ring_tail, 0);
    atomic_store(&g.active_voices, 0);

    AudioComponentDescription cd = {
        kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
        kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &cd);
    if (!comp) {
        snprintf(g_error, sizeof(g_error), "DefaultOutput component not found");
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }
    OSStatus st = AudioComponentInstanceNew(comp, &g.unit);
    if (st != noErr || !g.unit) {
        snprintf(g_error, sizeof(g_error), "AudioComponentInstanceNew failed: %d", (int)st);
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }

    AURenderCallbackStruct cb = { ks_render_cb, NULL };
    st = AudioUnitSetProperty(g.unit, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (st != noErr) {
        st = AudioUnitSetProperty(g.unit, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Global, 0, &cb, sizeof(cb));
    }
    if (st != noErr) {
        snprintf(g_error, sizeof(g_error), "SetRenderCallback failed: %d", (int)st);
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }

    g.device = ks_default_output_device();
    if (g.device != kAudioObjectUnknown) {
        g.saved_buffer_frames = ks_get_buffer_frames(g.device);
        g.has_saved_buffer = (g.saved_buffer_frames > 0);
    }

    /* Request a small IO buffer (best effort; the real value is read back). */
    const UInt32 want_buffer = 128;
    ks_set_buffer_frames(g.device, want_buffer);

    UInt32 max_slice = 128;
    st = AudioUnitSetProperty(g.unit, kAudioUnitProperty_MaximumFramesPerSlice,
                              kAudioUnitScope_Global, 0, &max_slice, sizeof(max_slice));
    if (st != noErr) {
        snprintf(g_error, sizeof(g_error), "MaximumFramesPerSlice failed: %d", (int)st);
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }

    /* Pin the client format to 48 kHz stereo float. Core Audio converts to the
     * device rate, so our 48 kHz packs never play back detuned or stretched. */
    {
        AudioStreamBasicDescription want;
        memset(&want, 0, sizeof(want));
        want.mSampleRate = 48000.0;
        want.mFormatID = kAudioFormatLinearPCM;
        want.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        want.mFramesPerPacket = 1;
        want.mChannelsPerFrame = 2;
        want.mBitsPerChannel = 32;
        want.mBytesPerFrame = 2 * 4;
        want.mBytesPerPacket = 2 * 4;
        want.mReserved = 0;
        OSStatus s1 = AudioUnitSetProperty(g.unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &want, sizeof(want));
        if (s1 != noErr)
            s1 = AudioUnitSetProperty(g.unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Global, 0, &want, sizeof(want));
        if (debug_on()) fprintf(stderr, "[audio] set 48k client format -> %d\n", (int)s1);
    }

    st = AudioUnitInitialize(g.unit);
    if (st != noErr) {
        snprintf(g_error, sizeof(g_error), "AudioUnitInitialize failed: %d", (int)st);
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }

    /* Read back what the unit actually negotiated and use that. */
    AudioStreamBasicDescription asbd;
    UInt32 size = sizeof(asbd);
    memset(&asbd, 0, sizeof(asbd));
    st = AudioUnitGetProperty(g.unit, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &asbd, &size);
    if (st != noErr || asbd.mSampleRate <= 0.0) {
        size = sizeof(asbd);
        memset(&asbd, 0, sizeof(asbd));
        st = AudioUnitGetProperty(g.unit, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output, 0, &asbd, &size);
    }
    if (st != noErr || asbd.mSampleRate <= 0.0) {
        snprintf(g_error, sizeof(g_error), "StreamFormat unavailable: %d", (int)st);
        pthread_mutex_unlock(&g_init_lock);
        return 0;
    }

    g.sample_rate = asbd.mSampleRate;
    g.channels = (int)asbd.mChannelsPerFrame > 0 ? (int)asbd.mChannelsPerFrame : 2;
    if (g.channels > 2) g.channels = 2;
    g.buffer_frames = ks_get_buffer_frames(g.device);
    if (g.buffer_frames == 0) g.buffer_frames = max_slice;
    g.latency_ms = (ks_device_latency(g.device) * 1000.0) +
                   ((double)g.buffer_frames * 1000.0 / g.sample_rate);
    if (debug_on())
        fprintf(stderr, "[audio] negotiated rate=%.0f ch=%u buffer=%u latency=%.2fms\n",
                g.sample_rate, asbd.mChannelsPerFrame, g.buffer_frames, g.latency_ms);

    g.ready = 1;
    pthread_mutex_unlock(&g_init_lock);
    return 1;
}

/* The mixer, split out from the render callback so it can also be exercised
 * offline (engine_test --render) without an audio device. */
static void ks_mix(float *out, UInt32 frames, int ch) {
    memset(out, 0, (size_t)frames * (size_t)ch * sizeof(float));

    ks_drain_triggers();

    if (g.master > 0.0001f) {
        int active = 0;
        for (int v = 0; v < KS_MAX_VOICES; v++) {
            ks_voice_t *vc = &g.voices[v];
            if (!vc->active) continue;
            const float *src = vc->data;
            const unsigned int len = vc->frames;
            double pos = vc->pos;
            float gain = vc->gain;
            const float gtarget = vc->gain_target;
            const float gstep = vc->gain_step;

            for (UInt32 n = 0; n < frames; n++) {
                if (pos >= (double)len) break;
                if (gain != gtarget) {
                    gain += gstep;
                    if ((gstep > 0.0f && gain > gtarget) ||
                        (gstep < 0.0f && gain < gtarget)) gain = gtarget;
                }
                const unsigned int i0 = (unsigned int)pos;
                const double frac = pos - (double)i0;
                float s;
                if (i0 + 1 < len) s = src[i0] * (float)(1.0 - frac) + src[i0 + 1] * (float)frac;
                else              s = src[len - 1];

                const float x = s * gain * g.master;
                out[n * ch] += x;
                if (ch > 1) out[n * ch + 1] += x;
                pos += vc->step;
            }

            vc->pos = pos;
            vc->gain = gain;
            if (pos < (double)len) active++;
            else vc->active = 0;
        }
        atomic_store(&g.active_voices, active);

        /* gentle safety limiter: only act when we would actually clip */
        int clipped = 0;
        for (UInt32 n = 0; n < frames * (UInt32)ch; n++) {
            float x = out[n];
            if (x > 0.98f) { x = 0.98f + 0.02f * tanhf((x - 0.98f) / 0.02f); clipped = 1; }
            else if (x < -0.98f) { x = -0.98f - 0.02f * tanhf((-x - 0.98f) / 0.02f); clipped = 1; }
            out[n] = x;
        }
        if (clipped) g.clipped++;
    } else {
        atomic_store(&g.active_voices, 0);
    }
}

/* Render frames straight into an interleaved destination (used by tests). */
void ks_audio_render_into(float *out, unsigned int frames) {
    float stack_buf[4096 * 2];
    float *buf = (frames * 2 > sizeof(stack_buf) / sizeof(float))
        ? (float *)malloc((size_t)frames * 2 * sizeof(float))
        : stack_buf;
    if (!buf) return;
    ks_mix(buf, frames, 2);
    for (unsigned int i = 0; i < frames * 2; i++) out[i] = buf[i];
    if (buf != stack_buf) free(buf);
}

OSStatus ks_render_cb(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                      const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                      UInt32 inNumberFrames, AudioBufferList *ioData) {
    (void)inRefCon; (void)ioActionFlags; (void)inTimeStamp; (void)inBusNumber;
    g.render_calls++;
    if (debug_on() && (g.render_calls % 500) == 1)
        fprintf(stderr, "[audio] render call %llu frames=%u ch=%d rate=%.0f master=%.3f\n",
                g.render_calls, inNumberFrames, g.channels, g.sample_rate, g.master);
    if (!ioData || ioData->mNumberBuffers == 0) return noErr;
    AudioBuffer *b = &ioData->mBuffers[0];
    if (!b->mData) return noErr;

    const int ch = (g.channels > 0) ? g.channels : 2;

    UInt32 frames = inNumberFrames;
    if (b->mDataByteSize / sizeof(float) < (UInt32)(frames * ch))
        frames = b->mDataByteSize / (sizeof(float) * (UInt32)ch);
    if (frames == 0) return noErr;

    if (ch == 2) {
        ks_mix((float *)b->mData, frames, 2);
    } else {
        float tmp[4096 * 2];
        float *dst = (frames * 2 > sizeof(tmp) / sizeof(float))
            ? (float *)malloc((size_t)frames * 2 * sizeof(float))
            : tmp;
        if (dst) {
            ks_mix(dst, frames, 2);
            float *out = (float *)b->mData;
            for (UInt32 n = 0; n < frames; n++) out[n] = 0.5f * (dst[n * 2] + dst[n * 2 + 1]);
            if (dst != tmp) free(dst);
        } else {
            memset(b->mData, 0, b->mDataByteSize);
        }
    }

    return noErr;
}

/* -------------------------------------------------------------- playback */

/* Pointer to the 4-tier block for a (key-group, event), or NULL. */
static struct ks_clip_set *ks_block_for(const ks_pack_t *pack, int group, int event) {    if (!pack) return NULL;
    if (group < 0 || group >= KS_GROUP_COUNT) group = KS_GROUP_GENERIC;
    const int gi = pack->group_fallback[group];
    const int base = (gi * 2 + (event ? 1 : 0)) * KS_TIER_COUNT;
    return &((struct ks_clip_set *)pack->sets)[base];
}

/* Nearest tier that actually has clips (packs may skip a tier). */
static struct ks_clip_set *ks_pick_tier(struct ks_clip_set *block, int tier) {
    if (!block) return NULL;
    for (int i = 0; i < KS_TIER_COUNT; i++) {
        struct ks_clip_set *s = &block[(tier + i) % KS_TIER_COUNT];
        if (s->count > 0) return s;
    }
    return NULL;
}

static void ks_pick_clip(struct ks_clip_set *s, const float **data,
                         unsigned int *frames, double *rate) {
    *data = NULL; *frames = 0; *rate = 48000.0;
    if (!s || s->count <= 0) return;
    const int v = s->cursor % s->count;
    s->cursor = (s->cursor + 1) % 8;
    *data = s->data[v];
    *frames = s->frames[v];
    *rate = s->rate[v] > 0.0 ? s->rate[v] : 48000.0;
}

/* Pitch character per force tier: light touches are brighter, slams sit deeper. */
static float ks_tier_pitch(int tier) {
    switch (tier) {
        case 0: return 1.045f;
        case 1: return 1.000f;
        case 2: return 0.972f;
        case 3: return 0.940f;
        default: return 1.000f;
    }
}

static void ks_start_voice(const float *data, unsigned int frames, double src_rate,
                           float pitch, float gain) {
    if (!data || frames == 0) return;
    int idx = -1;
    for (int i = 0; i < KS_MAX_VOICES; i++) {
        int v = (g.voice_rr + i) % KS_MAX_VOICES;
        if (!g.voices[v].active) { idx = v; break; }
    }
    if (idx < 0) idx = g.voice_rr % KS_MAX_VOICES;   /* steal: pool is busy */
    g.voice_rr = (idx + 1) % KS_MAX_VOICES;

    ks_voice_t *vc = &g.voices[idx];
    const double rate = g.sample_rate > 0.0 ? g.sample_rate : 48000.0;
    vc->data = data;
    vc->frames = frames;
    vc->pos = 0.0;
    vc->step = (src_rate / rate) * (double)pitch;
    vc->gain = 0.0f;
    vc->gain_target = gain;
    const float fade = (float)KS_FADE_FRAMES;
    vc->gain_step = (gain > 0.0f) ? (gain / fade) : 0.0f;
    vc->active = 1;
    g.voices_started++;
}

static void ks_spawn_voice(const ks_trigger_t *t) {
    if (!t->pack) return;
    if (t->group < 0 || t->group >= KS_GROUP_COUNT) return;
    const int tier_lo = t->tier_lo < 0 ? 0 : (t->tier_lo >= KS_TIER_COUNT ? KS_TIER_COUNT - 1 : t->tier_lo);
    const int tier_hi = t->tier_hi < 0 ? 0 : (t->tier_hi >= KS_TIER_COUNT ? KS_TIER_COUNT - 1 : t->tier_hi);

    struct ks_clip_set *block = ks_block_for(t->pack, t->group, t->event);
    struct ks_clip_set *set_lo = ks_pick_tier(block, tier_lo);
    struct ks_clip_set *set_hi = (tier_lo == tier_hi) ? set_lo
                                                           : ks_pick_tier(block, tier_hi);

    const float *d_lo = NULL, *d_hi = NULL;
    unsigned int f_lo = 0, f_hi = 0;
    double r_lo = 48000.0, r_hi = 48000.0;
    ks_pick_clip(set_lo, &d_lo, &f_lo, &r_lo);
    ks_pick_clip(set_hi, &d_hi, &f_hi, &r_hi);

    const float mix = (t->mix < 0.0f) ? 0.0f : (t->mix > 1.0f ? 1.0f : t->mix);
    const float pitch_lo = ks_tier_pitch(tier_lo) * (1.0f + ks_jitter(0.018f));
    const float pitch_hi = ks_tier_pitch(tier_hi) * (1.0f + ks_jitter(0.018f));
    const float j = 1.0f + ks_jitter(0.05f);

    if (d_lo) {
        const float gain = (tier_lo == tier_hi)
            ? t->gain * j
            : t->gain * (1.0f - mix) * 0.85f * j;
        ks_start_voice(d_lo, f_lo, r_lo, pitch_lo, gain);
    }
    if (d_hi && tier_lo != tier_hi) {
        const float gain = t->gain * mix * 0.85f * j;
        ks_start_voice(d_hi, f_hi, r_hi, pitch_hi, gain);
    }
}

static void ks_drain_triggers(void) {
    int head = atomic_load_explicit(&g.ring_head, memory_order_acquire);
    const int tail = atomic_load_explicit(&g.ring_tail, memory_order_consume);
    if (head == tail) return;
    for (;;) {
        const int t = atomic_load_explicit(&g.ring_tail, memory_order_relaxed);
        if (t == head) break;
        ks_spawn_voice(&g.ring[t & (KS_RING_SIZE - 1)]);
        atomic_store_explicit(&g.ring_tail, t + 1, memory_order_release);
    }
    atomic_store_explicit(&g.active_voices, 0, memory_order_relaxed); /* recomputed next pass */
}

void ks_play(const ks_pack_t *pack, int group, int tier_lo, int tier_hi,
             float mix, int event, float gain) {
    if (!pack) return;
    if (!g.ready) return;
    if (!g.started) ks_audio_idle_resume();

    g.last_activity_ms = now_ms();

    pthread_mutex_lock(&g.ring_lock);
    const int head = atomic_load_explicit(&g.ring_head, memory_order_relaxed);
    const int tail = atomic_load_explicit(&g.ring_tail, memory_order_relaxed);
    if (head - tail >= KS_RING_SIZE) {
        g.dropped++;                       /* busy typing: drop rather than block */
    } else {
        ks_trigger_t *slot = &g.ring[head & (KS_RING_SIZE - 1)];
        slot->pack = pack;
        slot->group = group;
        slot->tier_lo = tier_lo;
        slot->tier_hi = tier_hi;
        slot->mix = mix;
        slot->event = event;
        slot->gain = gain;
        atomic_store_explicit(&g.ring_head, head + 1, memory_order_release);
    }
    pthread_mutex_unlock(&g.ring_lock);
}

/* --------------------------------------------------------------- controls */

void ks_audio_set_volume(float v) {
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    g.master = v;
}

float ks_audio_get_volume(void) { return g.master; }

int ks_audio_is_running(void) { return g.ready && g.started; }

double ks_audio_sample_rate(void) { return g.sample_rate > 0.0 ? g.sample_rate : 48000.0; }

int ks_audio_buffer_frames(void) { return (int)g.buffer_frames; }

double ks_audio_latency_ms(void) { return g.latency_ms; }

void ks_audio_stats(unsigned long long *voices_started,
                    unsigned long long *underruns,
                    unsigned long long *active_voices,
                    unsigned long long *render_calls) {
    if (voices_started) *voices_started = g.voices_started;
    if (underruns)      *underruns = g.dropped;
    if (active_voices)  *active_voices = (unsigned long long)atomic_load(&g.active_voices);
    if (render_calls)   *render_calls = g.render_calls;
}

void ks_audio_idle_pause(void) {
    if (!g.ready || !g.started) return;
    if (now_ms() - g.last_activity_ms < KS_IDLE_MS) return;
    AudioOutputUnitStop(g.unit);
    g.started = 0;
    g.idle_paused = 1;
}

void ks_audio_idle_resume(void) {
    if (!g.ready || g.started) return;
    OSStatus st = AudioOutputUnitStart(g.unit);
    if (st == noErr) { g.started = 1; g.idle_paused = 0; }
}

void ks_audio_shutdown(void) {
    if (g.unit) {
        if (g.started) { AudioOutputUnitStop(g.unit); g.started = 0; }
        AudioUnitUninitialize(g.unit);
        AudioComponentInstanceDispose(g.unit);
        g.unit = NULL;
    }
    if (g.device != kAudioObjectUnknown && g.has_saved_buffer) {
        ks_set_buffer_frames(g.device, g.saved_buffer_frames);
    }
    g.ready = 0;
}

int ks_audio_start(void) {
    if (!ks_audio_init()) return 0;
    OSStatus st = AudioOutputUnitStart(g.unit);
    if (st != noErr) {
        snprintf(g_error, sizeof(g_error), "AudioOutputUnitStart failed: %d", (int)st);
        return 0;
    }
    g.started = 1;
    g.idle_paused = 0;
    g.last_activity_ms = now_ms();
    return 1;
}

void ks_audio_stop(void) {
    if (g.unit && g.started) {
        AudioOutputUnitStop(g.unit);
        g.started = 0;
    }
}

