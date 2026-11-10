#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[64];
    char serial[32];
    int player;          // 1..8
    int battery_percent; // 0..100, or -1 if unknown
    int battery_mv;      // millivolts, e.g. 3850
    int charging;        // the battery current is positive (the feature the mask enables at 0x20)
    int rssi;
    bool connected;
} dm_switch2_controller_info;

void dm_switch2_ble_start(void);   // kit-d3: renamed from dm_switch2_start to stay clear of upstream's pad_switch2_apple.m (its dm_switch2_start(const dm_switch2_front*) is linked into iOS by gen_build and dead-strips unused)
void dm_switch2_scan_start(void);
void dm_switch2_scan_stop(void);
bool dm_switch2_is_scanning(void);
int dm_switch2_get_controllers(dm_switch2_controller_info *out, int max_count);
void dm_switch2_disconnect(int player);
void dm_switch2_test_rumble(int player);
void dm_switch2_find(int player);   // the player's controller flashes its LEDs and pulses its motors so it can be found among others

#ifdef __cplusplus
}
#endif
