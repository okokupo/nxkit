#pragma once
// lint shim: Apple's os/lock.h (real one is on macOS/iOS SDK)
#include "../stubs.h"
void os_unfair_lock_lock(os_unfair_lock *l);
void os_unfair_lock_unlock(os_unfair_lock *l);
