/* Snow depth sampler core for the Ski patrol mod: pure logic, no Windows calls, so it also runs in the
   Linux tests. Reads the game's asynchronously refreshed CPU snow tiles (the SnowStateCache object) without
   touching the GPU, and only after four exact code fingerprints of the game executable match.

   Derived from skieo_sample_snow in skieomod's native/SkiEONativeTerrain/native_terrain.c
   (BSD-3-Clause, Copyright (c) 2026, Ayane; see LICENSE-skieomod), reduced to the one game layout this mod
   supports (56-byte tile map entries, readiness flag at +0x28). Everything is read-only. */
#ifndef PATROL_SNOW_CORE_H
#define PATROL_SNOW_CORE_H
#include <stdint.h>
#include <stddef.h>

typedef struct { uint16_t offset, size; } mask_t;
typedef struct {
    const uint8_t *prefix;
    uint16_t prefix_size, code_size;
    const mask_t *masks;
    uint16_t mask_count;
    uint64_t fingerprint;
} layout_t;

/* Supplied by the includer: 1 when [p, p+n) can be read without faulting. */
static int readable(const void *p, size_t n);

static int ps_memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}
static void ps_memcpy(void *d, const void *s, size_t n) {
    uint8_t *x = d; const uint8_t *y = s;
    for (size_t i = 0; i < n; i++) x[i] = y[i];
}
static int fin_d(double v) { return v == v && v - v == 0; }
static int fin_f(float v) { return v == v && v - v == 0; }

static int fingerprint_matches(const layout_t *l, const uint8_t *code) {
    uint64_t h = UINT64_C(14695981039346656037);
    unsigned mi = 0;
    for (unsigned i = 0; i < l->code_size; i++) {
        while (mi < l->mask_count && i >= (unsigned)l->masks[mi].offset + l->masks[mi].size) mi++;
        uint8_t v = (mi < l->mask_count && i >= l->masks[mi].offset) ? 0 : code[i];
        h = (h ^ v) * UINT64_C(1099511628211);
    }
    return h == l->fingerprint;
}

/* Counts the places in [code, code+size) where the layout matches (stops at 2). */
static unsigned scan_layout(const layout_t *l, const uint8_t *code, size_t size) {
    if (size < l->code_size) return 0;
    unsigned count = 0;
    size_t limit = size - l->code_size + 1;
    uint8_t first = l->prefix[0], second = l->prefix_size > 1 ? l->prefix[1] : 0;
    for (size_t i = 0; i < limit; i++) {
        if (code[i] != first) continue;
        if (l->prefix_size > 1 && code[i + 1] != second) continue;
        if (ps_memcmp(code + i, l->prefix, l->prefix_size) == 0 && fingerprint_matches(l, code + i))
            if (++count == 2) return count;
    }
    return count;
}

/* Each of the four routines must appear exactly once across the given code ranges. 0 = layout supported. */
static int layouts_supported(const layout_t *layouts, unsigned n, const uint8_t *const *ranges,
                             const size_t *sizes, unsigned range_count) {
    for (unsigned i = 0; i < n; i++) {
        unsigned total = 0;
        for (unsigned r = 0; r < range_count && total < 2; r++) total += scan_layout(&layouts[i], ranges[r], sizes[r]);
        if (total != 1) return 1 + (int)i;   /* which one failed, 1-based */
    }
    return 0;
}

#define SNOW_MAX_SAMPLES 64
/* One result per sample: {ready, packed cm, fresh cm, cell size cm}. Returns an error string, or 0 when the
   cache was read (individual points may still be not ready). */
static const char *sample_snow(const uint8_t *cache, uint64_t expected_class, const double *xy, unsigned count,
                               float out[][4]) {
    const unsigned stride = 56, ready_offset = 0x28;
    for (unsigned i = 0; i < count; i++) { out[i][0] = out[i][1] = out[i][2] = out[i][3] = 0; }
    if (!cache || !readable(cache, 0x2a0)) return "snow cache not readable";
    uint64_t cls; ps_memcpy(&cls, cache + 0x10, 8);
    if (cls != expected_class) return "snow cache class mismatch";
    if (!cache[0x1a5]) return "snow cache not valid yet";
    double bounds[4]; ps_memcpy(bounds, cache + 0xe8, 32);
    int32_t tiles; ps_memcpy(&tiles, cache + 0x10c, 4);
    if (tiles < 1 || tiles > 128 || !fin_d(bounds[0]) || !fin_d(bounds[1]) || !fin_d(bounds[2]) || !fin_d(bounds[3])
        || bounds[2] <= bounds[0] || bounds[3] <= bounds[1]) return "snow cache bounds invalid";
    const uint8_t *entries; int32_t n, capacity, bits; const uint32_t *allocated;
    ps_memcpy(&entries, cache + 0x48, 8); ps_memcpy(&n, cache + 0x50, 4); ps_memcpy(&capacity, cache + 0x54, 4);
    ps_memcpy(&bits, cache + 0x70, 4); ps_memcpy(&allocated, cache + 0x68, 8);
    if (!allocated) allocated = (const uint32_t *)(cache + 0x58);
    if (n < 0 || n > 2048 || capacity < n || capacity > 4096 || bits < n || bits > 4096
        || !readable(entries, (size_t)n * stride) || !readable(allocated, ((size_t)bits + 31) / 32 * 4))
        return "snow tile map invalid";
    for (unsigned s = 0; s < count; s++) {
        double x = xy[s * 2], y = xy[s * 2 + 1];
        if (!fin_d(x) || !fin_d(y)) continue;
        double gx = (x - bounds[0]) / (bounds[2] - bounds[0]) * tiles * 64;
        double gy = (y - bounds[1]) / (bounds[3] - bounds[1]) * tiles * 64;
        if (gx < 0 || gy < 0 || gx >= tiles * 64 || gy >= tiles * 64) continue;
        int32_t ix = (int32_t)gx, iy = (int32_t)gy, tx = ix / 64, ty = iy / 64;   /* gx, gy >= 0: truncation = floor */
        for (int32_t i = 0; i < n; i++) {
            if (!(allocated[i / 32] & (1U << (i % 32)))) continue;
            const uint8_t *entry = entries + (size_t)i * stride;
            int32_t key[2], length; const float *samples;
            ps_memcpy(key, entry, 8);
            if (key[0] != tx || key[1] != ty) continue;
            ps_memcpy(&samples, entry + 8, 8); ps_memcpy(&length, entry + 16, 4);
            if (length != 4096 || !entry[ready_offset] || !readable(samples, 4096 * 32)) break;
            const float *pixel = (const float *)((const uint8_t *)samples + ((iy % 64) * 64 + ix % 64) * 32);
            if (fin_f(pixel[0]) && fin_f(pixel[1]) && pixel[0] >= 0 && pixel[1] >= 0 && pixel[0] + pixel[1] < 10000) {
                out[s][0] = 1; out[s][1] = pixel[0]; out[s][2] = pixel[1];
                out[s][3] = (float)((bounds[2] - bounds[0]) / (tiles * 64));
            }
            break;
        }
    }
    return 0;
}
#endif
