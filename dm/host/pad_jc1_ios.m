// Joy-Con (1st generation) direct BLE probe for iOS (pad_jc1_ios.m; surfaced in the test view, Launcher.swift).
// The Mac reads 1st-gen Joy-Cons through the system's HID stack (pad_jc1_mac.h), which iOS apps don't get. This probe
// answers one question over CoreBluetooth as a plain GATT central: does the pad stream input reports to an app-level
// connection (HID service 0x1812, report characteristic 0x2A4D) without the system claiming it first? Reports flowing
// = the Mac's parsing (pad_jc1.h) can sit on top of this transport. A subscription that needs a bond the system steals
// = iOS 1st-gen Joy-Con is dead, like Switch 2 wake-from-button was. The pad must NOT be paired in iOS Settings.
// Everything runs on the main queue, like the Switch 2 transport (pad_switch2_apple.m).
#if !TARGET_OS_OSX

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <stdio.h>

static char g_jc1_status[384] = "未启动";
static char g_jc1_last[96] = "-";
static int g_jc1_count;
static int g_jc1_running;

@interface JC1Probe : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

static JC1Probe *g_jc1_probe;

@implementation JC1Probe {
    CBCentralManager *_cm;
    CBPeripheral *_per;
    NSMutableArray<CBCharacteristic *> *_reports;   // every 2A4D (HOGP names input and output report characteristics alike)
    NSMutableDictionary<NSUUID *, NSString *> *_names;  // identifier -> advertised name (may be empty)
    NSMutableDictionary<NSUUID *, NSNumber *> *_hid;    // identifier -> YES if advert carried HID 0x1812
    NSMutableDictionary<NSUUID *, NSNumber *> *_rssi;   // identifier -> last RSSI
    int _advCount;   // every advert callback
    int _devCount;   // distinct devices seen
    int _nudgeCount;
    BOOL _nudged;
}

- (void)start {
    [self stop];   // clean slate if a run is live
    g_jc1_count = 0;
    snprintf(g_jc1_last, sizeof g_jc1_last, "-");
    _reports = [NSMutableArray new];
    _names = [NSMutableDictionary new];
    _hid = [NSMutableDictionary new];
    _rssi = [NSMutableDictionary new];
    _advCount = 0;
    _devCount = 0;
    _nudgeCount = 0;
    _nudged = NO;
    g_jc1_running = 1;
    snprintf(g_jc1_status, sizeof g_jc1_status, "蓝牙启动中…（手柄别在 iOS 设置里配对，系统会独占）");
    _cm = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
}

- (void)stop {
    if (_per && _cm) [_cm cancelPeripheralConnection:_per];
    if (_cm) [_cm stopScan];
    _per = nil;
    _cm = nil;
    _reports = nil;
    if (g_jc1_running) snprintf(g_jc1_status, sizeof g_jc1_status, "已停止（收到 %d 条报表）", g_jc1_count);
    g_jc1_running = 0;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state != CBManagerStatePoweredOn) {
        if (g_jc1_running) snprintf(g_jc1_status, sizeof g_jc1_status, "蓝牙不可用（状态 %ld）", (long)central.state);
        return;
    }
    // AllowDuplicates is mandatory: the first report often carries no local name (it lives in the scan response),
    // and with duplicate filtering on we would drop the pad forever after one unnamed sighting — the exact bug v1 had.
    [_cm scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @YES}];
    snprintf(g_jc1_status, sizeof g_jc1_status, "扫描所有广播…（按住手柄顶部 Sync 键进入配对）");
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)per advertisementData:(NSDictionary<NSString *, id> *)adv RSSI:(NSNumber *)rssi {
    _advCount++;
    if (!_names[per.identifier]) _devCount++;
    NSString *name = per.name;
    if (name.length == 0) name = (NSString *)adv[CBAdvertisementDataLocalNameKey];
    if (name.length == 0) name = @"";
    _names[per.identifier] = name;                       // remember even if empty
    NSArray *uuids = (NSArray *)adv[CBAdvertisementDataServiceUUIDsKey];
    BOOL has1812 = NO;
    for (CBUUID *u in uuids)
        if ([u.UUIDString.lowercaseString isEqualToString:@"1812"]) { has1812 = YES; break; }
    if (has1812) _hid[per.identifier] = @YES;
    _rssi[per.identifier] = rssi;
    if (_per) return;   // already pursuing one
    NSString *known = name;
    if (known.length >= 7 && [known.lowercaseString containsString:@"joy-con"]) {
        _per = per;
        _per.delegate = self;
        [_cm stopScan];
        snprintf(g_jc1_status, sizeof g_jc1_status, "发现 %s（%@ dBm），连接…", known.UTF8String, rssi);
        [_cm connectPeripheral:per options:nil];
        return;
    }
    if (has1812) {   // HID service in the advert itself: input device even without a usable name
        _per = per;
        _per.delegate = self;
        [_cm stopScan];
        snprintf(g_jc1_status, sizeof g_jc1_status, "发现 HID 设备（%@ dBm，名字\"%s\"），连接…", rssi, known.UTF8String);
        [_cm connectPeripheral:per options:nil];
        return;
    }
    // Live discovery feed: every device with name (or UUID stub) + RSSI + HID tag, so nothing hides.
    NSMutableArray<NSString *> *shown = [NSMutableArray new];
    for (NSUUID *k in _names.allKeys) {
        if (shown.count >= 4) break;
        NSString *n = _names[k];
        NSString *label = n.length ? [n substringToIndex:MIN(n.length, 12)] : [k.UUIDString substringToIndex:8];
        NSString *tag = _hid[k] ? @" [HID]" : @"";
        [shown addObject:[NSString stringWithFormat:@"%@(%@dBm)", [label stringByAppendingString:tag], _rssi[k]]];
    }
    snprintf(g_jc1_status, sizeof g_jc1_status, "广播 %d 包 / %d 台：%s%s（找 Joy-Con…）",
             _advCount, _devCount, shown.count ? [shown componentsJoinedByString:@" "].UTF8String : "（空）",
             _devCount > 4 ? "…" : "");
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)per {
    snprintf(g_jc1_status, sizeof g_jc1_status, "已连接，找 HID 服务 0x1812…");
    [per discoverServices:@[[CBUUID UUIDWithString:@"1812"]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)per error:(NSError *)error {
    snprintf(g_jc1_status, sizeof g_jc1_status, "❌ 连接失败：%s", error.localizedDescription.UTF8String);
    _per = nil;
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)per error:(NSError *)error {
    snprintf(g_jc1_status, sizeof g_jc1_status, "连接断开（收到 %d 条）：%s", g_jc1_count, error.localizedDescription.UTF8String);
    _per = nil;
}

- (void)peripheral:(CBPeripheral *)per didDiscoverServices:(NSError *)error {
    if (per.services.count == 0) {
        snprintf(g_jc1_status, sizeof g_jc1_status, "❌ 没有 0x1812 HID 服务（%s）", error.localizedDescription.UTF8String);
        return;
    }
    snprintf(g_jc1_status, sizeof g_jc1_status, "HID 服务在，找特征…");
    [per discoverCharacteristics:nil forService:per.services.firstObject];
}

- (NSString *)propNames:(CBCharacteristic *)c {
    NSMutableArray<NSString *> *p = [NSMutableArray new];
    if (c.properties & CBCharacteristicPropertyRead) [p addObject:@"读"];
    if (c.properties & CBCharacteristicPropertyWriteWithoutResponse) [p addObject:@"写NR"];
    if (c.properties & CBCharacteristicPropertyWrite) [p addObject:@"写"];
    if (c.properties & CBCharacteristicPropertyNotify) [p addObject:@"通知"];
    return [p componentsJoinedByString:@"/"];
}

- (void)peripheral:(CBPeripheral *)per didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    NSMutableString *list = [NSMutableString new];
    for (CBCharacteristic *c in service.characteristics) {
        [list appendFormat:@"%@[%@] ", c.UUID.UUIDString, [self propNames:c]];
        if ([c.UUID.UUIDString isEqualToString:@"2A4D"]) [_reports addObject:c];
    }
    snprintf(g_jc1_status, sizeof g_jc1_status, "特征：%s→ 订阅报表…", list.UTF8String);
    for (CBCharacteristic *c in _reports) [per setNotifyValue:YES forCharacteristic:c];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!_nudged && g_jc1_count == 0 && _reports.count > 0) [self nudge];
    });
}

// No reports six seconds after subscribing: ask for the simple HID report the plain way — output report 0x01,
// counter, 11 zero rumble bytes, subcommand 0x03 "set input report mode", argument 0x3F (dekuNukem's Joy-Con notes).
// The report ID itself travels in HOGP's report-reference descriptor, not in the written bytes.
- (void)nudge {
    _nudged = YES;
    CBCharacteristic *out = nil;
    for (CBCharacteristic *c in _reports)
        if (c.properties & CBCharacteristicPropertyWriteWithoutResponse) { out = c; break; }
    if (!out)
        for (CBCharacteristic *c in _reports)
            if (c.properties & CBCharacteristicPropertyWrite) { out = c; break; }
    if (!out) {
        snprintf(g_jc1_status, sizeof g_jc1_status, "订阅了但没有可写特征；等报表（%d 条）", g_jc1_count);
        return;
    }
    uint8_t p[14] = {0};
    p[0] = (uint8_t)(++_nudgeCount & 0xff);
    p[12] = 0x03;
    p[13] = 0x3F;
    NSData *d = [NSData dataWithBytes:p length:sizeof p];
    if (out.properties & CBCharacteristicPropertyWriteWithoutResponse)
        [_per writeValue:d forCharacteristic:out type:CBCharacteristicWriteWithoutResponse];
    else
        [_per writeValue:d forCharacteristic:out type:CBCharacteristicWriteWithResponse];
    snprintf(g_jc1_status, sizeof g_jc1_status, "已发 0x3F 模式请求（等报表…收到 %d 条）", g_jc1_count);
}

- (void)peripheral:(CBPeripheral *)per didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    if (error) snprintf(g_jc1_status, sizeof g_jc1_status, "❌ 订阅失败：%s（弹配对框就点允许）", error.localizedDescription.UTF8String);
}

- (void)peripheral:(CBPeripheral *)per didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error {
    if (error) return;
    NSData *v = c.value;
    if (v.length == 0) return;
    g_jc1_count++;
    const uint8_t *b = v.bytes;
    NSMutableString *hex = [NSMutableString stringWithFormat:@"%zuB/%@:", v.length, c.UUID.UUIDString];
    for (NSUInteger i = 0; i < v.length && i < 10; i++) [hex appendFormat:@" %02X", b[i]];
    snprintf(g_jc1_last, sizeof g_jc1_last, "%s", hex.UTF8String);
    snprintf(g_jc1_status, sizeof g_jc1_status, "✅ 报表在流！按按键/摇杆看字节变（%d 条）——传输层可行", g_jc1_count);
}

@end

void dm_jc1_probe_start(void) {
    if (!g_jc1_probe) g_jc1_probe = [JC1Probe new];
    [g_jc1_probe start];
}

void dm_jc1_probe_stop(void) {
    [g_jc1_probe stop];
}

const char *dm_jc1_probe_status(void) { return g_jc1_status; }
const char *dm_jc1_probe_last(void) { return g_jc1_last; }
int dm_jc1_probe_count(void) { return g_jc1_count; }
int dm_jc1_probe_running(void) { return g_jc1_running; }

#else   // Mac: the probe is an iOS question — the Mac reads 1st-gen Joy-Cons through the HID stack already
typedef int dm_jc1_ios_probe_not_for_mac;
#endif
