/* Tests the sampler core on Linux. Build and run: see ../run_tests.sh
   usage: test_core [path to skieogame.exe]  (the exe scan is skipped without it) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../patrol_snow_core.h"
#include "../patrol_snow_layouts.h"

/* Everything the tests allocate is readable; the tests also exercise the unreadable cases explicitly. */
static const void *unreadable_from, *unreadable_to;
static int readable(const void *p, size_t n) {
    if (!p) return 0;
    if (unreadable_from && (const char *)p + n > (const char *)unreadable_from && p < unreadable_to) return 0;
    return 1;
}
static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

/* A fake SnowStateCache with the layout the sampler expects: 2x2 tiles of 64x64 samples. */
typedef struct { uint8_t *cache; uint8_t *entries; uint32_t allocated[4]; float *tiles[4]; } fake_t;
static fake_t make(double x0, double y0, double x1, double y1, int ready) {
    fake_t f; memset(&f, 0, sizeof f);
    f.cache = calloc(1, 0x300); f.entries = calloc(4, 56);
    uint64_t cls = 0xC1A55; memcpy(f.cache + 0x10, &cls, 8);
    f.cache[0x1a5] = 1;
    double b[4] = {x0, y0, x1, y1}; memcpy(f.cache + 0xe8, b, 32);
    int32_t tiles = 2; memcpy(f.cache + 0x10c, &tiles, 4);
    int32_t n = 4, cap = 8, bits = 4; memcpy(f.cache + 0x50, &n, 4); memcpy(f.cache + 0x54, &cap, 4); memcpy(f.cache + 0x70, &bits, 4);
    memcpy(f.cache + 0x48, &f.entries, 8);
    uint32_t *inline_bits = (uint32_t *)(f.cache + 0x58); inline_bits[0] = 0xF;   /* all four allocated, bits pointer left null */
    for (int t = 0; t < 4; t++) {
        f.tiles[t] = calloc(4096, 32);
        for (int p = 0; p < 4096; p++) { f.tiles[t][p * 8] = (t == 3) ? 0.f : 100.f; f.tiles[t][p * 8 + 1] = 20.f; }   /* tile 3 is bare */
        uint8_t *e = f.entries + t * 56; int32_t key[2] = {t % 2, t / 2}; memcpy(e, key, 8);
        memcpy(e + 8, &f.tiles[t], 8); int32_t len = 4096; memcpy(e + 16, &len, 4); e[0x28] = (uint8_t)ready;
    }
    return f;
}

int main(int argc, char **argv) {
    /* 1. depth lookup */
    fake_t f = make(0, 0, 25600, 25600, 1);           /* 128x128 cells of 200 cm; tile edge at 12800 */
    double xy[6] = {1000, 1000,  20000, 1000,  20000, 20000};
    float out[3][4];
    const char *e = sample_snow(f.cache, 0xC1A55, xy, 3, out);
    CHECK(!e, "unexpected error %s", e ? e : "");
    CHECK(out[0][0] == 1 && out[0][1] == 100 && out[0][2] == 20, "tile 0: %g %g %g", out[0][0], out[0][1], out[0][2]);
    CHECK(out[1][0] == 1 && out[1][1] == 100, "tile 1");
    CHECK(out[2][0] == 1 && out[2][1] == 0 && out[2][2] == 20, "bare tile 3 reads 0 cm packed: %g", out[2][1]);
    CHECK(out[0][3] == 200, "cell size %g", out[0][3]);
    /* 2. refusals */
    double outside[2] = {-5, 10}; e = sample_snow(f.cache, 0xC1A55, outside, 1, out);
    CHECK(!e && out[0][0] == 0, "outside the map is not ready");
    CHECK(sample_snow(f.cache, 0xBAD, xy, 1, out) != 0, "wrong class refused");
    f.cache[0x1a5] = 0; CHECK(sample_snow(f.cache, 0xC1A55, xy, 1, out) != 0, "invalid cache refused"); f.cache[0x1a5] = 1;
    f.entries[0x28] = 0; e = sample_snow(f.cache, 0xC1A55, xy, 1, out); CHECK(!e && out[0][0] == 0, "tile not ready => not ready"); f.entries[0x28] = 1;
    int32_t n = 5000; memcpy(f.cache + 0x50, &n, 4); CHECK(sample_snow(f.cache, 0xC1A55, xy, 1, out) != 0, "absurd tile count refused"); n = 4; memcpy(f.cache + 0x50, &n, 4);
    double nan_xy[2] = {0.0 / 0.0 * 0 + __builtin_nan(""), 1}; e = sample_snow(f.cache, 0xC1A55, nan_xy, 1, out); CHECK(!e && out[0][0] == 0, "NaN point not ready");
    float bad = __builtin_nanf(""); f.tiles[0][0] = bad; double p0[2] = {10, 10}; e = sample_snow(f.cache, 0xC1A55, p0, 1, out); CHECK(!e && out[0][0] == 0, "NaN sample not ready");
    unreadable_from = f.tiles[1]; unreadable_to = (char *)f.tiles[1] + 4096 * 32;
    double p1[2] = {20000, 1000}; e = sample_snow(f.cache, 0xC1A55, p1, 1, out); CHECK(!e && out[0][0] == 0, "unreadable tile data not read");
    unreadable_from = unreadable_to = NULL;
    CHECK(sample_snow(NULL, 0xC1A55, xy, 1, out) != 0, "null cache refused");

    /* 3. fingerprints: they must not match random data, and must match the real game */
    uint8_t *junk = calloc(1, 4096);
    const uint8_t *r[1] = {junk}; size_t sz[1] = {4096};
    CHECK(layouts_supported(layouts, 4, r, sz, 1) == 1, "junk matches nothing");
    if (argc > 1) {
        FILE *fh = fopen(argv[1], "rb"); if (!fh) { printf("cannot open %s\n", argv[1]); return 2; }
        fseek(fh, 0, SEEK_END); long size = ftell(fh); fseek(fh, 0, SEEK_SET);
        uint8_t *exe = malloc(size); if (fread(exe, 1, size, fh) != (size_t)size) return 2; fclose(fh);
        /* .text of the CL8198 exe: raw offset 0x600, size 0x82954fc */
        const uint8_t *tr[1] = {exe + 0x600}; size_t ts[1] = {0x82954fc};
        int bad = layouts_supported(layouts, 4, tr, ts, 1);
        CHECK(bad == 0, "the real game's code was not recognised (routine %d)", bad);
        /* a one-byte change inside a fingerprinted, unmasked area must break it */
        uint8_t *copy = malloc(0x82954fc); memcpy(copy, tr[0], 0x82954fc);
        for (unsigned i = 0; i < 0x82954fc - 16; i++)
            if (!memcmp(copy + i, layouts[0].prefix, layouts[0].prefix_size) && fingerprint_matches(&layouts[0], copy + i)) { copy[i + 3] ^= 1; break; }
        const uint8_t *cr[1] = {copy};
        CHECK(layouts_supported(layouts, 4, cr, ts, 1) == 1, "a changed routine is refused");
        printf("game exe scanned: %s\n", bad == 0 ? "all four routines recognised" : "NOT recognised");
    }
    printf(failures ? "%d FAILED\n" : "ok: all sampler tests passed\n", failures);
    return failures != 0;
}
