#!/bin/sh
# objc_lint.sh — local syntax gate for dm/host/*.m BEFORE push.
# Why: cloud build is a 7-minute round trip; every ObjC compile error wastes one.
# Proven: catches dot-syntax-with-args (2026-11-15 incident), ARC switch-case init,
# misplaced @implementation methods — all real errors that cost build rounds.
# Usage: objc_lint.sh [file.m ...]   (default: both BLE transports)
DIR="$(cd "$(dirname "$0")" && pwd)"
FILES="${*:-$DIR/pad_jc1_ios.m $DIR/pad_switch2_apple.m}"
RC=0
for f in $FILES; do
  N=$(clang -fsyntax-only -x objective-c -fobjc-arc -fobjc-runtime=ios-17.0 -fblocks \
      -D TARGET_OS_OSX=0 -Wno-int-conversion -Wno-incompatible-pointer-types \
      -I "$DIR/objc_lint" -I "$DIR" "$f" 2>&1 | { grep -c ' error:' || true; })
  if [ "$N" = "0" ]; then echo "PASS $f"
  else echo "FAIL $f ($N errors):"; clang -fsyntax-only -x objective-c -fobjc-arc -fobjc-runtime=ios-17.0 -fblocks \
      -D TARGET_OS_OSX=0 -Wno-int-conversion -Wno-incompatible-pointer-types \
      -I "$DIR/objc_lint" -I "$DIR" "$f" 2>&1 | grep ' error:' | head -8; RC=1; fi
done
exit $RC
