# Diablo III: Eternal Collection (`01001B300B9BE000`)

Update 2.7.7.92380 (v1441792), SDK 8.2.0. Blizzard's engine with FMOD, on NVN; modules `main` and `sdk`. No game-specific binary cuts or gameplay modifications. This profile provides the original game's local play; it does not add offline seasons, challenge rifts, altered drops or a different screen aspect.

## What it needs

| Setting | Why |
|---|---|
| `tex_flush_upload on`, `tex_dirty_upload on` | The engine writes texture storage in CPU-cached / GPU-cached pools (flags `0x24`) after initialization. At first use a 2048 × 2048 BC3 texture had 2,829,690 nonzero guest bytes but an entirely zero GPU image. The existing dirty-page upload path makes those writes visible; without it the interface and movies render black. |
| Memory keys in [`game.tsv`](game.tsv) | A 5 GiB guest reservation, 4.375 GiB alias region and 256 MiB stack region. The initial survey reached alias +3.42 GiB in 15 seconds without calling `SetHeapSize`. These sizes reached the opening scene; later areas and long sessions remain unmeasured. |
| Deferred graphics-program resolution | Menu programs are finalized before the world submission replaces vertex and fragment programs separately. A bind must not dereference the retired, unselected stage: [reference](../../../docs/reference/nvn-objects.md#stage-binds-do-not-consume-the-other-stages). |
| Depth feedback snapshots | Soft particles sample the attached depth texture. They need a sampled copy outside the live depth pass: [reference](../../../docs/reference/rendering.md#depth-feedback-after-opaque-rendering). |
| `depth_mode zero` | The engine selects zero-to-one clip depth. Offline pipeline keys must match this runtime mode; upstream's default `gl` makes the archive disagree. |

## Files and shaders

The tested update's main build ID is `2607a74f5df7754cc0357b5df7e49693`; SDK build ID `3ae34e689d7a35f13cbf42bfd672af8b`. The merged RomFS image is 17,144,417,464 bytes. DLC indices 11, 100, 101 and 102 mount through the existing `DM_AOC_DIR` support; index 11 contains language content. The four add-on images total 5,609,751,673 bytes. Game files, saves and extracted shader packages stay outside this repository.

Blizzard CPK is distinct from CRI CPK. The bounded reader scans `.shd` assets on demand and feeds their checked GLSLC sections to the existing scanner: [Blizzard CPK](../../../docs/reference/shaders.md#blizzard-cpk-shader-assets). The census is 1,364 shaders: 585 vertex and 779 pixel. The 30 unique keys observed during the original startup investigation are in this union. Two packet encoding revisions occur among the containers; the newer feedback initializer was checked against this update's decoder at `main+0x762fa0` through `main+0x762fcc` (addresses are observations, not host hooks).

A separate-data IPA needs `Documents/romfs.img` and the numbered images under `Documents/aoc/`. The upstream launcher's existing external-DLC lookup is used unchanged. No game or shader binaries ship in this profile.

## Mac route

Use the updated image and all four add-on images. `DM_LANG=en-US` supplies the English system preference; the game's saved language setting can override it. A normal, non-seasonal Monk save skips first-run gamma and welcome dialogs: A at the title, A on Continue, then A to accept Normal difficulty; B dismisses news dialogs. Move with the left stick, attack with A, open inventory with Plus and the pause menu with Minus. Quit from that menu, then restart a new process to check save readback. `smoke.tsv` supplies a shorter loading route for `scripts/regress.py`; it requires that normal hero in the build's `run/save`, which the harness copies for each run. Never run on the player's only save.

## Lighting

The opening lantern's dark rectangles were traced to soft particles sampling the live depth attachment, rather than to the stencil-cull optimization hint. The shared snapshot path preserves the original light and particle shaders and leaves uniform deferral enabled. Read-only consumer draws reuse a snapshot; depth/stencil writes, clears, barriers, submissions and pass changes expire it. `DM_NVN_FB_SNAP=0` is a diagnostic negative control, not a profile setting. Other shapes and bindless depth feedback remain outside this fix.

2026-11-02 comparison on the support-only host, from copies of the same normal save: [snapshots disabled](../../../docs/images/diablo-iii-depth-feedback-before.jpg), [enabled](../../../docs/images/diablo-iii.jpg). The disabled path shows the black rectangle at the lantern; the enabled path removes it. Both fresh processes load the committed hero without cheats or game-specific main cuts, and log no `[RED]` lines.

## Validation

Historical base-support testing (2026-10-29, before gameplay modifications) used an M1 Max, macOS 26.5.2, Xcode 26.6 and Metal 32023.883. A normal Monk was created, loaded into Overlook Road, moved, attacked, opened inventory and returned to the menu; a new process read the committed hero back. The old unsigned IPA was 85.4 MiB. These historical results and caches do not validate current upstream or its pinned toolchain.

Current-branch validation is recorded separately from those results. The available compiler is Xcode 26.6 / Metal 32023.883, while this upstream revision requires Xcode 27.2 / Metal 32023.922 and macOS 26.6. `DM_ALLOW_OTHER_METAL=1` permits local compatibility testing, without changing the chain lock. No Xcode 27.2 or current-branch physical iPad run is claimed.

On 2026-11-02, over upstream `f355131991dd`:

- The current reader rescanned all 1,364 shaders; its map, facts and pair tables match this profile byte for byte. The current chain (`b7cd656abd7c`) built 1,364/1,364 Mac libraries with the available Metal compiler.
- All 117 Python test files pass (Python 3.13, `backports.zstd`, the existing .NET 10 SDK); the pinned Python lint environment has no new findings. Archive fixtures include scanner dispatch, corrupt metadata, both byte orders and packet encodings.
- The full host test target passes through `CLANG="xcrun clang"` (Apple Clang 21). Metal validation passes depth feedback (18 checks in each encoding mode), queue/stage lifetime (398), color feedback (69), pending pipelines (52), fusion (10), depth/stencil pipelines (286) and primitive restart (37). Disabling snapshots makes seven depth-fixture assertions fail, as expected. These GPU fixtures use Homebrew Clang 19.1.7 with Xcode 26.6's Metal compiler.
- The full D3 regression route passes on the candidate: frame 4,714 in 95 seconds, no crash or new `[RED]` lines, matching zero-to-one depth mode and 585 pipeline bases built without failures. Upstream alone crashes in `keys_hash` at frame 876. Both revisions use this same support-only profile as an external fixture because upstream has no D3 profile. Runs overlapped shader builds; their timings are not performance measurements.
- Pinned LLVM 23.1.4 C lint passes over all 215 sources with the available Xcode 26.6 SDK: 272 baseline findings, no new or fixed-but-still-listed findings. The tool archive's SHA-256 matches the upstream workflow. This still does not test Xcode 27.2's SDK.
- The full GPU target stops at `t_present_crop` in a MetalFX framework assertion (`_outputTextureBarrierStages not set`) on this OS; the remaining full-suite checks are not claimed. The Mac host builds and runs here with the local deployment override `MACOS_MIN=26.0`; no compatibility change is included in the source.

Rebased to upstream `f108343ac5c0` on the same date: its packing/pipeline-cache changes leave the renderer and shader chain unchanged. All 117 Python test files pass again. The latest full D3 comparison also passes (baseline 4,868 frames, candidate 4,914, each 95 seconds; no new RED or depth-mode mismatch). The stage-lifetime crash is intermittent: this baseline run did not trigger it, unlike the earlier runs above. The same MetalFX assertion also reproduces on an untouched `f108343ac5c0` checkout.

## Found on this game

- [Blizzard CPK shader assets](../../../docs/reference/shaders.md#blizzard-cpk-shader-assets): indexed reads, first-packet framing and both feedback initializers.
- [Stage binds do not consume the other stages](../../../docs/reference/nvn-objects.md#stage-binds-do-not-consume-the-other-stages): resolve programs when a draw consumes them.
- [Depth feedback after opaque rendering](../../../docs/reference/rendering.md#depth-feedback-after-opaque-rendering): sample a depth snapshot outside its producer pass.

## Open

- **Memory observation from a different, modified local build:** entering the next Nephalem Rift map once trapped after a 4,942,736-byte allocation failed. That build also contained gameplay and screen-aspect changes excluded here. The failing pool and fragmentation remain unknown; this has not been reproduced or fixed on this support-only branch. Raw device reports and saves are not included.
- Later areas, multiplayer, online services, full-session memory use and the current branch on a physical iPad need further testing. Opening-scene success does not establish them.
- The iOS smoke build on Xcode 26.6 cannot compile upstream's `CMMotionManager.deviceMotionBody` use; the API requires the newer SDK. This is a toolchain limit, not a fix included in this profile.
