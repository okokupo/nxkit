HLE_FORCE("getenv", "the game profile's game_env answers its names; the SDK's own getenv (an empty environ on Horizon) the rest", char *, g_getenv, const char *name) {
    static char *(*orig)(const char *);
    static char ***env_dir;
    size_t n = name ? strlen(name) : 0;
    for (const char *const *p = game_env(); n && *p; p++)
        if (!strncmp(*p, name, n) && (*p)[n] == '=') {
            char *r = (char *)*p + n + 1;
            LOG("g_getenv(%s) game_env -> \"%s\"", name, r);
            return r;
        }
    if (!orig) orig = guest_sym("getenv");
    if (!orig) {
        LOG("g_getenv(%s) -> NULL (orig unresolved)", name);
        return NULL;
    }
    char *r = orig(name);
    if (!env_dir) env_dir = guest_sym("environ");
    char **env = env_dir ? *env_dir : NULL;
    int cnt = 0;
    if (env) while (env[cnt] && cnt < 64) cnt++;
    LOG("g_getenv(%s) -> %p (orig=%p environ=%p n=%d)", name, (void *)r, (void *)orig, (void *)env, cnt);
    if (r) {
        char b[17];
        unsigned char *s = (unsigned char *)r;
        for (int i = 0; i < 16; i++) b[i] = (s[i] >= 32 && s[i] < 127) ? (char)s[i] : '.';
        b[16] = 0;
        LOG("g_getenv val16: \"%s\"", b);
    }
    return r;
}

// ---------- nn::mem::StandardAllocator::Allocate(size): Vanillaware's large blocks aligned to 64 KB (profile key alloc_big_align) ----------
// 13 Sentinels 1.10's own malloc (main 4b632573…, main+0x310550) is StandardAllocator::Allocate(size). It gets the storage of a GPU memory pool from malloc rounded only to 4 KB (main+0x3073b8),
//   then cuts three ring heaps out of the pool at 64 KB alignment relative to the GPU address (main+0x30c118), and the pool size is exactly their sum (main+0x307adc). On the Switch a pool's GPU address is aligned to a big page;
//   the host's GPU address is the CPU address, which is only 4 KB aligned, so up to 60 KB is lost at the start, the third ring heap (16 MB, used by the main thread's allocations while a command buffer is recorded) does not fit and keeps base 0,
//   and the first allocation while recording writes through a null pointer (main+0x2fa9a0, when the prologue enters its first battle).
// Unicorn Overlord 1.05 (main c841ffe2…), the same engine: operator new (main+0x5a55d4) takes the calling thread's ring heap (bump allocator main+0x5b8504: cursor +0x20 starts at the base) and one kept base 0.
//   Past the title screen the first allocation from it returned 0, which operator new's null check skipped, and the next returned 0x200; its constructor (main+0x5a3224 via main+0x4c754) wrote to 0x268.
//   With the profile key, allocations of 64 KB or more are aligned to 64 KB (Allocate(size, 0x10000)), which puts the pool storage on a 64 KB boundary. Other games forward unchanged
static void *(*g_sa_alloc)(void *, size_t), *(*g_sa_alloc_al)(void *, size_t, size_t);
static int g_sa_big_align;
static pthread_once_t g_sa_once = PTHREAD_ONCE_INIT;
static void sa_init(void) {
    module_t *ms = NULL; for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "sdk")) ms = &g_mod[i];
    g_sa_alloc = ms ? module_sym(ms, "_ZN2nn3mem17StandardAllocator8AllocateEm") : NULL;
    g_sa_alloc_al = ms ? module_sym(ms, "_ZN2nn3mem17StandardAllocator8AllocateEmm") : NULL;
    if (!g_sa_alloc || !g_sa_alloc_al) die("StandardAllocator::Allocate not found in the SDK");
    g_sa_big_align = DM_GAME_ALLOC_BIG_ALIGN;
    if (g_sa_big_align) LOG("StandardAllocator::Allocate: allocations ≥ 64 KB are 64 KB aligned (game profile alloc_big_align: memory pool storage, see hle_os.c)");
}
HLE_FORCE("_ZN2nn3mem17StandardAllocator8AllocateEm", "passed straight to the SDK; with the profile's alloc_big_align (13 Sentinels, Unicorn Overlord) allocations ≥ 64 KB are 64 KB aligned (memory pool start)", void *, h_mem_SAAllocate, void *self, size_t size) {
    pthread_once(&g_sa_once, sa_init);
    return g_sa_big_align && size >= 0x10000 ? g_sa_alloc_al(self, size, 0x10000) : g_sa_alloc(self, size);
}
