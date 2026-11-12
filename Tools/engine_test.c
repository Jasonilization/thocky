/* engine_test.c - smoke test for the Core Audio engine.
 *
 *   make test-audio  PACK=Resources/Packs/cream                  # live playback
 *   make test-offline PACK=Resources/Packs/cream                  # render to WAV
 *
 * The offline path exercises the same mixer without an audio device, so the
 * DSP (voice scheduling, resampling pitch, tier crossfade, limiter) can be
 * validated on any machine.
 */

#include "audio_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void write_le16(FILE *f, int v) {
    unsigned char b[2] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF) };
    fwrite(b, 1, 2, f);
}
static void write_le32(FILE *f, unsigned int v) {
    unsigned char b[4] = { (unsigned char)(v & 0xFF), (unsigned char)((v >> 8) & 0xFF),
                           (unsigned char)((v >> 16) & 0xFF), (unsigned char)((v >> 24) & 0xFF) };
    fwrite(b, 1, 4, f);
}

/* Render a scripted keystroke pattern to a 16-bit stereo WAV. */
static int render_offline(const char *dir, const char *out, double seconds) {
    if (!ks_audio_init()) {
        fprintf(stderr, "audio init failed: %s\n", ks_audio_error());
        return 1;
    }
    ks_pack_t *p = ks_pack_load(dir);
    if (!p) { fprintf(stderr, "pack load failed: %s\n", dir); return 1; }

    const int rate = (int)ks_audio_sample_rate();
    const long long total = (long long)(seconds * rate);
    const int block = 128;

    FILE *f = fopen(out, "wb");
    if (!f) { perror("open output"); return 1; }
    /* 44-byte stereo header; sizes patched at the end */
    fwrite("RIFF", 1, 4, f); write_le32(f, 0); fwrite("WAVEfmt ", 1, 8, f);
    write_le32(f, 16); write_le16(f, 1); write_le16(f, 2);
    write_le32(f, (unsigned int)rate); write_le32(f, (unsigned int)rate * 4);
    write_le16(f, 4); write_le16(f, 16);
    fwrite("data", 1, 4, f); write_le32(f, 0);
    long data_bytes = 0;

    struct { int tier; int group; int event; int at; } script[64];
    int n_script = 0;
    srand(11);
    int t = 0;
    while (n_script < 60 && t < total - rate / 4) {
        int lo = rand() % 4, hi = rand() % 4;
        if (hi < lo) { int tmp = lo; lo = hi; hi = tmp; }
        script[n_script].tier = lo;
        script[n_script].group = (int[]){ 0, 1, 2, 3 }[rand() % 4];
        script[n_script].event = 0;
        script[n_script].at = t;
        n_script++;
        if (rand() % 3 == 0) {  /* a release shortly after */
            script[n_script].tier = hi;
            script[n_script].group = script[n_script - 1].group;
            script[n_script].event = 1;
            script[n_script].at = t + rate / 40;
            n_script++;
        }
        t += rate / 8 + (rand() % 3) * (rate / 4);
    }

    float *buf = (float *)malloc((size_t)block * 2 * sizeof(float));
    long long triggered = 0;
    for (long long done = 0; done < total; done += block) {
        long long now = done;
        for (int i = 0; i < n_script; i++) {
            if (script[i].at >= now && script[i].at < now + block) {
                int tier = script[i].tier;
                ks_play(p, script[i].group, tier, tier, 0.0f, script[i].event, 1.0f);
                triggered++;
            }
        }
        ks_audio_render_into(buf, block);
        for (int i = 0; i < block * 2; i++) {
            float x = buf[i];
            if (x > 1) x = 1; if (x < -1) x = -1;
            write_le16(f, (int)(x * 32767));
        }
        data_bytes += block * 4;
    }
    free(buf);
    fseek(f, 0x28, SEEK_SET); write_le32(f, (unsigned int)data_bytes);
    fseek(f, 4, SEEK_SET);    write_le32(f, (unsigned int)(36 + data_bytes));
    fclose(f);

    unsigned long long voices = 0, dropped = 0, active = 0, renders = 0;
    ks_audio_stats(&voices, &dropped, &active, &renders);
    printf("offline render: %s  %lld samples @ %d Hz  scripted=%d triggered=%lld voices=%llu dropped=%llu renders=%llu\n",
           out, total, rate, n_script, triggered, voices, dropped, renders);
    ks_pack_release(p);
    return 0;
}

int main(int argc, char **argv) {
    const char *dir = "Resources/Packs/cream";
    const char *dir2 = NULL;
    double seconds = 6.0;
    int offline = 0;
    const char *out = "/tmp/thock_offline.wav";

    int dir_set = 0, dir2_set = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--render") == 0) offline = 1;
        else if (strncmp(argv[i], "--seconds=", 10) == 0) seconds = atof(argv[i] + 10);
        else if (strncmp(argv[i], "--out=", 6) == 0) out = argv[i] + 6;
        else if (!dir_set) { dir = argv[i]; dir_set = 1; }
        else if (!dir2_set) { dir2 = argv[i]; dir2_set = 1; }
    }

    if (offline) return render_offline(dir, out, seconds);

    if (!ks_audio_start()) {
        fprintf(stderr, "audio init failed: %s\n", ks_audio_error());
        return 1;
    }
    printf("engine: rate=%.0fHz buffer=%d latency=%.2fms\n",
           ks_audio_sample_rate(), ks_audio_buffer_frames(), ks_audio_latency_ms());

    ks_pack_t *p1 = ks_pack_load(dir);
    if (!p1) { fprintf(stderr, "pack load failed: %s\n", dir); return 1; }
    printf("pack %s: %d clips\n", dir, ks_pack_clip_count(p1));
    ks_pack_t *p2 = dir2 ? ks_pack_load(dir2) : NULL;
    if (p2) printf("pack %s: %d clips\n", dir2, ks_pack_clip_count(p2));

    static const char *tiers[4] = { "soft", "medium", "hard", "slam" };
    for (int t = 0; t < 4; t++) {
        printf("  %s\n", tiers[t]);
        ks_play(p1, KS_GROUP_GENERIC, t, t, 0.0f, KS_EVENT_PRESS, 1.0f);
        usleep(260000);
        ks_play(p1, KS_GROUP_GENERIC, t, t, 0.0f, KS_EVENT_RELEASE, 0.5f);
        usleep(340000);
    }

    printf("  typing burst\n");
    srand(7);
    for (int i = 0; i < 24; i++) {
        int lo = rand() % 4, hi = rand() % 4;
        if (hi < lo) { int tmp = lo; lo = hi; hi = tmp; }
        float mix = (hi > lo) ? (float)(rand() % 100) / 100.0f : 0.0f;
        int group = (int[]){ 0, 1, 2, 3 }[rand() % 4];
        ks_play(p1, group, lo, hi, mix, KS_EVENT_PRESS, 1.0f);
        if (i % 3 == 0) ks_play(p1, group, lo, hi, 0.0f, KS_EVENT_RELEASE, 0.45f);
        usleep(60000 + (rand() % 90) * 1000);
    }

    if (p2) {
        printf("  second pack (cache check)\n");
        for (int i = 0; i < 6; i++) {
            ks_play(p2, KS_GROUP_GENERIC, i % 4, i % 4, 0.0f, KS_EVENT_PRESS, 1.0f);
            usleep(150000);
        }
        ks_play(p1, KS_GROUP_GENERIC, 3, 3, 0.0f, KS_EVENT_PRESS, 1.0f);
        usleep(200000);
        ks_pack_release(p2);
    }

    unsigned long long voices = 0, dropped = 0, active = 0, renders = 0;
    ks_audio_stats(&voices, &dropped, &active, &renders);
    printf("stats: voices=%llu dropped=%llu active=%llu renders=%llu\n", voices, dropped, active, renders);

    ks_pack_release(p1);
    ks_audio_shutdown();
    printf("done\n");
    return 0;
}
