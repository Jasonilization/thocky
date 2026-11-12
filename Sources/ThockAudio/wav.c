/* wav.c - minimal RIFF/WAVE reader (PCM 16-bit + IEEE float 32/64). */
#include "wav.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int rd_u32le(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}

static unsigned int rd_u16le(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8);
}

int ks_wav_load(const char *path, ks_wav_t *out) {
    if (!path || !out) return 0;
    memset(out, 0, sizeof(*out));

    FILE *f = fopen(path, "rb");
    if (!f) return 0;

    unsigned char hdr[12];
    if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) != 0 ||
        memcmp(hdr + 8, "WAVE", 4) != 0) {
        fclose(f);
        return 0;
    }

    unsigned int fmt_tag = 0, channels = 0, bits = 0;
    double rate = 0.0;
    unsigned char *payload = NULL;
    size_t payload_len = 0;

    for (;;) {
        unsigned char ch[8];
        if (fread(ch, 1, 8, f) != 8) break;
        unsigned int id = rd_u32le(ch);
        size_t size = rd_u32le(ch + 4);

        if (id == 0x20746d66u) { /* "fmt " */
            unsigned char fmt[64];
            size_t want = size < sizeof(fmt) ? size : sizeof(fmt);
            if (fread(fmt, 1, want, f) != want) { fclose(f); free(payload); return 0; }
            if (size > want) fseek(f, (long)(size - want), SEEK_CUR);
            fmt_tag = rd_u16le(fmt);
            channels = rd_u16le(fmt + 2);
            rate = (double)rd_u32le(fmt + 4);
            bits = rd_u16le(fmt + 14);
        } else if (id == 0x61746164u) { /* "data" */
            payload = (unsigned char *)malloc(size ? size : 1);
            if (!payload) { fclose(f); return 0; }
            payload_len = fread(payload, 1, size, f);
            if (payload_len == 0) { free(payload); fclose(f); return 0; }
        } else {
            if (size & 1u) size++;
            if (fseek(f, (long)size, SEEK_CUR) != 0) break;
        }
    }
    fclose(f);

    if (!payload || channels == 0 || channels > 8 || rate <= 0.0) {
        free(payload);
        return 0;
    }

    size_t bytes_per_frame = (size_t)(bits / 8) * channels;
    if (bytes_per_frame == 0) { free(payload); return 0; }
    size_t frames = payload_len / bytes_per_frame;
    if (frames == 0) { free(payload); return 0; }

    float *out_buf = (float *)calloc(frames, sizeof(float));
    if (!out_buf) { free(payload); return 0; }

    const unsigned char *p = payload;
    double inv;
    int float_fmt = (fmt_tag == 3u); /* IEEE float */

    switch (bits) {
        case 16:
            inv = 1.0 / 32768.0;
            for (size_t i = 0; i < frames * channels; i++) {
                int v = (int)(short)rd_u16le(p + i * 2);
                out_buf[i / channels] += (float)(v * inv); /* accumulate; divided below */
            }
            break;
        case 24: {
            inv = 1.0 / 8388608.0;
            for (size_t i = 0; i < frames * channels; i++) {
                const unsigned char *q = p + i * 3;
                int v = (int)((unsigned)q[0] | ((unsigned)q[1] << 8) | ((unsigned)q[2] << 16));
                if (v & 0x800000) v |= ~0xFFFFFF; /* sign extend */
                out_buf[i / channels] += (float)(v * inv);
            }
            break;
        }
        case 32:
            if (float_fmt) {
                for (size_t i = 0; i < frames * channels; i++) {
                    unsigned int b = rd_u32le(p + i * 4);
                    float v; memcpy(&v, &b, 4);
                    out_buf[i / channels] += v;
                }
            } else {
                inv = 1.0 / 2147483648.0;
                for (size_t i = 0; i < frames * channels; i++) {
                    int v = (int)rd_u32le(p + i * 4);
                    out_buf[i / channels] += (float)(v * inv);
                }
            }
            break;
        case 64:
            if (float_fmt) {
                for (size_t i = 0; i < frames * channels; i++) {
                    unsigned long long b = 0;
                    for (int k = 7; k >= 0; k--) b = (b << 8) | p[i * 8 + k];
                    double v; memcpy(&v, &b, 8);
                    out_buf[i / channels] += (float)v;
                }
            } else {
                inv = 1.0 / 9223372036854775808.0;
                for (size_t i = 0; i < frames * channels; i++) {
                    unsigned long long b = 0;
                    for (int k = 7; k >= 0; k--) b = (b << 8) | p[i * 8 + k];
                    long long v = (long long)b;
                    out_buf[i / channels] += (float)((double)v * inv);
                }
            }
            break;
        default:
            free(out_buf); free(payload);
            return 0;
    }

    free(payload);
    if (channels > 1) {
        float inv_ch = 1.0f / (float)channels;
        for (size_t i = 0; i < frames; i++) out_buf[i] *= inv_ch;
    }

    out->data = out_buf;
    out->frames = (unsigned int)frames;
    out->rate = rate;
    return 1;
}

void ks_wav_free(ks_wav_t *w) {
    if (!w) return;
    free(w->data);
    w->data = NULL;
    w->frames = 0;
    w->rate = 0.0;
}
