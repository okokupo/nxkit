// Depth sampled after opaque rendering must come from a snapshot, including
// repeated read-only draws and a later depth clear in the same submission.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static prog_t pg[2];
static void program(id<MTLLibrary> lib, int index, const char *fragment) {
    NvProg *p = [NvProg new];
    p->sh[0] = [NvShader new]; p->sh[0]->fn = [lib newFunctionWithName:@"v"]; p->sh[0]->stage = 0;
    NvShader *fs = [NvShader new]; p->sh[1] = fs;
    fs->fn = [lib newFunctionWithName:@(fragment)]; fs->stage = 1;
    snprintf(fs->key, sizeof fs->key, "depth-fixture-%d", index);
    if (index) {
        fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D};
        fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    }
    pg[index].serial = 900 + index; serial_put(pg[index].serial, p);
}
static tex_t texture(uint64_t serial, int depth) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial, .off=serial << 20};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = depth ? NVN_FORMAT_DEPTH32F_STENCIL8 : NVN_FORMAT_RGBA8;
    return t;
}
static void bind(int index) {
    p_bind_program b = {&pg[index], 3}; state_op(OP_BIND_PROGRAM, &b);
}
static void pixels(id<MTLBuffer> out, unsigned row, int green) {
    const uint8_t *p = (const uint8_t *)out.contents + row * 2048;
    unsigned bad = 0;
    for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) { const uint8_t *q = p + y * 256 + x * 4; if (q[0] != (green ? 0 : 255) || q[1] != (green ? 255 : 0) || q[2] || q[3] != 255) bad++; }
    CHECK(!bad, green ? "sample sees preceding depth write" : "sample sees subsequent depth clear");
}
int main(void) { @autoreleasepool {
    mtl_init(); NSError *err = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n[[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[n],0.25,1); }\n"
        "fragment float4 opaque() { return float4(0,0,0,1); }\n"
        "struct A { depth2d<float> z[[id(0)]]; };\n"
        "fragment float4 sampled(constant A &a[[buffer(0)]], float4 p[[position]]) { float z=a.z.read(uint2(p.xy)); return abs(z-0.25)<0.001 ? float4(0,1,0,1) : float4(1,0,0,1); }\n"
        options:nil error:&err];
    if (!lib) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 2; }
    program(lib, 0, "opaque"); program(lib, 1, "sampled");
    tex_t color = texture(1001, 0), depth = texture(1002, 1);
    mtl_reg_tex(200, &depth, NULL);
    id<MTLBuffer> out = [g_dev newBufferWithLength:8192 options:MTLResourceStorageModeShared]; res_add(out);
    state_reset(); memset(&R, 0, sizeof R); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &color; R.rt.depth = &depth;
    R.clear_d = 1; R.cd = 1; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0,0,0,1);
    S.ds.dt = S.ds.dw = 1; S.ds.df = NVN_DEPTH_FUNC_ALWAYS;
    p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
    mtl_sub_begin(); bind(0); draw(&d, NULL);
    CHECK(g_enc != nil, "opaque depth stays in the open pass");
    S.ds.dw = 0; g_dss_dirty = 1; S.tex[1][0] = 200; args_dirty_all(); bind(1);
    uint64_t pass = g_pass.serial;
    draw(&d, NULL);
    CHECK(g_fb_n == 1, "depth sampler receives a snapshot");
    CHECK(g_pass.serial == pass + 1, "depth producer ends before sampling");
    CHECK(g_fb_src[0] != g_fb_use[0], "sampled texture is distinct from the depth attachment");
    pass = g_pass.serial; id<MTLTexture> snap = g_fb_depth_snap;
    draw(&d, NULL);
    CHECK(g_pass.serial == pass, "read-only consumer draws keep their pass");
    CHECK(g_fb_depth_snap == snap, "read-only consumer reuses the depth snapshot");
    NvProg *sampled = prog_get(&pg[1]);
    for (int slot = 128; slot <= 255; slot += 127) {
        sampled->sh[1]->rf.b[0].reg = slot; S.tex[1][slot] = 200; args_dirty_all();
        draw(&d, NULL);
        CHECK(g_fb_n == 1 && g_fb_depth_snap == snap, "separate depth texture slots use the read-only snapshot");
    }
    sampled->sh[1]->rf.b[0].reg = 0; args_dirty_all();
    struct { op_hdr barrier; int32_t bits, pad; op_hdr end; } commands = {{OP_BARRIER,16},NVN_BARRIER_ORDER_FRAGMENTS_BIT,0,{OP_END,8}};
    mtl_exec((const uint8_t *)&commands);
    uint64_t copies = g_fb_count;
    draw(&d, NULL);
    CHECK(g_fb_count == copies + 1, "a game barrier expires the depth snapshot");
    enc_b_copy_texture_buffer(blit(), tex_mtl(&color), 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(8,8,1), out, 0, 256, 2048);
    // Take another snapshot, then clear depth without changing render targets.
    draw(&d, NULL);
    p_clear_ds clear = {.depth=0.75, .depth_mask=1}; clear_ds_tri(&clear);
    CHECK(g_fb_depth_pass == 0, "mid-pass depth clear invalidates the snapshot");
    draw(&d, NULL);
    enc_b_copy_texture_buffer(blit(), tex_mtl(&color), 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(8,8,1), out, 2048, 256, 2048);
    draw(&d, NULL); bind(0); S.ds.dw = 1; g_dss_dirty = 1;
    draw(&d, NULL);
    CHECK(!g_fb_depth_pass, "ordinary depth-writing draw invalidates the snapshot");
    bind(1); S.ds.dw = 0; g_dss_dirty = 1; draw(&d, NULL);
    enc_b_copy_texture_buffer(blit(), tex_mtl(&color), 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(8,8,1), out, 4096, 256, 2048);
    R.clear_d = 1; R.cd = 0.75;
    draw(&d, NULL);
    enc_b_copy_texture_buffer(blit(), tex_mtl(&color), 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(8,8,1), out, 6144, 256, 2048);
    // No color attachment is necessary for detecting depth feedback.
    R.rt.n = 0; fb_prepare(sampled);
    CHECK(g_fb_n == 1, "depth-only render targets also snapshot feedback");
    uint64_t fence = mtl_sub_commit();
    mtl_tex_release(&depth); mtl_tex_release(&color);
    CHECK(mtl_wait(fence, 5000000000ull), "GPU submission completes after source textures retire");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(out, 0, 1); pixels(out, 1, 0); pixels(out, 2, 1); pixels(out, 3, 0);
    printf("t_depth_feedback: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
