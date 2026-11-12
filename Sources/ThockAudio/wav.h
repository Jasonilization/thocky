/* wav.h - minimal RIFF/WAVE reader used to load sound-pack assets. */
#ifndef KS_WAV_H
#define KS_WAV_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float  *data;      /* mono, FLOAT32, owned by caller */
    size_t  frames;
    double  rate;      /* samples per second of the file */
} ks_wav_t;

/* Returns 1 on success, 0 on failure. Accepts PCM 16-bit and IEEE float 32/64-bit. */
int ks_wav_load(const char *path, ks_wav_t *out);
void ks_wav_free(ks_wav_t *w);

#ifdef __cplusplus
}
#endif

#endif /* KS_WAV_H */
