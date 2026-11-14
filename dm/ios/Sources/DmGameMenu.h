// The in-game menu: GameMenu.swift builds it, the gamepad's menu button at the top centre opens it (DmGamepad.m). It holds the controller layout and the launcher
// settings the running game takes at once (front_ios.m dm_setting_live); the other settings stay on the settings screen before the game starts.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
void *dm_game_menu(void);   // GameMenu.swift: a retained UIMenu, rebuilt each time it opens
int dm_pad_layout(void);   // DmGamepad.m: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
bool dm_pad_layout_offered(int layout);   // Tap only in handheld mode
void dm_pad_layout_set(int layout);   // releases every touch first, and is saved for the next start
void dm_gamepad_touch_feedback(bool on);   // DM_TOUCH_HAPTICS
bool dm_setting_live(const char *env, const char *value);   // front_ios.m: value NULL asks whether the running game takes env at once; otherwise applies it
void dm_switch2_ensure_started(void);   // DmGamepad.m: starts the Switch 2 BLE transport once; the launcher calls it so a pad pairs before the game starts
const char *dm_switch2_bond_status(void);   // pad_switch2_apple.m: last bond() step receipts (pad_switch2_apple.m g_sw2_bond_status), for the test view
const char *dm_switch2_flash_status(void);   // pad_switch2_apple.m: what the post-bond user-flash dump showed (sentinel landed? a real console's record?)
void dm_switch2_set_host(const char *addr);   // pad_switch2_apple.m: set this host's Bluetooth address at runtime (test view; read the value from an Android nRF scan of this device's advert)
void dm_switch2_rumble_test(void);            // pad_switch2_apple.m: ~1 s of strong rumble through the game's rumble path (test view)
const char *dm_switch2_info_status(void);    // pad_switch2_apple.m: what the 0x13000 info block showed (the pad saw our real radio address — did it record it?)

// Switch 2 test view (Launcher.swift): a flat pad snapshot so Swift needs no C struct access
typedef struct dm_s2_test_row { unsigned pid, buttons; unsigned short lx, ly, rx, ry, battery_mv; } dm_s2_test_row;
int dm_switch2_test_rows(dm_s2_test_row *out, int cap);   // DmGamepad.m: fills up to cap rows, returns the pad count
#ifdef __cplusplus
}
#endif
