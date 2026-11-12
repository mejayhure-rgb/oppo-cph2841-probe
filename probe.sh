#!/usr/bin/env bash
# OPPO CPH2841 identity probe v3 — runs in the GitHub Actions job against an
# emulator the workflow launched manually with -writable-system and -prop flags.
# History: v1's rewrite silently failed (remount refused, /system read-only, run
# still green). v2 added disable-verity + an honest verdict, and proved BOTH
# remount and disable-verity are refused ("Device must be bootloader unlocked")
# AND the runner action's -prop flags had zero effect. v3 therefore launches
# the emulator directly with -writable-system (the flag designed to make
# /system writable without unlocking) and passes -prop on that same command
# line, so both mechanisms are exercised with no middleman.
# The verdict is honest: PROBE_RESULT=IDENTITY_APPLIED only if the post-reboot
# getprop shows the CPH2841 model AND device; otherwise exit 1.
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
  return 1
}

core_props() {
  for p in ro.product.model ro.product.device ro.product.name \
           ro.product.manufacturer ro.product.brand ro.build.fingerprint \
           ro.build.display.id ro.build.id ro.build.version.incremental \
           ro.build.version.release ro.build.version.sdk \
           ro.build.version.security_patch ro.build.description; do
    echo "$p=$(adb shell getprop $p | tr -d '\r')"
  done
}

echo "### Phase 0: baseline (includes whatever the launch -prop flags set)"
wait_boot || { echo "BOOT_TIMEOUT_BEFORE_BASELINE"; exit 1; }
echo "=== core props (baseline) ==="
core_props | tee "$OUT/core-baseline.txt"
adb shell getprop > "$OUT/getprop-baseline.txt"
adb exec-out screencap -p > "$OUT/screen-baseline.png" || true

echo "### Phase 1: make /system writable (emulator launched with -writable-system)"
adb root
sleep 2
echo "--- adb remount output:"
adb remount
sleep 2
if adb shell 'touch /system/.probe_write_test && rm /system/.probe_write_test' 2>/dev/null; then
  echo "SYSTEM_WRITABLE=yes"
else
  echo "SYSTEM_WRITABLE=no"
fi

echo "### Phase 2: apply CPH2841 identity to build.props"
cat > /tmp/setprops.sh <<'EOS'
#!/system/bin/sh
apply() {
  f="$1"
  [ -f "$f" ] || return 0
  for kv in \
    "ro.product.model=CPH2841" \
    "ro.product.system.model=CPH2841" \
    "ro.product.vendor.model=CPH2841" \
    "ro.product.odm.model=CPH2841" \
    "ro.product.product.model=CPH2841" \
    "ro.product.system_ext.model=CPH2841" \
    "ro.product.device=OP627CL1" \
    "ro.product.system.device=OP627CL1" \
    "ro.product.vendor.device=OP627CL1" \
    "ro.product.odm.device=OP627CL1" \
    "ro.product.product.device=OP627CL1" \
    "ro.product.system_ext.device=OP627CL1" \
    "ro.product.name=CPH2841EEA" \
    "ro.product.system.name=CPH2841EEA" \
    "ro.product.vendor.name=CPH2841EEA" \
    "ro.product.odm.name=CPH2841EEA" \
    "ro.product.product.name=CPH2841EEA" \
    "ro.product.system_ext.name=CPH2841EEA" \
    "ro.product.manufacturer=OPPO" \
    "ro.product.system.manufacturer=OPPO" \
    "ro.product.vendor.manufacturer=OPPO" \
    "ro.product.odm.manufacturer=OPPO" \
    "ro.product.product.manufacturer=OPPO" \
    "ro.product.system_ext.manufacturer=OPPO" \
    "ro.product.brand=OPPO" \
    "ro.product.system.brand=OPPO" \
    "ro.product.vendor.brand=OPPO" \
    "ro.product.odm.brand=OPPO" \
    "ro.product.product.brand=OPPO" \
    "ro.product.system_ext.brand=OPPO" \
    "ro.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
    "ro.system.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
    "ro.vendor.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
    "ro.odm.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
    "ro.product.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
    "ro.build.display.id=CPH2841_16.0.10.500(EX01)" \
    "ro.build.id=BP2A.250605.015" \
    "ro.build.version.incremental=B.R4T2.aef3b8_1a19661_1a14cbd" \
    "ro.build.version.security_patch=2026-08-01" \
    "ro.build.version.release=16" \
    "ro.build.description=CPH2841EEA-user 16 BP2A.250605.015 B.R4T2.aef3b8_1a19661_1a14cbd release-keys" \
  ; do
    k="${kv%%=*}"
    if grep -q "^${k}=" "$f"; then
      sed -i "s|^${k}=.*|${kv}|" "$f"
    else
      echo "${kv}" >> "$f"
    fi
  done
}
apply /system/build.prop
apply /system/system_ext/etc/build.prop
apply /vendor/build.prop
apply /vendor/odm/etc/build.prop
apply /product/etc/build.prop
EOS
adb push /tmp/setprops.sh /data/local/tmp/setprops.sh
adb shell 'chmod 755 /data/local/tmp/setprops.sh; sh /data/local/tmp/setprops.sh'
echo "--- build.prop on device now contains:"
adb shell 'grep -h "CPH2841" /system/build.prop /vendor/build.prop /product/etc/build.prop 2>/dev/null | head -20'

echo "### Phase 3: reboot and verify"
adb reboot
wait_boot || { echo "BOOT_TIMEOUT_AFTER_REBOOT"; exit 1; }
sleep 3
echo "=== core props (spoofed) ==="
core_props | tee "$OUT/core-spoofed.txt"
adb shell getprop > "$OUT/getprop-spoofed.txt"
adb exec-out screencap -p > "$OUT/screen-spoofed.png" || true

echo "### Phase 4: Google apps surface (no sign-in)"
adb shell pm list packages | grep -iE 'google|vending|gms|android.gms' | sort | tee "$OUT/google-packages.txt"
adb shell monkey -p com.android.vending -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 5
adb exec-out screencap -p > "$OUT/screen-playstore-spoofed.png" || true

{
  echo "# CPH2841 probe summary"
  echo
  echo "## Baseline"
  cat "$OUT/core-baseline.txt"
  echo
  echo "## Spoofed"
  cat "$OUT/core-spoofed.txt"
  echo
  echo "### Verdict"
  m=$(adb shell getprop ro.product.model | tr -d '\r')
  d=$(adb shell getprop ro.product.device | tr -d '\r')
  if [ "$m" = "CPH2841" ] && [ "$d" = "OP627CL1" ]; then
    echo "PROBE_RESULT=IDENTITY_APPLIED"
  else
    echo "PROBE_RESULT=IDENTITY_DID_NOT_APPLY"
  fi
} | tee "$OUT/SUMMARY.md"

m=$(adb shell getprop ro.product.model | tr -d '\r')
d=$(adb shell getprop ro.product.device | tr -d '\r')
if [ "$m" = "CPH2841" ] && [ "$d" = "OP627CL1" ]; then
  exit 0
fi
exit 1
