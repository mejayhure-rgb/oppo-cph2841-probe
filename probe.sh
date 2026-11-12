#!/usr/bin/env bash
# OPPO CPH2841 identity probe v2 — runs in the GitHub Actions job while the emulator is up.
# Fix vs v1: run #1's rewrite silently failed because `adb remount` was refused
# ("Device must be bootloader unlocked") and /system stayed read-only. v2 disables
# verity first (standard path for google_apis userdebug images), verifies the
# filesystem is actually writable and that CPH2841 landed in build.prop BEFORE
# rebooting, and fails the step honestly if the identity does not stick.
# Identity also comes from emulator -prop launch flags (set in the workflow),
# so getprop is the judge of both mechanisms combined.
set -u
OUT="probe-results"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/probe.log") 2>&1

wait_boot() {
  adb wait-for-device
  for i in $(seq 1 60); do
    v=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$v" = "1" ] && return 0
    sleep 5
  done
  echo "WARN: boot_completed not seen within timeout"
}

core_props() {
  for k in ro.product.model ro.product.device ro.product.name ro.product.manufacturer \
           ro.product.brand ro.build.fingerprint ro.build.display.id ro.build.id \
           ro.build.version.incremental ro.build.version.release ro.build.version.sdk \
           ro.build.version.security_patch ro.build.description; do
    printf '%s=%s\n' "$k" "$(adb shell getprop "$k" | tr -d '\r')"
  done
}

capture() {
  label="$1"
  adb shell getprop > "$OUT/getprop-$label.txt" 2>/dev/null
  core_props > "$OUT/core-$label.txt"
  adb exec-out screencap -p > "$OUT/screen-$label.png" 2>/dev/null || true
  echo "=== core props ($label) ==="
  cat "$OUT/core-$label.txt"
}

echo "### Phase 0: baseline"
wait_boot
capture baseline

echo "### Phase 1: make /system writable (disable-verity path)"
adb root || true
adb wait-for-device
echo "--- adb disable-verity output:"
adb disable-verity || true
adb reboot
wait_boot
adb root || true
adb wait-for-device
echo "--- adb remount output:"
adb remount || true
WRITABLE="no"
if adb shell "touch /system/.wtest 2>/dev/null && rm /system/.wtest && echo ok" | grep -q ok; then
  WRITABLE="yes"
fi
echo "SYSTEM_WRITABLE=$WRITABLE"

echo "### Phase 2: apply CPH2841 identity to build.props"
cat > /tmp/setprops.sh <<'EOS'
#!/system/bin/sh
FP='OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys'
setkv() {
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  fi
}
appendkv() {
  if grep -q "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    echo "$2=$3" >> "$1"
  fi
}
for f in /system/build.prop /system/system/build.prop /vendor/build.prop /product/build.prop /system_ext/build.prop /odm/build.prop; do
  [ -f "$f" ] || continue
  for part in "" system. vendor. product. system_ext. odm.; do
    setkv "$f" "ro.product.${part}model" "CPH2841"
    setkv "$f" "ro.product.${part}device" "OP627CL1"
    setkv "$f" "ro.product.${part}name" "CPH2841EEA"
    setkv "$f" "ro.product.${part}manufacturer" "OPPO"
    setkv "$f" "ro.product.${part}brand" "OPPO"
  done
  for part in "" system. vendor. product. system_ext. odm. bootimage.; do
    setkv "$f" "ro.${part}build.fingerprint" "$FP"
  done
done
SYS=/system/build.prop
[ -f /system/system/build.prop ] && SYS=/system/system/build.prop
appendkv "$SYS" ro.product.model CPH2841
appendkv "$SYS" ro.product.device OP627CL1
appendkv "$SYS" ro.product.name CPH2841EEA
appendkv "$SYS" ro.product.manufacturer OPPO
appendkv "$SYS" ro.product.brand OPPO
appendkv "$SYS" ro.build.fingerprint "$FP"
appendkv "$SYS" ro.build.display.id 'CPH2841_16.0.10.500(EX01)'
appendkv "$SYS" ro.build.id BP2A.250605.015
appendkv "$SYS" ro.build.version.incremental 'B.R4T2.aef3b8_1a19661_1a14cbd'
appendkv "$SYS" ro.build.version.security_patch 2026-08-01
appendkv "$SYS" ro.build.version.release 16
appendkv "$SYS" ro.build.description 'CPH2841EEA-user 16 BP2A.250605.015 B.R4T2.aef3b8_1a19661_1a14cbd release-keys'
sync
EOS
adb push /tmp/setprops.sh /data/local/tmp/setprops.sh
adb shell "sh /data/local/tmp/setprops.sh"
echo "--- build.prop on device now contains:"
adb shell "grep -h 'CPH2841' /system/build.prop /system/system/build.prop 2>/dev/null | head -20"

echo "### Phase 3: reboot and verify"
adb reboot
wait_boot
sleep 5
capture spoofed

echo "### Phase 4: Google apps surface (no sign-in)"
adb shell monkey -p com.android.vending 1 >/dev/null 2>&1 || true
sleep 8
adb exec-out screencap -p > "$OUT/screen-playstore-spoofed.png" 2>/dev/null || true
adb shell pm list packages 2>/dev/null | grep -iE "one|gemini|vending|gms" > "$OUT/google-packages.txt" || true
cat "$OUT/google-packages.txt" || true

echo "### Summary"
{
  echo "# CPH2841 probe summary"
  echo
  echo "## Baseline"
  cat "$OUT/core-baseline.txt"
  echo
  echo "## Spoofed"
  cat "$OUT/core-spoofed.txt"
} > "$OUT/SUMMARY.md"
cat "$OUT/SUMMARY.md"

echo "### Verdict"
if grep -q "^ro.product.model=CPH2841$" "$OUT/core-spoofed.txt" && grep -q "^ro.product.device=OP627CL1$" "$OUT/core-spoofed.txt"; then
  echo "PROBE_RESULT=IDENTITY_APPLIED"
else
  echo "PROBE_RESULT=IDENTITY_DID_NOT_APPLY"
  exit 1
fi
echo "### Done"
