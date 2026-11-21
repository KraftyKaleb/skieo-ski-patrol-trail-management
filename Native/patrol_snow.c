// PatrolSnow.dll - Ski patrol (Ski-E-O!, UE4SS): reads the snow depth under points on a run.
//
// Lua can't read the game's snow, so the patrol's thin-snow rule calls this DLL:
//   package.loadlib(<mod>\Native\PatrolSnow.dll, "patrol_snow")()
// It takes no arguments and returns nothing; the job and the answer go through three small files in
// %LOCALAPPDATA%, named like the mod's other saved files: Ski-E-O-Mod-<mod folder>-snow.job / .bin / .status.
//   .job    "SKSN", u32 2, u64 SnowStateCache address, u64 its class address, u32 count (1..64), u32 0,
//           then count x (f64 x, f64 y)   - world position in cm
//   .bin    per point 4 x f32: ready (1 or 0), packed cm, fresh cm, cell size cm
//   .status one line: "ok" or why the sampler is off (it is written when it changes)
// It only READS the game's memory, only on the game thread, and only after four exact fingerprints of the
// game's own snow cache routines match this game build (patrol_snow_layouts.h). On any other build it answers
// "unsupported" and the patrol's thin-snow rule stays off; nothing in the game is changed.
//
// Derived from skieomod's native snow sampler (BSD-3-Clause, Ayane): see LICENSE-skieomod.
//
// Build (from this folder; the same recipe as the other SkiEO mods' DLLs):
//   clang --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -fno-builtin
//         -mno-stack-arg-probe -c patrol_snow.c
//   llvm-dlltool -m i386:x86-64 -d kernel32.def -l kernel32.lib
//   lld-link /dll /nodefaultlib /entry:DllMain /out:PatrolSnow.dll patrol_snow.obj kernel32.lib
#include "patrol_snow_core.h"
#include "patrol_snow_layouts.h"

typedef unsigned short wch;
typedef unsigned int u32;
typedef void *HANDLE;
typedef int BOOL;

typedef struct {
    void *BaseAddress, *AllocationBase;
    u32 AllocationProtect; u32 PartitionPad;
    size_t RegionSize;
    u32 State, Protect, Type, Pad;
} MBI;

#define W __declspec(dllimport)
W void *__stdcall GetModuleHandleW(const wch *);
W u32 __stdcall GetModuleFileNameW(HANDLE, wch *, u32);
W u32 __stdcall GetEnvironmentVariableW(const wch *, wch *, u32);
W size_t __stdcall VirtualQuery(const void *, MBI *, size_t);
W HANDLE __stdcall CreateFileW(const wch *, u32, u32, void *, u32, u32, HANDLE);
W BOOL __stdcall ReadFile(HANDLE, void *, u32, u32 *, void *);
W BOOL __stdcall WriteFile(HANDLE, const void *, u32, u32 *, void *);
W BOOL __stdcall CloseHandle(HANDLE);
W BOOL __stdcall DeleteFileW(const wch *);

int _fltused = 0;                                   // the linker asks for this when floating point is used without the C runtime
static HANDLE g_self;
BOOL __stdcall DllMain(HANDLE h, u32 reason, void *r) {
    (void)r;
    if (reason == 1) g_self = h;                    // DLL_PROCESS_ATTACH
    return 1;
}

// The compiler may turn loops into these even with -fno-builtin.
void *memset(void *d, int c, size_t n) { volatile uint8_t *p = d; while (n--) *p++ = (uint8_t)c; return d; }
void *memcpy(void *d, const void *s, size_t n) {
    volatile uint8_t *p = d; const uint8_t *q = s; while (n--) *p++ = *q++; return d;
}

// 1 when [p, p+n) is committed, readable memory (not a guard page).
static int readable(const void *p, size_t n) {
    if (!p) return 0;
    if (!n) return 1;
    const uint8_t *cur = p;
    size_t left = n;
    while (left) {
        MBI m;
        if (VirtualQuery(cur, &m, sizeof(m)) < sizeof(m)) return 0;
        if (m.State != 0x1000) return 0;                                   // MEM_COMMIT
        if (m.Protect & 0x101) return 0;                                   // PAGE_NOACCESS, PAGE_GUARD
        if (!(m.Protect & 0xEE)) return 0;                                 // some read right
        size_t avail = (size_t)((const uint8_t *)m.BaseAddress + m.RegionSize - cur);
        if (avail >= left) return 1;
        cur += avail; left -= avail;
    }
    return 1;
}

#define BUF 1024
static wch g_dir[BUF], g_id[260];                  // %LOCALAPPDATA%, the mod's folder name
static int g_paths = -1;
static int g_support = -1;                         // -1 not checked, 0 supported, else which routine failed
static char g_status[96];
static char g_written[96];

static int find_paths(void) {
    if (g_paths >= 0) return g_paths;
    g_paths = 0;
    u32 n = GetEnvironmentVariableW(L"LOCALAPPDATA", g_dir, BUF - 64);
    if (!n || n >= BUF - 64) return 0;
    // .../mods/<id>/Native/PatrolSnow.dll -> <id>
    wch path[BUF];
    u32 len = GetModuleFileNameW(g_self, path, BUF);
    if (!len || len >= BUF) return 0;
    int end = (int)len, starts[3], found = 0;
    for (int i = end - 1; i >= 0 && found < 3; i--)
        if (path[i] == '\\' || path[i] == '/') starts[found++] = i;
    if (found < 3) return 0;
    int a = starts[2] + 1, b = starts[1];            // the folder two levels above the DLL's file name
    if (b - a <= 0 || b - a >= 250) return 0;
    for (int i = 0; i < b - a; i++) g_id[i] = path[a + i];
    g_id[b - a] = 0;
    g_paths = 1;
    return 1;
}

static int file_name(wch *out, const char *suffix) {
    int n = 0;
    for (int i = 0; g_dir[i] && n < BUF - 1; i++) out[n++] = g_dir[i];
    if (n && out[n - 1] != '\\' && out[n - 1] != '/') out[n++] = '\\';
    const char *pre = "Ski-E-O-Mod-";
    for (int i = 0; pre[i] && n < BUF - 1; i++) out[n++] = (wch)pre[i];
    for (int i = 0; g_id[i] && n < BUF - 1; i++) out[n++] = g_id[i];
    out[n++] = '-';
    for (int i = 0; suffix[i] && n < BUF - 1; i++) out[n++] = (wch)suffix[i];
    out[n] = 0;
    return n < BUF - 1;
}

static void put_file(const char *suffix, const void *data, u32 size) {
    wch path[BUF];
    if (!file_name(path, suffix)) return;
    HANDLE f = CreateFileW(path, 0x40000000, 3, 0, 2, 0x80, 0);            // write, create always
    if ((size_t)f == (size_t)-1) return;
    u32 done; WriteFile(f, data, size, &done, 0); CloseHandle(f);
}

static void set_status(const char *text) {
    int i = 0;
    while (text[i] && i < (int)sizeof(g_status) - 2) { g_status[i] = text[i]; i++; }
    g_status[i] = 0;
}
static void flush_status(void) {
    int same = 1;
    for (int i = 0; i < (int)sizeof(g_status); i++) { if (g_status[i] != g_written[i]) { same = 0; break; } if (!g_status[i]) break; }
    if (same) return;
    int i = 0; while (g_status[i]) { g_written[i] = g_status[i]; i++; } g_written[i] = 0;
    put_file("snow.status", g_status, (u32)i);
}

// The game's code sections, scanned once for the four fingerprints.
static int check_game(void) {
    if (g_support >= 0) return g_support;
    g_support = 99;
    const uint8_t *exe = GetModuleHandleW(L"skieogame.exe");
    if (!exe || !readable(exe, 0x1000)) { set_status("unsupported: game module not found"); return g_support; }
    int32_t lfanew; ps_memcpy(&lfanew, exe + 0x3c, 4);
    if (lfanew <= 0 || lfanew > 0x100000 || !readable(exe + lfanew, 0x108)) { set_status("unsupported: bad PE header"); return g_support; }
    const uint8_t *nt = exe + lfanew;
    uint16_t sections, optsize; uint32_t image;
    ps_memcpy(&sections, nt + 6, 2); ps_memcpy(&optsize, nt + 20, 2); ps_memcpy(&image, nt + 24 + 56, 4);
    if (!sections || sections > 96) { set_status("unsupported: bad PE header"); return g_support; }
    const uint8_t *table = nt + 24 + optsize;
    if (!readable(table, (size_t)sections * 40)) { set_status("unsupported: bad PE header"); return g_support; }
    const uint8_t *ranges[32]; size_t sizes[32]; unsigned count = 0;
    for (unsigned i = 0; i < sections && count < 32; i++) {
        const uint8_t *s = table + i * 40;
        uint32_t vsize, va, flags;
        ps_memcpy(&vsize, s + 8, 4); ps_memcpy(&va, s + 12, 4); ps_memcpy(&flags, s + 36, 4);
        if (!(flags & 0x20000000)) continue;                               // not executable
        if (va > image || vsize > image - va || !readable(exe + va, vsize)) continue;
        ranges[count] = exe + va; sizes[count] = vsize; count++;
    }
    if (layouts_supported(layouts, 4, ranges, sizes, count)) {
        set_status("unsupported: this game build's snow cache layout is not recognised");
        return g_support = 98;
    }
    g_support = 0;
    set_status("ok");
    return 0;
}

__declspec(dllexport) int patrol_snow(void *lua_state) {
    (void)lua_state;
    if (!find_paths()) return 0;
    wch job_path[BUF], out_path[BUF];
    if (!file_name(job_path, "snow.job") || !file_name(out_path, "snow.bin")) return 0;
    static uint8_t payload[32 + SNOW_MAX_SAMPLES * 16 + 1];
    static float result[SNOW_MAX_SAMPLES][4];
    u32 got = 0;
    HANDLE f = CreateFileW(job_path, 0x80000000, 3, 0, 3, 0x80, 0);        // read, open existing
    if ((size_t)f == (size_t)-1) return 0;
    ReadFile(f, payload, sizeof(payload), &got, 0);
    CloseHandle(f);
    DeleteFileW(out_path);

    unsigned count = 0;
    uint64_t owner = 0, cls = 0; uint32_t version = 0, reserved = 1, declared = 0;
    int ok = got >= 32 && got <= 32 + SNOW_MAX_SAMPLES * 16;
    if (ok) {
        ps_memcpy(&version, payload + 4, 4); ps_memcpy(&owner, payload + 8, 8); ps_memcpy(&cls, payload + 16, 8);
        ps_memcpy(&declared, payload + 24, 4); ps_memcpy(&reserved, payload + 28, 4);
        ok = !ps_memcmp(payload, "SKSN", 4) && version == 2 && declared >= 1 && declared <= SNOW_MAX_SAMPLES
            && !reserved && got == 32 + declared * 16 && owner && cls;
        count = declared;
    }
    if (!ok) { set_status("error: bad job file"); flush_status(); return 0; }
    if (check_game()) { flush_status(); return 0; }
    static double xy[SNOW_MAX_SAMPLES * 2];
    for (unsigned i = 0; i < count; i++) { ps_memcpy(&xy[i * 2], payload + 32 + i * 16, 16); }
    const char *failure = sample_snow((const uint8_t *)(size_t)owner, cls, xy, count, result);
    if (failure) {
        set_status("error: ");
        int n = 7;
        for (int i = 0; failure[i] && n < (int)sizeof(g_status) - 1; i++) g_status[n++] = failure[i];
        g_status[n] = 0;
    } else set_status("ok");
    flush_status();
    put_file("snow.bin", result, count * 16);
    return 0;
}
