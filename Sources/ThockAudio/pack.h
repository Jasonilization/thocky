/* pack.h - a sound pack: every (group, event, tier, variant) clip the engine can play. */
#ifndef KS_PACK_H
#define KS_PACK_H

#include <stddef.h>
#include "../include/audio_engine.h"

/* One (key-group, event, force-tier) slot; holds 1..KS_MAX_VARIANTS recordings. */
struct ks_clip_set {
    int          count;
    int          cursor;                          /* round-robin variant picker */
    float       *data[KS_MAX_VARIANTS];
    unsigned int frames[KS_MAX_VARIANTS];
    double       rate[KS_MAX_VARIANTS];
};

struct ks_pack {
    char   dir[1024];
    int    group_fallback[KS_GROUP_COUNT];  /* group -> index actually holding clips */
    int    total_clips;
    int    refcount;
    struct ks_clip_set *sets;               /* KS_GROUP_COUNT * 2 * KS_TIER_COUNT */
};

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
}
#endif

#endif /* KS_PACK_H */
