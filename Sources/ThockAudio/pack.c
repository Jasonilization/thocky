/* pack.c - load a sound-pack directory into RAM-resident float buffers. */
#include "pack.h"
#include "wav.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *k_group_names[KS_GROUP_COUNT] = {
    "generic", "enter", "space", "backspace"
};
static const char *k_event_names[2] = { "press", "release" };

/* ---------------------------------------------------------------- pack cache */

#define KS_CACHE_MAX 8
static struct ks_pack *g_cache[KS_CACHE_MAX];
static int g_cache_limit = 4;

void ks_pack_cache_set_limit(int packs) {
    if (packs < 0) packs = 0;
    if (packs > KS_CACHE_MAX) packs = KS_CACHE_MAX;
    g_cache_limit = packs;
}

static void ks_pack_destroy(struct ks_pack *p) {
    if (!p) return;
    if (p->sets) {
        int n = KS_GROUP_COUNT * 2 * KS_TIER_COUNT;
        for (int i = 0; i < n; i++) {
            struct ks_clip_set *s = &p->sets[i];
            for (int v = 0; v < s->count; v++) free(s->data[v]);
        }
        free(p->sets);
    }
    free(p);
}

void ks_pack_cache_clear(void) {
    for (int i = 0; i < KS_CACHE_MAX; i++) {
        if (g_cache[i] && g_cache[i]->refcount <= 0) {
            ks_pack_destroy(g_cache[i]);
            g_cache[i] = NULL;
        }
    }
}

/* ------------------------------------------------------------------- loading */

/* Variant numbering is not guaranteed to start at zero - some upstream packs
 * number their recordings 1..n - so probe a generous range and keep whatever
 * exists, packed contiguously. */
#define KS_VARIANT_SCAN 24

static int load_clip_set(const char *dir, const char *group, int event, int tier,
                         struct ks_clip_set *out) {
    char path[2048];
    memset(out, 0, sizeof(*out));

    for (int v = 0; v < KS_VARIANT_SCAN && out->count < KS_MAX_VARIANTS; v++) {
        ks_wav_t w;
        int loaded = 0;

        /* preferred: <group>_<press|release>_t<tier>_v<n>.wav */
        snprintf(path, sizeof(path), "%s/%s_%s_t%d_v%d.wav",
                 dir, group, k_event_names[event], tier, v);
        loaded = ks_wav_load(path, &w);

        /* single-variant packs: <group>_<press|release>_t<tier>.wav */
        if (!loaded && v == 0) {
            snprintf(path, sizeof(path), "%s/%s_%s_t%d.wav",
                     dir, group, k_event_names[event], tier);
            loaded = ks_wav_load(path, &w);
        }
        if (!loaded) continue;

        out->data[out->count] = w.data;
        out->frames[out->count] = (unsigned int)w.frames;
        out->rate[out->count] = w.rate;
        out->count++;
    }
    return out->count;
}

ks_pack_t *ks_pack_load(const char *dir) {
    if (!dir || !dir[0]) return NULL;

    /* cached? */
    for (int i = 0; i < KS_CACHE_MAX; i++) {
        if (g_cache[i] && strcmp(g_cache[i]->dir, dir) == 0) {
            g_cache[i]->refcount++;
            return g_cache[i];
        }
    }

    struct ks_pack *p = (struct ks_pack *)calloc(1, sizeof(*p));
    if (!p) return NULL;
    snprintf(p->dir, sizeof(p->dir), "%s", dir);
    p->refcount = 1;
    p->sets = (struct ks_clip_set *)calloc((size_t)(KS_GROUP_COUNT * 2 * KS_TIER_COUNT),
                                           sizeof(struct ks_clip_set));
    if (!p->sets) { free(p); return NULL; }

    for (int g = 0; g < KS_GROUP_COUNT; g++) {
        for (int e = 0; e < 2; e++) {
            for (int t = 0; t < KS_TIER_COUNT; t++) {
                struct ks_clip_set *s =
                    &p->sets[(g * 2 + e) * KS_TIER_COUNT + t];
                load_clip_set(dir, k_group_names[g], e, t, s);
                if (s->count > 0) p->total_clips += s->count;
            }
        }
    }
    if (p->total_clips == 0) {
        ks_pack_destroy(p);
        return NULL;
    }

    /* fall back to the generic set for key groups this pack does not record */
    for (int g = 0; g < KS_GROUP_COUNT; g++) {
        int any = 0;
        for (int e = 0; e < 2; e++)
            for (int t = 0; t < KS_TIER_COUNT; t++)
                if (p->sets[(g * 2 + e) * KS_TIER_COUNT + t].count > 0) any = 1;
        p->group_fallback[g] = any ? g : KS_GROUP_GENERIC;
    }

    for (int i = 0; i < KS_CACHE_MAX; i++) {
        if (!g_cache[i]) {
            if (g_cache_limit > 0) { g_cache[i] = p; return p; }
            return p;
        }
    }
    /* cache full: evict an unreferenced pack */
    for (int i = 0; i < KS_CACHE_MAX; i++) {
        if (g_cache[i]->refcount <= 0) { ks_pack_destroy(g_cache[i]); g_cache[i] = p; return p; }
    }
    return p; /* keep it live but uncached */
}

void ks_pack_release(ks_pack_t *p) {
    if (!p) return;
    if (p->refcount > 0) p->refcount--;
    if (p->refcount > 0) return;
    for (int i = 0; i < KS_CACHE_MAX; i++) {
        if (g_cache[i] == p) return; /* still cached, keep resident */
    }
    ks_pack_destroy(p);
}

int ks_pack_clip_count(const ks_pack_t *p) { return p ? p->total_clips : 0; }
