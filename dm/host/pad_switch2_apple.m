// CoreBluetooth transport for Switch 2 controllers, shared by the Mac and iOS front ends (pad_switch2_apple.h says what it does; switch2_proto.h is the protocol).
// Everything runs on the main queue, where the front ends' own pad callbacks run.
#import "pad_switch2_apple.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <IOBluetooth/IOBluetooth.h>   // IOBluetoothHostController: this Mac's own Bluetooth address, which a bonded controller wakes toward
#endif
#include "dm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <os/lock.h>

static dm_switch2_front g_front;
static s2_pad *g_pads;
static int g_verbose, g_motion_right = 1, g_motion = 1, g_active = 1, g_joy = 1;   // g_joy: each Joy-Con reported on its own (not with DM_PAD_MERGE)
static float g_gyro = S2_GYRO_RAD;
static int8_t g_map[6];
static int g_map_set;               // DM_SW2_MAP overrides the per-layout maps
static uint8_t g_host[6];           // this host's Bluetooth address, little endian, as a bonded controller's wake advertisement carries it
static int g_host_known;
static char g_sw2_bond_status[160] = "no bond attempt yet";   // bond() step receipts, surfaced live in the test view (dm_switch2_bond_status)
static char g_sw2_flash_status[256] = "旁路配对后自动验证 0x1FA000 记录区…";   // what the pairing-record sector showed before/after the store (dm_switch2_flash_status)
static char g_sw2_info_status[256] = "Info 区未读…";   // what the 0x13000 info block showed (dm_switch2_info_status)

// The pair step names, for the test view's diagnostics line
static const char *s2_step_zh(const char *what) {
    if (strstr(what, "pre-store")) return "记录区原始读取";
    if (strstr(what, "pair info")) return "配对信息(0x07)";
    if (strstr(what, "store")) return "落盘指令(0x09)";
    if (strstr(what, "host address")) return "主机地址";
    if (strstr(what, "first key")) return "key1";
    if (strstr(what, "second key")) return "key2";
    return "完成指令";
}

const char *dm_switch2_bond_status(void) { return g_sw2_bond_status; }
const char *dm_switch2_flash_status(void) { return g_sw2_flash_status; }
const char *dm_switch2_info_status(void) { return g_sw2_info_status; }

s2_pad *dm_switch2_pads(void) { return g_pads; }

// Rumble: each player's values as the game sets them, with their times (s2_rumble_log), written by the rumble queue (dm_switch2_rumble) and read by the main queue's tick. Every
// 15 ms each controller sends a packet of the next three 5 ms slots (switch2_proto.h, Rumble timing), the last one ending S2_RUMBLE_LAG_NS before the tick
static s2_rumble_log g_rlog[DM_PLAYERS];
static os_unfair_lock g_rlog_lock = OS_UNFAIR_LOCK_INIT;
#define S2_RUMBLE_TICK_S 0.015
#define S2_RUMBLE_LAG_NS 5000000ull   // so a late tick (the timer's own jitter) still finds every value of its slots
void dm_switch2_rumble(const dm_haptic_state *st) {
    if (!st || st->player < 0 || st->player >= DM_PLAYERS) return;
    s2_haptic m[2];
    for (int k = 0; k < 2; k++) { const dm_vibration *v = &st->motor[k]; m[k] = s2_haptic_from(v->amplitude_low, v->frequency_low, v->amplitude_high, v->frequency_high); }
    uint64_t t = now_ns();
    os_unfair_lock_lock(&g_rlog_lock); s2_rumble_log_add(&g_rlog[st->player], t, m); os_unfair_lock_unlock(&g_rlog_lock);
}
// Test view: set this host's Bluetooth address at runtime ("aa:bb:cc:dd:ee:ff" or "aabbccddeeff", display order). iOS hides its own address, so the value comes from an Android nRF scan while this device advertises; the pad targets the stored address when it wakes, so the iPad only hears its own wake if this is its real address
void dm_switch2_set_host(const char *addr) {
    unsigned v[6]; char c[5];
    int ok = addr && sscanf(addr, "%x%c%x%c%x%c%x%c%x%c%x", &v[0], &c[0], &v[1], &c[1], &v[2], &c[2], &v[3], &c[3], &v[4], &c[4], &v[5]) == 11;
    if (!ok) ok = addr && strlen(addr) == 12 && sscanf(addr, "%2x%2x%2x%2x%2x%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 6;
    if (!ok) { snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "唤醒地址格式不对：要 aa:bb:cc:dd:ee:ff 或 12 位 hex"); return; }
    for (int i = 0; i < 6; i++) g_host[i] = (uint8_t)v[5 - i];   // air order, as a wake advert carries it
    g_host_known = 1;
    snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "唤醒地址已设 %02x:%02x:%02x:%02x:%02x:%02x → 按住 Sync 重新配对落盘，再杀App重开按任意键", v[0], v[1], v[2], v[3], v[4], v[5]);
}
// Test view: ~1 s of strong rumble on player 1 through the game's rumble path (dm_switch2_rumble → 15 ms tick → BLE); the tick runs while any controller is live, so connect first
void dm_switch2_rumble_test(void) {
    static NSTimer *t;
    if (t) return;   // a burst is already running
    __block int left = 66;
    t = [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *tt) {
        dm_haptic_state st; memset(&st, 0, sizeof st);
        dm_vibration v = {1.0f, 0.3f, 1.0f, 0.6f};
        st.player = 0; st.motor[0] = v; st.motor[1] = v;
        dm_switch2_rumble(&st);
        if (--left <= 0) { [tt invalidate]; t = nil; }
    }];
}
static NSTimer *g_rumble_timer;
static struct { uint64_t last, maxgap, ticks, sent, busy, t0; } g_rstat;   // DM_SW2_VERBOSE: the rumble tick's spacing and the packets sent, each second
// One sample as the console treats it before coding: both bands scaled so that they add up to at most 0.98 (switch2_proto.h s2_rumble_cap)
static void s2_rumble_limit(s2_haptic *v) { float lo = v->lf_amp / 1023.f, hi = v->hf_amp / 1023.f; s2_rumble_cap(&lo, &hi); v->lf_amp = s2_amp_code(lo); v->hf_amp = s2_amp_code(hi); }

@interface S2Command : NSObject
@property (nonatomic) uint8_t cmd, sub; @property (nonatomic, copy) NSData *payload; @property (nonatomic, copy) void (^done)(NSData *);
@end
@implementation S2Command
@end

@interface S2Session : NSObject <CBPeripheralDelegate>
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic) uint16_t pid;
@property (nonatomic) int use;      // S2_ADV_PAIR, S2_ADV_TAKE or S2_ADV_WAKE: why it was connected
@property (nonatomic) s2_pad *pad;
@property (nonatomic) BOOL live;
@end

static NSMutableDictionary<NSUUID *, S2Session *> *g_sessions;
static CBCentralManager *g_central;
static void s2_session_closed(S2Session *s);
static void s2_rumble_timer(void);

static const char *s2_kind(uint16_t pid) { return pid == S2_PID_PRO ? "Pro Controller 2" : pid == S2_PID_JOYCON_L ? "Joy-Con 2 (L)" : "Joy-Con 2 (R)"; }
static s2_dev *s2_dev_of(s2_pad *p, uint16_t pid) { return pid == S2_PID_PRO ? &p->st.pro : pid == S2_PID_JOYCON_L ? &p->st.left : &p->st.right; }
static int s2_pad_empty(const s2_pad *p) { return !p->st.pro.have && !p->st.left.have && !p->st.right.have; }
static int s2_player(s2_pad *p) { return p && g_front.player ? g_front.player(p) : -1; }
static int s2_blocked(void) { return !g_active || (g_front.blocked && g_front.blocked()); }
// Which Joy-Cons a pad holds, to the npad layer (dm_joy_attach): a Pro Controller 2 is 0
static void s2_sync_sides(s2_pad *p) {
    int pl = g_joy ? s2_player(p) : -1; if (pl < 0) return;
    dm_joy_attach(pl, p->st.pro.have ? 0 : (uint32_t)((p->st.left.have ? 1 : 0) | (p->st.right.have ? 2 : 0) | DM_JOY_2));
}
static void s2_joy_release(int pl, int side) { if (g_joy && pl >= 0) { dm_joy_set(pl, side, 0, 0, 0); dm_motion_clear_joy(pl, side); } }
static void s2_pad_unlink(s2_pad *p) { s2_pad **link = &g_pads; while (*link && *link != p) link = &(*link)->next; if (*link) *link = p->next; }
static s2_pad *s2_pad_for(uint16_t pid) {   // a Joy-Con joins a pad that has the other one alone; anything else starts a pad
    if (pid != S2_PID_PRO)
        for (s2_pad *p = g_pads; p; p = p->next)
            if (!p->st.pro.have && ((pid == S2_PID_JOYCON_L && p->st.right.have && !p->st.left.have) || (pid == S2_PID_JOYCON_R && p->st.left.have && !p->st.right.have))) return p;
    s2_pad *p = calloc(1, sizeof *p); if (!p) return NULL;
    snprintf(p->name, sizeof p->name, "%s", pid == S2_PID_PRO ? "Pro Controller 2" : "Joy-Con 2");
    p->next = g_pads; g_pads = p;
    return p;
}

@implementation S2Session {
    CBCharacteristic *_wr, *_rsp, *_inp;
    NSMutableArray<S2Command *> *_queue;
    BOOL _pending; uint8_t _pendingCmd; NSUInteger _seq; void (^_cb)(NSData *);
    s2_cal _cal[2];
    NSTimer *_tick; uint64_t _reports; BOOL _handshaken; s2_rest _rest;
    s2_clock _clk; uint64_t _lost; char _serial[15]; uint64_t _restSaved;   // sample times from the controller's clock; the serial its learned gyro offset is kept under
    CBCharacteristic *_vib; uint8_t _vseq; int _offLeft; s2_rumble_cursor _rcur;   // _rcur: where this controller is in its player's rumble log
    int _player;   // the player at the last report: a pad waiting for its first button press (DM_PAD_PRESS_TO_JOIN) gets one later
    int16_t _mouseX, _mouseY; BOOL _mouseSeen, _mouseOn;   // _mouseOn: its mouse sensor is turned on (features)   // the mouse sensor's counters at the last report
    s2_hold _hold;   // the choosing gesture this Joy-Con holds now (s2_gesture)
}
- (void)dealloc { [self saveRest]; }
- (instancetype)initWith:(CBPeripheral *)p pid:(uint16_t)pid use:(int)use {
    if ((self = [super init])) { _peripheral = p; _pid = pid; _use = use; p.delegate = self; _queue = [NSMutableArray new]; s2_cal_default(&_cal[0]); s2_cal_default(&_cal[1]); }
    return self;
}
- (void)begin {
    [_peripheral discoverServices:nil];
    __weak S2Session *w = self;   // a controller that connects but never finishes the handshake is dropped
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ S2Session *s = w; if (s && !s->_handshaken) [s fail:@"handshake timed out"]; });
}
- (void)fail:(NSString *)why {
    LOG("[sw2] %s: %s", s2_kind(_pid), why.UTF8String);
    [g_central cancelPeripheralConnection:_peripheral];   // didDisconnect cleans up; a session that never connected is dropped there too
    if (!_live) s2_session_closed(self);
}
- (void)teardown {
    [_tick invalidate]; _tick = nil;
    if (_pad) {
        s2_pad *p = _pad; _pad = NULL;
        int player = s2_player(p);
        s2_dev *d = s2_dev_of(p, _pid); memset(d, 0, sizeof *d);
        if (player >= 0) dm_motion_clear_hid(player);
        if (_pid != S2_PID_PRO) s2_joy_release(player, _pid == S2_PID_JOYCON_R);
        if (s2_pad_empty(p)) {
            if (player >= 0 && g_joy) dm_joy_attach(player, 0);
            s2_pad_unlink(p);
            if (g_front.detach) g_front.detach(p);
            free(p);
        } else { s2_sync_sides(p); if (g_front.read) g_front.read(p); }
    }
}
// ---- commands: one in flight (the controller has one reply channel) ----
- (void)send:(uint8_t)cmd sub:(uint8_t)sub payload:(const uint8_t *)pl len:(size_t)n done:(void (^)(NSData *))done {
    S2Command *c = [S2Command new]; c.cmd = cmd; c.sub = sub; c.payload = [NSData dataWithBytes:pl length:n]; c.done = done;
    [_queue addObject:c]; [self pump];
}
- (void)pump {
    if (_pending || !_queue.count || !_wr) return;
    S2Command *c = _queue.firstObject; [_queue removeObjectAtIndex:0];
    uint8_t f[8 + 255]; size_t n = s2_command(f, sizeof f, c.cmd, c.sub, c.payload.bytes, c.payload.length);
    if (!n) { if (c.done) c.done(nil); [self pump]; return; }
    _pending = YES; _pendingCmd = c.cmd; _cb = c.done; NSUInteger mine = ++_seq; uint8_t id = c.cmd;
    __weak S2Session *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *s = w; if (!s || !s->_pending || s->_seq != mine) return;
        s->_pending = NO; void (^d)(NSData *) = s->_cb; s->_cb = nil;
        LOG("[sw2] %s: command 0x%02x timed out", s2_kind(s->_pid), id);
        if (d) d(nil);
        [s pump];
    });
    [_peripheral writeValue:[NSData dataWithBytes:f length:n] forCharacteristic:_wr type:CBCharacteristicWriteWithoutResponse];
}
- (void)readMemory:(uint8_t)len at:(uint32_t)addr done:(void (^)(NSData *))done {
    uint8_t p[8]; s2_memory_payload(p, len, addr);
    [self send:S2_CMD_MEMORY sub:S2_SUB_MEMORY_READ payload:p len:8 done:^(NSData *r) {
        done(r.length >= S2_REPLY_DATA + len && ((const uint8_t *)r.bytes)[8] == len ? [r subdataWithRange:NSMakeRange(S2_REPLY_DATA, len)] : nil);
    }];
}
- (void)readCal:(int)slot done:(void (^)(void))done {   // the user's calibration when set, else the factory's
    __weak S2Session *w = self;
    uint32_t user = slot ? S2_ADDR_USER_STICK2 : S2_ADDR_USER_STICK1, factory = slot ? S2_ADDR_FACTORY_STICK2 : S2_ADDR_FACTORY_STICK1;
    [self readMemory:0x0B at:user done:^(NSData *u) {
        S2Session *s = w; if (!s) return;
        if (u && s2_cal_parse(u.bytes, u.length, &s->_cal[slot])) { done(); return; }
        [s readMemory:0x0B at:factory done:^(NSData *f) { S2Session *s2 = w; if (!s2) return; if (f) s2_cal_parse(f.bytes, f.length, &s2->_cal[slot]); done(); }];
    }];
}
- (void)setLEDs:(void (^)(void))done {
    int p = s2_player(_pad); uint8_t pl[4] = {s2_led_pattern[p >= 0 && p < 8 ? p : 0], 0, 0, 0};
    [self send:S2_CMD_LEDS sub:S2_SUB_LEDS_SET payload:pl len:4 done:^(NSData *r) { (void)r; if (done) done(); }];
}
- (void)handshake {
    __weak S2Session *w = self;
    [self readMemory:0x40 at:S2_ADDR_INFO done:^(NSData *info) {
        S2Session *s = w; if (!s) return;
        uint16_t vid, pid; char serial[15];
        if (!info || !s2_info_parse(info.bytes, info.length, &vid, &pid, serial) || vid != S2_VENDOR_ID) { [s fail:@"the controller did not answer the identity read"]; return; }
        if (pid != s->_pid) LOG("[sw2] advertised 0x%04x but identifies as 0x%04x", s->_pid, pid);
        s->_pid = pid; memcpy(s->_serial, serial, sizeof s->_serial);
        void (^calibrate0)(void) = ^{ S2Session *a = w; if (!a) return;
            [a readCal:0 done:^{ S2Session *b = w; if (!b) return;
                void (^next)(void) = ^{ S2Session *c = w; if (!c) return; [c finish]; };
                if (b->_pid == S2_PID_PRO) [b readCal:1 done:next]; else next();
            }];
        };
        void (^calibrate)(void) = ^{ S2Session *a = w; if (!a) return; [a seedRest:calibrate0]; };
        if (s->_use == S2_ADV_PAIR) { [s bond:calibrate]; } else calibrate();   // v14: bond reads the pairing-record sector (0x1FA000) before and after the store itself, no separate flash scan
    }];
}
// The gyro offset before the controller has lain still for a second (s2_rest): the one learned for this controller in an earlier session, kept under its serial number,
// else its factory offset where that matches the rest offset (s2_gyro_cal_usable), else none until it rests. Either way s2_rest keeps refining it
- (void)seedRest:(void (^)(void))done {
    NSString *key = [NSString stringWithFormat:@"sw2.gyroOffset.%s", _serial];
    NSArray *kept = _serial[0] ? [NSUserDefaults.standardUserDefaults arrayForKey:key] : nil;
    if (kept.count == 3) {
        for (int i = 0; i < 3; i++) _rest.bias[i] = [kept[i] floatValue];
        _rest.have = 1;
        LOG("[sw2] %s: gyro offset %.1f, %.1f, %.1f counts, as learned in an earlier session", s2_kind(_pid), _rest.bias[0], _rest.bias[1], _rest.bias[2]);
        done(); return;
    }
    __weak S2Session *w = self;
    [self readMemory:0x10 at:S2_ADDR_GYRO_CAL done:^(NSData *d) {
        S2Session *s = w; if (!s) return;
        float off[3];
        if (d && s2_gyro_cal_parse(d.bytes, d.length, off)) {
            if (s2_gyro_cal_usable(s->_pid)) {
                memcpy(s->_rest.bias, off, sizeof off); s->_rest.have = 1;
                LOG("[sw2] %s: gyro offset %.1f, %.1f, %.1f counts, from its factory calibration", s2_kind(s->_pid), off[0], off[1], off[2]);
            } else LOG("[sw2] %s: factory gyro offset %.1f, %.1f, %.1f counts not used for this controller; it is learned once the controller rests", s2_kind(s->_pid), off[0], off[1], off[2]);
        } else LOG("[sw2] %s: no usable factory gyro offset; it is learned once the controller rests", s2_kind(s->_pid));
        done();
    }];
}
- (void)saveRest {
    if (!_serial[0] || !_rest.have) return;
    [NSUserDefaults.standardUserDefaults setObject:@[@(_rest.bias[0]), @(_rest.bias[1]), @(_rest.bias[2])] forKey:[NSString stringWithFormat:@"sw2.gyroOffset.%s", _serial]];
}
// After a bond attempt, read the pad's flash ONE candidate window per pairing session (the pairing-mode link only lives ~10-15s ≈ 6KB of reads): a cursor in NSUserDefaults advances to the next window every Sync, so a few press-holds cover the whole candidate list. v8-v12 proved the user region 0x1FC000-0x1FE000 and the info block 0x13000 are blank — the record must live elsewhere or nowhere.
- (void)scanFlash:(void (^)(void))done {
    __weak S2Session *w = self;
    __block NSMutableData *dump = [NSMutableData data];
    __block int remaining = 0;
    __block int fails = 0;
    __block int reads = 0;
    __block BOOL finished = NO;
    __block void (^readNext)(void);

    const int nWins = 6;
    const uint32_t bases[6] = {0x001FE000u, 0x001FF800u, 0x00013100u, 0x001F8000u, 0x001F9800u, 0x001FB000u};
    const int sizes[6]      = {6144, 2048, 3840, 6144, 6144, 4096};
    static const char *names[6] = {"尾区前半", "尾区后半", "Info区之后", "用户区前①", "用户区前②", "紧邻用户校准"};
    NSInteger cursor = [NSUserDefaults.standardUserDefaults integerForKey:@"sw2.flash.cursor"];
    if (cursor < 0 || cursor >= nWins) cursor = 0;
    [NSUserDefaults.standardUserDefaults setInteger:(cursor + 1) % nWins forKey:@"sw2.flash.cursor"];   // next Sync scans the next window
    static char wname[64];   // statics are pointer-captured by blocks (C arrays cannot be); single pad = single scan at a time
    snprintf(wname, sizeof wname, "窗口%ld/6·%s@0x%06X", (long)(cursor + 1), names[cursor], bases[cursor]);
    remaining = sizes[cursor];
    __block uint32_t nextAddr = bases[cursor];

    void (^abortWith)(const char *) = ^(const char *msg) { if (finished) return; finished = YES; snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "Flash %s： %s", wname, msg); done(); };
    void (^finishReport)(const char *) = ^(const char *note) { if (finished) return; finished = YES; s2_flash_report(dump.bytes, dump.length, note); done(); };

    // Watchdog: whatever wedges (pad stops answering, timers suspended in background, teardown delayed), always land a verdict within 15s — partial dumps are evidence too.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *s = w; if (!s || finished) return;
        finishReport("看门狗到点，以下为已扫部分");
    });

    readNext = ^{
        if (finished) return;   // scan already closed (watchdog/bond may have taken over)
        S2Session *s = w; if (!s) { finishReport("会话已断"); return; }
        if (remaining <= 0 || s->_peripheral.state != CBPeripheralStateConnected) { finishReport(remaining <= 0 ? "扫完" : "连接丢失"); return; }   // gone or finished: report what we have (never nil self while executing)
        uint32_t addr = nextAddr; nextAddr += 32;
        remaining--; reads++;
        snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "Flash %s： 已扫 %zuB（第%d次读取）…", wname, dump.length, reads + 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{   // gentle pace (proven stable v6-v12)
            S2Session *t = w; if (!t || finished) { finishReport("会话已断"); return; }
            [t readMemory:32 at:addr done:^(NSData *r) {
                if (finished) return;   // watchdog fired mid-read: drop this stale callback
                S2Session *u = w; if (!u) { finishReport("连接丢失"); return; }
                if (r.length >= 32) { [dump appendData:r]; fails = 0; }
                else if (++fails >= 3) { finishReport("3 次无回执"); return; }   // the pad stopped answering: report what we got
                readNext();
            }];
        });
    };
    readNext();
}

// Flash report as plain C so it can still run after the session died (partial dumps are evidence too — the pairing-mode window kills the link at ~6KB)
static BOOL s2_flash_region_reads(const uint8_t *d, size_t n) {
    for (size_t i = 0; i < n; i++) if (d[i] != 0xFF && d[i] != 0x00) return YES;
    return NO;
}
static void s2_flash_report(const uint8_t *d, size_t n, const char *note) {
    if (!n) { snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "Flash：手柄未应答扫描（已断线或固件忙）"); return; }
    const uint8_t v1[6] = {0x4C, 0x49, 0x4E, 0x47, 0x53, 0x32}, v2[6] = {0x30, 0x31, 0x32, 0x33, 0x34, 0x35};
    BOOL has1 = NO, has2 = NO, hostRec = NO; char cand[18] = "-";
    for (size_t i = 0; i + 14 <= n; i++) {
        if (!has1 && memcmp(d + i, v1, 6) == 0) has1 = YES;
        if (!has2 && memcmp(d + i, v2, 6) == 0) has2 = YES;
        if (!hostRec && d[i] == 0x00 && d[i + 1] == 0x02 && memcmp(d + i + 2, d + i + 8, 6) == 0 && (d[i + 2] | d[i + 3] | d[i + 4] | d[i + 5] | d[i + 6] | d[i + 7])) {
            hostRec = YES;
            snprintf(cand, sizeof cand, "%02X:%02X:%02X:%02X:%02X:%02X", d[i + 8], d[i + 7], d[i + 6], d[i + 5], d[i + 4], d[i + 3]);
        }
    }
    snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "Flash %zuKB（%s）： %s真机记录 主机=%s； sentinel旧%s新%s； %s", n / 1024, note, hostRec ? "有" : "无", cand, has1 ? "已落盘" : "无", has2 ? "已落盘" : "无", s2_flash_region_reads(d, n) ? "区域有数据" : "区域全空白（可能读错区）");
}

- (void)flashReport:(NSData *)dump done:(void (^)(void))done {
    s2_flash_report(dump.bytes, dump.length, "完整扫描");
    done();
}

// Info block report: the pad watched our REAL radio address at connect time — hunt for a host record (00 02 + addr×2) or our sentinel in what we read
__attribute__((unused)) static void s2_info_report(const uint8_t *d, size_t n) {   // kept for reference: v12 proved 0x13000 blank; v13 drops the info phase
    if (!n) { snprintf(g_sw2_info_status, sizeof g_sw2_info_status, "Info：无数据（固件拒绝或断链）"); return; }
    const uint8_t v2[6] = {0x30, 0x31, 0x32, 0x33, 0x34, 0x35};
    BOOL host = NO; char cand[18] = "-";
    for (size_t i = 0; i + 14 <= n; i++) {
        if (d[i] == 0x00 && d[i + 1] == 0x02 && memcmp(d + i + 2, d + i + 8, 6) == 0 && (d[i + 2] | d[i + 3] | d[i + 4] | d[i + 5] | d[i + 6] | d[i + 7])) {
            host = YES;
            snprintf(cand, sizeof cand, "%02X:%02X:%02X:%02X:%02X:%02X", d[i + 8], d[i + 7], d[i + 6], d[i + 5], d[i + 4], d[i + 3]);
            break;
        }
    }
    BOOL sent = NO;
    for (size_t i = 0; i + 6 <= n; i++) if (memcmp(d + i, v2, 6) == 0) { sent = YES; break; }
    size_t nz = 0; for (size_t i = 0; i < n; i++) if (d[i] != 0xFF && d[i] != 0x00) nz++;
    char peek[40];
    for (int i = 0; i < 12; i++) snprintf(peek + i * 3, 4, "%02X ", d[i]);
    snprintf(g_sw2_info_status, sizeof g_sw2_info_status, "Info %zuB： %s主机=%s； sentinel新%s； 非空%zuB； 头12B %s", n, host ? "疑似" : "无", cand, sent ? "在" : "无", nz, peek);
}

// Sync is held on this controller (its advertisement named no host): store this host's address via the community bypass — 0x03 0x07 sends address + LTK, 0x03 0x09 commits it to flash, no 0x15 handshake (whose PAIR_DONE drops the link)
- (void)bond:(void (^)(void))done {
    [self bondWrites:done];
}

- (void)bondWrites:(void (^)(void))done {
    __weak S2Session *w = self;
    uint8_t ltk[16], info[22];
    arc4random_buf(ltk, sizeof ltk);
    s2_pair_info_payload(info, g_host, ltk);
    NSData *pi = [NSData dataWithBytes:info length:sizeof info];
    snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "旁路配对开始：读记录区原始状态…");
    void (^step)(NSData *, const char *, void (^)(void)) = ^(NSData *r, const char *what, void (^next)(void)) {
        S2Session *s = w; if (!s) return;
        if (!r) { snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "停在【%s】：手柄无回执", s2_step_zh(what)); LOG("[sw2] %s: bypass pairing stopped at %s (no answer)", s2_kind(s->_pid), what); done(); return; }
        next();
    };
    [self readMemory:0x20 at:S2_ADDR_PAIRING done:^(NSData *pre) { step(pre, "the pre-store record read", ^{
        S2Session *s = w; if (!s) return;
        snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "原始状态已读，0x07 发送配对信息…");
        [s send:S2_CMD_BT sub:S2_SUB_BT_SEND_PAIR payload:pi.bytes len:pi.length done:^(NSData *r1) { step(r1, "the pair info", ^{
            S2Session *t = w; if (!t) return;
            snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "配对信息 ✓，0x09 请求落盘…");
            [t send:S2_CMD_BT sub:S2_SUB_BT_STORE_PAIR payload:nil len:0 done:^(NSData *r2) { step(r2, "the store command", ^{
                S2Session *u = w; if (!u) return;
                snprintf(g_sw2_bond_status, sizeof g_sw2_bond_status, "落盘指令 ✓，回读记录区验证…");
                [u readMemory:0x20 at:S2_ADDR_PAIRING done:^(NSData *post) {
                    S2Session *v = w; if (!v) return;
                    [v reportPairingRecord:pre post:post];
                    LOG("[sw2] %s bypass pair store: %s", s2_kind(v->_pid), g_sw2_flash_status);
                    done();
                }];
            }); }];
        }); }];
    }); }];
}

// Compare the pairing-record sector (0x1FA000: count, then 0x28-byte entries of 6-byte host address + 16-byte LTK) before and after the store, and say which of the three possible worlds we are in
- (void)reportPairingRecord:(NSData *)pre post:(NSData *)post {
    const uint8_t *p = post.bytes; const uint8_t *q = pre.bytes;
    if (!p || post.length < 0x14) { snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "记录区回读失败（无数据或已断链）"); return; }
    char h0[20] = "-", a[20] = "-", pa[20] = "-", aa[20] = "-";
    snprintf(h0, sizeof h0, "%02X%02X%02X%02X", p[0], p[1], p[2], p[3]);
    snprintf(a, sizeof a, "%02X:%02X:%02X:%02X:%02X:%02X", p[8], p[9], p[10], p[11], p[12], p[13]);
    if (q && pre.length >= 0x14) { snprintf(pa, sizeof pa, "%02X%02X%02X%02X", q[0], q[1], q[2], q[3]); snprintf(aa, sizeof aa, "%02X:%02X:%02X:%02X:%02X:%02X", q[8], q[9], q[10], q[11], q[12], q[13]); }
    uint8_t rev[6]; for (int i = 0; i < 6; i++) rev[i] = g_host[5 - i];
    int raw = !memcmp(p + 8, g_host, 6), revm = !memcmp(p + 8, rev, 6);
    size_t common = pre.length < post.length ? pre.length : post.length;
    int changed = !common || memcmp(q, p, common) != 0;
    if (raw || revm)
        snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "✅ 记录已落盘！地址%s（%s字节序=当前唤醒地址）→ 杀App重开按任意键测唤醒", a, raw ? "正序" : "反序");
    else if (changed)
        snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "⚠️ 记录区变了但非sentinel：前%s/%s→后%s/%s，截图发小凌", pa, aa, h0, a);
    else
        snprintf(g_sw2_flash_status, sizeof g_sw2_flash_status, "❌ 记录区未变（前%s/%s 后%s/%s）——0x09未生效或被固件拒绝", pa, aa, h0, a);
}
// The features this controller reports: a Joy-Con 2's mouse sensor too once the game reads the sensors (dm_joy_mouse_wanted; the Pro Controller 2 has none), as the console
// turns it on only for a game that uses it. Once on, it stays on while the controller is connected
- (uint8_t)features {
    if (_pid != S2_PID_PRO && dm_joy_mouse_wanted()) _mouseOn = YES;
    return _mouseOn ? S2_FEATURES | S2_FEATURE_MOUSE : S2_FEATURES;
}
// The game set up the mouse sensors after this controller connected: the handshake's two feature commands again, with the sensor's bit
- (void)mouseOn {
    __weak S2Session *w = self;
    uint8_t fe[4] = {S2_FEATURES | S2_FEATURE_MOUSE, 0, 0, 0};
    [self send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_SET payload:fe len:4 done:^(NSData *r1) {
        (void)r1; S2Session *s = w; if (!s) return;
        uint8_t on[4] = {S2_FEATURES | S2_FEATURE_MOUSE, 0, 0, 0};
        [s send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_ENABLE payload:on len:4 done:^(NSData *r2) { S2Session *t = w; if (t) LOG("[sw2] %s: mouse sensor %s", s2_kind(t->_pid), r2 ? "on" : "not turned on (no answer)"); }];
    }];
}
- (void)finish {
    __weak S2Session *w = self;
    uint8_t feat = [self features];
    uint8_t pl[4] = {feat, 0, 0, 0};
    [self send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_SET payload:pl len:4 done:^(NSData *r1) {
        S2Session *s = w; if (!s) return; (void)r1;
        uint8_t on[4] = {feat, 0, 0, 0};
        [s send:S2_CMD_FEATURE sub:S2_SUB_FEATURE_ENABLE payload:on len:4 done:^(NSData *r2) {
            S2Session *t = w; if (!t) return;
            if (!r2) { [t fail:@"enabling the features was refused"]; return; }
            [t attachPad];
        }];
    }];
}
- (void)attachPad {
    s2_pad *p = s2_pad_for(_pid);
    if (!p) { [self fail:@"out of memory"]; return; }
    BOOL fresh = s2_pad_empty(p);
    s2_dev *d = s2_dev_of(p, _pid); memset(d, 0, sizeof *d);
    d->have = 1; d->pid = _pid; d->cal[0] = _cal[0]; d->cal[1] = _cal[1];
    _pad = p; _live = YES; _handshaken = YES;
    s2_rumble_timer();
    if (fresh) {
        if (!g_front.attach || !g_front.attach(p)) { LOG("[sw2] %s: no free player, not used", s2_kind(_pid)); [self fail:@"all players are taken"]; return; }
    } else if (g_front.read) g_front.read(p);
    s2_sync_sides(p);
    _player = s2_player(p);
    if (_player < 0) LOG("[sw2] %s connected: a player once a button is pressed%s", s2_kind(_pid), fresh ? "" : " (joined the Joy-Con already there)");
    else LOG("[sw2] %s connected: player %d%s", s2_kind(_pid), _player + 1, fresh ? "" : " (joined the Joy-Con already there)");
    [self setLEDs:nil];
    [_peripheral setNotifyValue:YES forCharacteristic:_inp];
    __weak S2Session *w = self;   // the link drops after about ten seconds without a write from the host, so the LEDs are written once a second
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        S2Session *s = w; if (!s) { [t invalidate]; return; }
        int pl = s2_player(s->_pad); uint8_t l[4] = {s2_led_pattern[pl >= 0 && pl < 8 ? pl : 0], 0, 0, 0}; uint8_t f[12];
        size_t n = s2_command(f, sizeof f, S2_CMD_LEDS, S2_SUB_LEDS_SET, l, 4);
        if (s->_wr && n) [s->_peripheral writeValue:[NSData dataWithBytes:f length:n] forCharacteristic:s->_wr type:CBCharacteristicWriteWithoutResponse];
        if (!s->_mouseOn && [s features] != S2_FEATURES) [s mouseOn];
    }];
}
// Every 15 ms: this controller's share of the player's motors (s2_rumble_pick) over its next three 5 ms slots (switch2_proto.h, Rumble timing).
// A buzz ends with three packets of silence, since one write without response can be lost
- (void)rumbleTick {
    if (!_live || !_pad || !_vib) return;
    int pl = s2_player(_pad); if (pl < 0 || pl >= DM_PLAYERS) return;
    s2_haptic a[3], b[3]; int on = 0;
    const s2_dev *dev = s2_dev_of(_pad, _pid); unsigned motors = s2_rumble_motors(&_pad->st, dev);
    s2_rumble_resync(&_rcur, now_ns(), S2_RUMBLE_LAG_NS);
    for (int k = 0; k < 3; k++) {
        os_unfair_lock_lock(&g_rlog_lock); s2_rumble_slot(&g_rlog[pl], &_rcur, motors); os_unfair_lock_unlock(&g_rlog_lock);
        s2_rumble_pick(&_pad->st, dev, _rcur.now, &a[k], &b[k]);
        s2_rumble_limit(&a[k]); s2_rumble_limit(&b[k]);
        on |= s2_haptic_on(&a[k]) || s2_haptic_on(&b[k]);
    }
    if (on) _offLeft = 3;
    else if (_offLeft > 0) _offLeft--;
    else return;
    uint8_t pk[33]; size_t n = s2_rumble_packet3(pk, a, b, _vseq++);
    if (!_peripheral.canSendWriteWithoutResponse) g_rstat.busy++;
    g_rstat.sent++;
    [_peripheral writeValue:[NSData dataWithBytes:pk length:n] forCharacteristic:_vib type:CBCharacteristicWriteWithoutResponse];
}
- (void)report:(NSData *)d {
    s2_report r; if (!_pad || !s2_report_parse(d.bytes, d.length, &r)) return;
    s2_dev *dev = s2_dev_of(_pad, _pid); dev->r = r; _reports++;
    unsigned lost; uint64_t ts = s2_clock_sample(&_clk, r.clock_ms, now_ns(), &lost); _lost += lost;
    int had = _rest.have; float was[3] = {_rest.bias[0], _rest.bias[1], _rest.bias[2]};
    s2_rest_update(&_rest, r.raw);
    if (_rest.have && (!had || was[0] != _rest.bias[0] || was[1] != _rest.bias[1] || was[2] != _rest.bias[2]) && ts - _restSaved > 30000000000ull) { [self saveRest]; _restSaved = ts; }
    if (g_verbose && _reports % 33 == 1)
        LOG("[sw2] %s: clock %u ms, %llu reports lost so far; buttons 0x%08x sticks %u,%u %u,%u accel %d,%d,%d gyro %d,%d,%d battery %u mV mouse %d,%d %u,%u", s2_kind(_pid), r.clock_ms, (unsigned long long)_lost, r.buttons, r.lx, r.ly, r.rx, r.ry, r.raw[0], r.raw[1], r.raw[2], r.raw[3], r.raw[4], r.raw[5], r.battery_mv, r.mouse_x, r.mouse_y, r.mouse_q, r.mouse_s);
    if (g_front.read) g_front.read(_pad);
    int player = s2_player(_pad), blocked = s2_blocked();
    if (player != _player) {   // the front end gave the pad a player at its first button press (or the pad changed hands): its Joy-Con styles and player lights follow
        _player = player;
        if (player >= 0) { s2_sync_sides(_pad); [self setLEDs:nil]; }
    }
    if (g_motion && !blocked && player >= 0 && s2_pad_motion_dev(&_pad->st, g_motion_right) == dev) {
        const int8_t *map = g_map_set ? g_map : s2_pad_map(&_pad->st, dev);
        float acc[3], rot[3]; s2_motion(r.raw, map, _rest.have ? _rest.bias : NULL, g_gyro, acc, rot);
        dm_motion_set_hid(player, acc, rot, ts);
    }
    if (_pid == S2_PID_PRO || !g_joy || player < 0) return;
    int right = _pid == S2_PID_JOYCON_R;
    if (!blocked) {   // the Joy-Con's own buttons, stick and sensor, in its own frame (upright: the pair's map)
        int32_t st[2]; s2_joy_stick(dev, right, st);
        dm_joy_set(player, right, s2_joy_buttons(r.buttons, right), st[0], st[1]);
        if (g_motion) { float acc[3], rot[3]; s2_motion(r.raw, g_map_set ? g_map : s2_map_pair, _rest.have ? _rest.bias : NULL, g_gyro, acc, rot); dm_motion_set_joy(player, right, acc, rot, ts); }
        // The mouse sensor, once it is on and reporting: the movement since the last report, none while lifted (the counters drift with no surface under them)
        if (_mouseOn && s2_mouse_present(&r)) {
            int on = s2_mouse_on_surface(&r);
            int32_t dx = _mouseSeen && on ? s2_mouse_delta(r.mouse_x, _mouseX) : 0, dy = _mouseSeen && on ? s2_mouse_delta(r.mouse_y, _mouseY) : 0;
            dm_joy_mouse(player, right, dx, dy, DM_JOYMOUSE_CONNECTED | (on ? DM_JOYMOUSE_ON_SURFACE : 0));
        }
    }
    _mouseSeen = _mouseOn && s2_mouse_present(&r); _mouseX = r.mouse_x; _mouseY = r.mouse_y;
    [self gesture:r.buttons right:right];
}
// SL + SR held on a Joy-Con of a pair: it plays alone. L on a left one alone and R on a right one alone, held together: they pair (switch2_proto.h, s2_gesture)
- (void)gesture:(uint32_t)b right:(int)right {
    s2_pad *p = _pad; int paired = p->st.left.have && p->st.right.have;
    if (!s2_hold_update(&_hold, s2_gesture(b, right, paired), now_ns()) || _hold.done) return;
    if (_hold.kind == S2_GESTURE_SPLIT) { _hold.done = 1; [self leavePair]; return; }
    for (S2Session *o in g_sessions.allValues) {   // the partner: the other side, alone, holding its own L or R as long
        if (o == self || !o->_live || !o->_pad || o->_pid == _pid || o->_pid == S2_PID_PRO || o->_pad->st.left.have == o->_pad->st.right.have) continue;
        if (o->_hold.kind != S2_GESTURE_JOIN || o->_hold.done || now_ns() - o->_hold.since < S2_GESTURE_NS) continue;
        _hold.done = o->_hold.done = 1;
        S2Session *mover = s2_player(_pad) > s2_player(o->_pad) ? self : o, *stay = mover == self ? o : self;
        [mover joinPadOf:stay];
        return;
    }
}
- (void)leavePair {
    s2_pad *old = _pad; int was = s2_player(old), side = _pid == S2_PID_JOYCON_R;
    s2_pad *p = calloc(1, sizeof *p); if (!p) return;
    snprintf(p->name, sizeof p->name, "%s", "Joy-Con 2");
    s2_dev *d = s2_dev_of(old, _pid), *nd = s2_dev_of(p, _pid); *nd = *d; memset(d, 0, sizeof *d);
    s2_joy_release(was, side); s2_sync_sides(old); if (g_front.read) g_front.read(old);
    p->next = g_pads; g_pads = p; _pad = p;
    if (!g_front.attach || !g_front.attach(p)) {   // no free player: back into the pair
        LOG("[sw2] %s: no free player to play alone, it stays in the pair", s2_kind(_pid));
        s2_pad_unlink(p); *d = *nd; _pad = old; free(p); s2_sync_sides(old); return;
    }
    s2_sync_sides(p); if (g_front.read) g_front.read(p);
    _player = s2_player(p);
    if (_player < 0) LOG("[sw2] %s plays alone once a button is pressed (SL + SR held); the other Joy-Con stays player %d", s2_kind(_pid), was + 1);
    else LOG("[sw2] %s plays alone now: player %d (SL + SR held); the other Joy-Con stays player %d", s2_kind(_pid), _player + 1, was + 1);
    [self setLEDs:nil];
}
- (void)joinPadOf:(S2Session *)stay {
    s2_pad *old = _pad, *into = stay->_pad; int was = s2_player(old), side = _pid == S2_PID_JOYCON_R;
    s2_dev *d = s2_dev_of(old, _pid), *nd = s2_dev_of(into, _pid); *nd = *d; memset(d, 0, sizeof *d);
    s2_joy_release(was, side);
    if (was >= 0) { dm_motion_clear_hid(was); if (g_joy) dm_joy_attach(was, 0); }
    s2_pad_unlink(old); if (g_front.detach) g_front.detach(old); free(old);
    _pad = into; s2_sync_sides(into); if (g_front.read) g_front.read(into);
    LOG("[sw2] %s and %s play as one pair now: player %d (L + R held)", s2_kind(stay->_pid), s2_kind(_pid), s2_player(into) + 1);
    [self setLEDs:nil];
}
// ---- CBPeripheralDelegate ----
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(NSError *)e {
    if (e) { [self fail:[NSString stringWithFormat:@"service discovery: %@", e.localizedDescription]]; return; }
    for (CBService *s in p.services) [p discoverCharacteristics:nil forService:s];
}
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(NSError *)e {
    if (e) { [self fail:[NSString stringWithFormat:@"characteristic discovery: %@", e.localizedDescription]]; return; }
    CBUUID *wr = [CBUUID UUIDWithString:@S2_UUID_CMD_WR], *rs = [CBUUID UUIDWithString:@S2_UUID_CMD_RSP], *in = [CBUUID UUIDWithString:@S2_UUID_INPUT];
    CBUUID *vr = [CBUUID UUIDWithString:@S2_UUID_VIB_JOYCON_R], *vl = [CBUUID UUIDWithString:@S2_UUID_VIB_JOYCON_L], *vp = [CBUUID UUIDWithString:@S2_UUID_VIB_PRO];
    for (CBCharacteristic *c in s.characteristics) {
        if ([c.UUID isEqual:wr]) _wr = c; else if ([c.UUID isEqual:rs]) _rsp = c; else if ([c.UUID isEqual:in]) _inp = c;
        else if ([c.UUID isEqual:vr] || [c.UUID isEqual:vl] || [c.UUID isEqual:vp]) _vib = c;
    }
    if (_wr && _rsp && _inp && !_handshaken && !_live) [p setNotifyValue:YES forCharacteristic:_rsp];
}
- (void)peripheral:(CBPeripheral *)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(NSError *)e {
    if (e) { [self fail:[NSString stringWithFormat:@"notifications: %@", e.localizedDescription]]; return; }
    if (c == _rsp && !_live) [self handshake];
}
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)e {
    if (e || !c.value.length) return;
    if (c == _inp) { [self report:c.value]; return; }
    if (c == _rsp && _pending && s2_reply_is(c.value.bytes, c.value.length, _pendingCmd)) {
        _pending = NO; void (^d)(NSData *) = _cb; _cb = nil;
        if (d) d(c.value);
        [self pump];
    }
}
- (void)peripheral:(CBPeripheral *)p didModifyServices:(NSArray<CBService *> *)invalidated { (void)invalidated; [self fail:@"the controller reset the link"]; }
@end

static void s2_session_closed(S2Session *s) { [s teardown]; [g_sessions removeObjectForKey:s.peripheral.identifier]; s2_rumble_timer(); }

@interface S2Central : NSObject <CBCentralManagerDelegate>
@end
@implementation S2Central {
    NSMutableDictionary<NSUUID *, NSDate *> *_tried;   // a controller whose connection failed is not tried again at every advertisement
    NSMutableSet<NSUUID *> *_told;                       // a controller in pairing mode that cannot be paired is logged once
}
- (void)scan:(CBCentralManager *)c {
    [c scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];   // a controller's wake is advertised for a short while: every advertisement counts
    LOG("[sw2] Switch 2 controllers: press a button on a paired one; to pair one, hold its Sync button until the player lights sweep");
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
    if (c.state == CBManagerStatePoweredOn) {
#if TARGET_OS_OSX
        static BOOL asked;
        if (!g_host_known && !asked) {   // this Mac's address, from the Bluetooth host controller once the app may use Bluetooth (off the main queue: the first call can take seconds); the scan starts after it
            asked = YES; __weak CBCentralManager *wc = c;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                const char *addr = IOBluetoothHostController.defaultController.addressAsString.UTF8String;   // "aa-bb-cc-dd-ee-ff"
                unsigned a[6]; BOOL ok = addr && sscanf(addr, "%x%*c%x%*c%x%*c%x%*c%x%*c%x", &a[0], &a[1], &a[2], &a[3], &a[4], &a[5]) == 6 && (a[0] | a[1] | a[2] | a[3] | a[4] | a[5]);
                uint8_t le[6]; for (int i = 0; i < 6; i++) le[i] = ok ? (uint8_t)a[5 - i] : 0;
                NSData *leData = [NSData dataWithBytes:le length:6];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) { memcpy(g_host, leData.bytes, 6); g_host_known = 1; }
                    else LOG("[sw2] this Mac's Bluetooth address could not be read: controllers are used without pairing (DM_SW2_HOST=aa:bb:cc:dd:ee:ff names it)");
                    CBCentralManager *cm = wc; if (cm && cm.state == CBManagerStatePoweredOn) [self scan:cm];
                });
            });
            return;
        }
#else
        if (!g_host_known) {   // iOS has no API for this host's Bluetooth address (see s2_advert_use): bond toward a fixed sentinel instead. The wake comparison runs on the advertisement payload, not on the radio link, so a sentinel wakes and reconnects like a real address
            const uint8_t sentinel[6] = {0x30, 0x31, 0x32, 0x33, 0x34, 0x35};   // every byte's top two bits 00: a valid public-address pattern whichever byte the pad validates as MSB (first sentinel "LINGS2" was ACKed but the pad never wake-advertised: suspecting an address-format check)
            memcpy(g_host, sentinel, 6); g_host_known = 1;
            LOG("[sw2] iOS has no API for this host's Bluetooth address: bonding toward a fixed sentinel instead. The first Sync pairs for good; after that a button press reconnects. A Switch 2 or Mac re-bond overwrites it: hold Sync here once more");
        }
#endif
        [self scan:c];
    } else if (c.state == CBManagerStateUnauthorized) LOG("[sw2] Bluetooth is not allowed for this app (System Settings > Privacy & Security > Bluetooth)");
    else if (c.state == CBManagerStatePoweredOff) LOG("[sw2] Bluetooth is off");
}
- (void)centralManager:(CBCentralManager *)c didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary<NSString *, id> *)ad RSSI:(NSNumber *)rssi {
    NSData *d = ad[CBAdvertisementDataManufacturerDataKey];
    if (d.length < 18 || s2_u16(d.bytes) != S2_COMPANY_ID || g_sessions[p.identifier]) return;
    s2_advert a; if (!s2_advert_parse((const uint8_t *)d.bytes + 2, d.length - 2, &a)) return;
    int use = s2_advert_use(&a, g_host_known ? g_host : NULL);
    if (!_tried) { _tried = [NSMutableDictionary new]; _told = [NSMutableSet new]; }
    if (use == S2_ADV_IGNORE) {   // waking toward another host (a Switch 2 nearby): not touched, logged once
        if (![_told containsObject:p.identifier]) { [_told addObject:p.identifier]; LOG("[sw2] a %s woke for another host: left alone (hold its Sync button to pair it with this Mac)", s2_kind(a.pid)); }
        return;
    }
    if (_tried[p.identifier] && -[_tried[p.identifier] timeIntervalSinceNow] < 3) return;
    _tried[p.identifier] = [NSDate date];
    if (use == S2_ADV_TAKE && ![_told containsObject:p.identifier]) {
        [_told addObject:p.identifier];
        LOG("[sw2] this host's Bluetooth address is not known: the %s is used without pairing, and needs Sync again next time", s2_kind(a.pid));
    }
    S2Session *s = [[S2Session alloc] initWith:p pid:a.pid use:use];
    g_sessions[p.identifier] = s;
    LOG("[sw2] %s %s (rssi %d), connecting", use == S2_ADV_WAKE ? "woke:" : "pairing:", s2_kind(a.pid), rssi.intValue);
    [c connectPeripheral:p options:nil];
    NSUUID *id = p.identifier; __weak CBCentralManager *wc = c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        S2Session *t = g_sessions[id];
        if (t && t.peripheral.state != CBPeripheralStateConnected) { LOG("[sw2] connecting timed out"); [wc cancelPeripheralConnection:t.peripheral]; s2_session_closed(t); }
    });
}
- (void)centralManager:(CBCentralManager *)c didConnectPeripheral:(CBPeripheral *)p { [g_sessions[p.identifier] begin]; }
- (void)centralManager:(CBCentralManager *)c didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    LOG("[sw2] connect failed: %s", e.localizedDescription.UTF8String ?: "unknown");
    S2Session *s = g_sessions[p.identifier]; if (s) s2_session_closed(s);
}
- (void)centralManager:(CBCentralManager *)c didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)e {
    S2Session *s = g_sessions[p.identifier]; if (!s) return;
    LOG("[sw2] %s disconnected%s%s", s2_kind(s.pid), e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
    s2_session_closed(s);
}
@end

void dm_switch2_active(int on) {
    g_active = on;
    if (!on) for (s2_pad *p = g_pads; p; p = p->next) { int pl = s2_player(p); if (pl >= 0) { dm_motion_clear_hid(pl); s2_joy_release(pl, 0); s2_joy_release(pl, 1); } }
}

static S2Central *g_delegate;
static void s2_central_start(void) { g_central = [[CBCentralManager alloc] initWithDelegate:g_delegate queue:nil options:nil]; }
// The rumble tick runs while a controller is connected (attachPad starts it, s2_session_closed stops it with the last one), not for the whole game
static void s2_rumble_timer(void) {
    BOOL any = NO; for (S2Session *s in g_sessions.allValues) if (s.live) { any = YES; break; }
    if (!any) { [g_rumble_timer invalidate]; g_rumble_timer = nil; return; }
    if (g_rumble_timer) return;
    memset(&g_rstat, 0, sizeof g_rstat);
    g_rumble_timer = [NSTimer scheduledTimerWithTimeInterval:S2_RUMBLE_TICK_S repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t now = now_ns();
        if (g_rstat.last && now - g_rstat.last > g_rstat.maxgap) g_rstat.maxgap = now - g_rstat.last;
        g_rstat.last = now; g_rstat.ticks++;
        for (S2Session *s in g_sessions.allValues) [s rumbleTick];
        if (!g_rstat.t0) g_rstat.t0 = now;
        if (now - g_rstat.t0 >= 1000000000ull) {
            if (g_verbose && g_rstat.sent) LOG("[sw2] rumble: %llu ticks (longest gap %.1f ms), %llu packets, %llu while Bluetooth was not ready", (unsigned long long)g_rstat.ticks, g_rstat.maxgap / 1e6, (unsigned long long)g_rstat.sent, (unsigned long long)g_rstat.busy);
            g_rstat.ticks = g_rstat.sent = g_rstat.busy = g_rstat.maxgap = 0; g_rstat.t0 = now;
        }
    }];
}

// The in-game menu changed a paddle slot: put the new value back into the environment and re-log the mapping (s2_buttons reads the env at every report, so nothing else to refresh)
void dm_switch2_paddle_live(const char *env, const char *value) {
    static const char *const slots[6] = {"DM_SW2_GL_1", "DM_SW2_GL_2", "DM_SW2_GL_3", "DM_SW2_GR_1", "DM_SW2_GR_2", "DM_SW2_GR_3"};
    for (int i = 0; i < 6; i++) if (!strcmp(env, slots[i])) {
        setenv(env, value ? value : "-", 1);
        LOG("[sw2] %s = %s (in-game menu)", env, value && *value != '-' ? value : "off");
        return;
    }
}

int dm_switch2_start(const dm_switch2_front *front) {
    const char *e = getenv("DM_SW2"); if (!e || !atoi(e)) return 0;   // off by default: no Bluetooth client, so no permission prompt
    if (![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSBluetoothAlwaysUsageDescription"]) {
        LOG("[sw2] Switch 2 controllers are off: this app's Info.plist has no NSBluetoothAlwaysUsageDescription (an app packed with a newer pack_app.py has it)");
        return 0;
    }
    g_front = *front;
    e = getenv("DM_SW2_VERBOSE"); g_verbose = e && atoi(e);
    e = getenv("DM_PAD_MERGE"); g_joy = !(e && atoi(e));   // merged, every pad is player 1: no pad holds a game's Joy-Cons apart
    e = getenv("DM_SW2_MOTION"); g_motion = !e || atoi(e);
    e = getenv("DM_SW2_MOTION_SIDE"); g_motion_right = !(e && (e[0] == 'L' || e[0] == 'l'));
    e = getenv("DM_SW2_MAP"); if (e && !(g_map_set = s2_map_parse(e, g_map))) LOG("[sw2] DM_SW2_MAP is not six numbers of 1..6 (signs allowed), like -1,-2,-3,4,5,6: using the built-in maps");
    e = getenv("DM_SW2_GYRO_DPS"); if (e && atof(e) > 0) g_gyro = (float)atof(e) * 3.14159265358979323846f / 180.f;
    g_sessions = [NSMutableDictionary new];
    g_delegate = [S2Central new];
    unsigned v[6]; char sep; e = getenv("DM_SW2_HOST");
    if (e && sscanf(e, "%x%c%x%c%x%c%x%c%x%c%x", &v[0], &sep, &v[1], &sep, &v[2], &sep, &v[3], &sep, &v[4], &sep, &v[5]) == 11) { for (int i = 0; i < 6; i++) g_host[i] = (uint8_t)v[5 - i]; g_host_known = 1; }
    s2_central_start();   // the main queue: the pad callbacks run where the front end's do. On the Mac this Mac's address is read once Bluetooth is allowed (centralManagerDidUpdateState)
    return 1;
}
