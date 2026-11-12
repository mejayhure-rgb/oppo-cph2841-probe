#!/usr/bin/env bash
# OPPO CPH2841 identity probe v10.5 — runs in the GitHub Actions job against an
# emulator the workflow launched manually with -writable-system.
# Run #8 (v6) SUCCEEDED: second remount flipped the overlays rw,
# SYSTEM_WRITABLE=yes, PROBE_RESULT=IDENTITY_APPLIED with the full verified
# CPH2841 prop set persisting across reboot. v7 keeps the v6 identity flow,
# adds the system_dlkm build.prop + ro.build.flavor/product props (second-order
# leftovers named in run #8's full getprop audit; ro.bootimage.* still needs
# ramdisk work), and adds Phase 5: fetch the Google One APK (APKPure direct),
# print its signer cert via apksigner (workflow v3.4 installs build-tools),
# install it, set the global device name, launch it WITHOUT any account, and
# capture the first screen + package info + filtered logcat — the pre-sign-in
# offer surface. The eligibility verdict itself still needs a throwaway
# account, which is a later phase.
# v8: run #9 (v7) applied the identity incl. the second-order props, but
# Phase 5 failed — APKPure's download is an XAPK bundle (a zip of split
# APKs), so the plain install failed to parse it and apksigner printed
# nothing on the container. v8 detects the bundle, extracts it, verifies
# the signer on the base APK, and installs base + emulator-compatible
# splits with install-multiple.
# v9: run #10 verified the bundle's signer as Google's genuine cert
# (O=Google Inc., SHA-256 e357f022…) but install failed with
# INSTALL_FAILED_MISSING_SPLIT — v8's filter excluded the ABI split the
# base APK requires. v9 installs ALL splits in the bundle (including
# config.arm64_v8a; the Android 14 x86_64 emulator image carries ARM
# translation) and fixes the device_name quoting.
# v10: Phase 6 — throwaway-account sign-in (credentials ONLY from GitHub
# repo secrets passed as env; never echoed, never committed) with TOTP
# 2-Step Verification codes generated in-runner from the setup key, then
# the Google One Benefits surface captured by screenshots + UI text.
# Observation only: Phase 6 never taps Redeem, Claim, Subscribe, Get or
# Buy, and stops before any payment step.
# v10.1: run #12 hung forever in Phase 3 — wait_boot's `adb wait-for-device`
# has no timeout and the emulator never re-registered after the identity
# reboot. wait_boot now bounds every adb call, Phase 3 retries once after
# an adb-server restart, and Phase 6's dump/screencap calls get timeouts.
# v10.2: run #13 finished cleanly but the sign-in never left the welcome
# screen — a "System UI isn't responding" dialog (starved 2-core runner)
# covered every Phase 6 screen, so taps and dumps hit the dialog instead
# of the app (SIGNIN_RESULT=not_confirmed). Phase 6 now runs an ANR
# watchdog (taps "Wait") before interactions and verifies the email step
# actually advanced before continuing; workflow v3.6 gives the emulator
# 4 cores + 4 GB RAM.
# v10.3: run #14 had no ANR, and the Sign In tap DID fire — screenshots
# show GMS's "Checking info…" express-sign-in screen — but the flow fell
# back to the welcome screen without ever presenting an email field to
# the fixed-sleep script, which then typed into nothing again. Phase 6
# now enters via Settings → Add account → Google (the classic GMS flow
# instead of Google One's express sign-in), POLLS for each screen with a
# text timeline in the log instead of fixed sleeps, and captures the
# sign-in window's logcat — so a bounce becomes diagnosable, not silent.
# v10.4: run #15 wedged at the same Phase 3 reboot as run #12 — the
# adb-server restart retry also failed because the GUEST never came
# back (v10.1's timeouts at least failed it honestly in ~11 min).
# Phase 3 now syncs before rebooting and, if the guest stays gone,
# relaunches the emulator process once: the identity writes persist
# in the AVD's overlayfs, so the relaunched boot should come up
# already spoofed.
# v10.5: run #16's classic flow WORKED up to the password screen — the
# email was accepted and the screenshot shows the empty password field
# waiting — but the password-screen detector missed it ("Enter your
# password" is the field's HINT, not a text node, so the dump never
# contained it), and the 2SV loop then fatally tapped "Try another
# way" on the password screen, walked into the method chooser, and
# landed on Google's "Couldn't sign you in / didn't provide enough
# info" risk page. The password was never submitted, so that page is
# NOT a verdict on the clean flow. v10.5: detect the password screen
# via "Show password" + read hint attributes in UI texts; the 2SV
# loop recognizes the risk-gate page as a terminal verdict, handles
# the method chooser explicitly, and taps "Try another way" at most
# once — never on the password screen.
# History: v1's rewrite silently failed (remount refused, /system read-only, run
# still green). v2 added disable-verity + an honest verdict, and proved BOTH
# remount and disable-verity are refused ("Device must be bootloader unlocked")
# AND the runner action's -prop flags had zero effect. v3 launched the emulator
# directly with -writable-system. Run #5 (v3) then settled two things from the
# emulator's own logs: (1) modern emulator -prop accepts ONLY qemu.* props —
# every ro.* -prop was rejected with a warning, so that mechanism is dead;
# (2) `adb remount` under -writable-system SUCCEEDS (verity disabled, overlayfs
# enabled for /system, /vendor, /product) but only takes effect AFTER a reboot
# ("Now reboot your device for settings to take effect") — v3 checked
# writability and wrote files before that reboot, so all writes still failed.
# v4 therefore reorders: remount -> reboot -> verify writable -> write -> reboot
# -> verdict.
# Run #6 (v4): SYSTEM_WRITABLE was STILL no after remount + reboot — run #5's
# remount output explains why: "could not map scratch image", "Failed to
# allocate scratch on /data, fallback to use free space on super". The overlayfs
# scratch backing the writable mounts never got created, so nothing persisted.
# v5 pairs with workflow v3.3, which grows the AVD data partition to 8G (room
# for the scratch on /data), and adds df/mount diagnostics after the
# remount-reboot so the next failure, if any, names itself.
# Run #7 (v5): diagnostics showed /data had 7.1G free (space was never the
# issue) and the overlays DO mount after the reboot — but every overlay is
# mounted RO (overlay on /system type overlay (ro,...)). The standard
# hardware sequence has one more step in exactly this position: a SECOND
# `adb remount` after the reboot, which flips the existing overlays rw in the
# current boot. v6 adds it. If the overlays still come up ro, this family is
# exhausted and the probe pivots to the Magisk/rootAVD route.
# The verdict is honest: PROBE_RESULT=IDENTITY_APPLIED only if the post-reboot
# getprop shows the CPH2841 model AND device; otherwise exit 1.
set -u
OUT="probe-results"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/probe.log") 2>&1

wait_boot() {
  # `adb wait-for-device` has NO built-in timeout: in run #12 the emulator
  # never re-registered after reboot and it blocked forever. Bound it, and
  # bound each getprop poll as well.
  timeout 120 adb wait-for-device || return 1
  for i in $(seq 1 60); do
    v=$(timeout 15 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
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
echo "--- on this image remount enables overlayfs only after a reboot; rebooting, then re-checking"
adb reboot
wait_boot || { echo "BOOT_TIMEOUT_AFTER_REMOUNT_REBOOT"; exit 1; }
adb root
sleep 2
echo "--- second adb remount in this boot (standard step that flips the overlays rw):"
adb remount
sleep 2
echo "--- diagnostics after remount + reboot + second remount:"
adb shell 'df -h /data /system 2>/dev/null; echo ---; mount | grep -iE "overlay| /system | /vendor | /product "'
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
    "ro.build.flavor=CPH2841EEA-user" \
    "ro.build.product=OP627CL1" \
    "ro.product.system_dlkm.model=CPH2841" \
    "ro.product.system_dlkm.device=OP627CL1" \
    "ro.product.system_dlkm.name=CPH2841EEA" \
    "ro.product.system_dlkm.manufacturer=OPPO" \
    "ro.product.system_dlkm.brand=OPPO" \
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
apply /system/system_dlkm/etc/build.prop
apply /vendor/build.prop
apply /vendor/odm/etc/build.prop
apply /product/etc/build.prop
EOS
adb push /tmp/setprops.sh /data/local/tmp/setprops.sh
adb shell 'chmod 755 /data/local/tmp/setprops.sh; sh /data/local/tmp/setprops.sh'
echo "--- build.prop on device now contains:"
adb shell 'grep -h "CPH2841" /system/build.prop /vendor/build.prop /product/etc/build.prop 2>/dev/null | head -20'

echo "### Phase 3: reboot and verify"
adb shell sync || true
sleep 3
timeout 30 adb reboot || true
if ! wait_boot; then
  echo "--- boot wait failed; restarting the adb server and retrying once"
  adb kill-server; sleep 2; adb start-server
  if ! wait_boot; then
    echo "--- guest still not back; relaunching the emulator ONCE (identity persists in the AVD overlay)"
    export ANDROID_AVD_HOME="$HOME/.android/avd"
    timeout 20 adb emu kill || true
    pkill -f "emulator -avd probe" || true
    for i in $(seq 1 6); do pgrep -f "emulator -avd probe" >/dev/null || break; sleep 5; done
    nohup emulator -avd probe -cores 4 -memory 4096 -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -no-snapshot -writable-system \
      -prop ro.product.model=CPH2841 \
      -prop ro.product.device=OP627CL1 \
      -prop ro.product.name=CPH2841EEA \
      -prop ro.product.manufacturer=OPPO \
      -prop ro.product.brand=OPPO \
      -prop "ro.build.fingerprint=OPPO/CPH2841EEA/OP627CL1:16/BP2A.250605.015/B.R4T2.aef3b8_1a19661_1a14cbd:user/release-keys" \
      > "$OUT/emulator-relaunch.log" 2>&1 &
    wait_boot || { echo "BOOT_TIMEOUT_AFTER_REBOOT"; exit 1; }
  fi
fi
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

echo "### Phase 5: Google One install + offer surface (no sign-in)"
APK=/tmp/google-one.apk
fetch_ok=no
echo "--- trying APKPure direct download for com.google.android.apps.subscriptions.red"
if curl -L --fail --max-time 240 -A "Mozilla/5.0 (X11; Linux x86_64)" -o "$APK" "https://d.apkpure.com/b/APK/com.google.android.apps.subscriptions.red?version=latest" && [ -s "$APK" ]; then
  if file "$APK" | grep -qi "zip"; then fetch_ok=yes; echo "download looks like a zip/APK package"; fi
fi
[ "$fetch_ok" = "yes" ] || echo "GOOGLE_ONE_FETCH=failed"
ls -la "$APK" 2>/dev/null || true
APKSIGNER=$(ls "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | head -1)
if [ "$fetch_ok" = "yes" ]; then
  # APKPure's direct endpoint serves an XAPK bundle (a zip of split APKs),
  # not a single APK — run #9's plain `adb install` failed to parse the
  # container and apksigner printed nothing on it. If the download contains
  # .apk entries, extract it, verify the signer on the BASE apk, and
  # install-multiple ALL splits in the bundle (the base requires its ABI
  # split — a filtered selection failed with MISSING_SPLIT in run #10).
  # Otherwise treat it as a single APK as before.
  INSTALL_TARGET="$APK"
  PARTS=""
  if unzip -l "$APK" 2>/dev/null | grep -q '\.apk'; then
    BUNDLE=/tmp/g1bundle
    rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"
    unzip -o -q "$APK" -d "$BUNDLE"
    BASE=$(find "$BUNDLE" -name 'com.google.android.apps.subscriptions.red*.apk' | head -1)
    [ -z "$BASE" ] && BASE=$(find "$BUNDLE" -name '*.apk' | head -1)
    if [ -n "$BASE" ]; then
      INSTALL_TARGET="$BASE"
      PARTS=$(find "$BUNDLE" -name '*.apk' | sort | tr '\n' ' ')
    fi
    echo "--- bundle contents:"; find "$BUNDLE" -type f | head -20
    echo "--- install parts: $PARTS"
  fi
  if [ -n "$APKSIGNER" ]; then
    echo "--- APK signer certificate (on $INSTALL_TARGET):"
    "$APKSIGNER" verify --print-certs "$INSTALL_TARGET" 2>&1 | head -8
    echo "GOOGLE_ONE_SIGNER=printed_above"
  else
    echo "GOOGLE_ONE_SIGNER=unknown_no_apksigner"
  fi
  if [ -n "$PARTS" ]; then
    adb install-multiple -r $PARTS && echo "GOOGLE_ONE_INSTALL=ok" || echo "GOOGLE_ONE_INSTALL=failed"
  else
    adb install -r "$APK" && echo "GOOGLE_ONE_INSTALL=ok" || echo "GOOGLE_ONE_INSTALL=failed"
  fi
  adb shell 'settings put global device_name "OPPO Find X9 Ultra"' || true
  adb shell monkey -p com.google.android.apps.subscriptions.red -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 8
  adb exec-out screencap -p > "$OUT/screen-googleone-1.png" || true
  adb shell dumpsys package com.google.android.apps.subscriptions.red 2>/dev/null | grep -E "versionName|versionCode|firstInstallTime|installerPackageName" | head -6 | tee "$OUT/google-one-package.txt" || true
  adb logcat -d 2>/dev/null | grep -iE "subscriptions.red|GoogleOne|one\.google" | head -40 > "$OUT/google-one-logcat.txt" || true
fi

echo "### Phase 6: throwaway sign-in + Google One Benefits surface (NO redemption)"
# Credentials come ONLY from env (GitHub repo secrets, workflow v3.5).
# They are never echoed here; generated TOTP codes are used and unset.
if [ -z "${THROWAWAY_EMAIL:-}" ] || [ -z "${THROWAWAY_PASSWORD:-}" ] || [ -z "${THROWAWAY_TOTP_SECRET:-}" ]; then
  echo "SIGNIN_RESULT=skipped_no_secrets"
else
  shot() { timeout 30 adb exec-out screencap -p > "$OUT/$1" || true; }
  ui_dump() { timeout 25 adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; timeout 15 adb exec-out cat /sdcard/ui.xml 2>/dev/null; }
  cat > /tmp/uihelp.py <<'PYEOF'
import sys, re, xml.etree.ElementTree as ET
def center(n):
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds') or '')
    if not m: return None
    a, b, c, d = map(int, m.groups()); return ((a + c) // 2, (b + d) // 2)
try:
    root = ET.fromstring(sys.stdin.buffer.read().decode('utf-8', 'ignore'))
except Exception:
    sys.exit(1)
mode = sys.argv[1]
if mode == 'texts':
    for n in root.iter('node'):
        t = n.get('text') or n.get('hint')
        if t: print(t)
elif mode == 'tap':
    frag = sys.argv[2].lower()
    cfrag = sys.argv[3].lower() if len(sys.argv) > 3 else ''
    for n in root.iter('node'):
        label = ((n.get('text') or '') + ' ' + (n.get('content-desc') or '')).lower()
        cls = (n.get('class') or '').lower()
        if frag in label and (not cfrag or cfrag in cls):
            c = center(n)
            if c: print(c[0], c[1]); sys.exit(0)
    sys.exit(1)
elif mode == 'field':
    for n in root.iter('node'):
        if 'edittext' in (n.get('class') or '').lower():
            c = center(n)
            if c: print(c[0], c[1]); sys.exit(0)
    sys.exit(1)
PYEOF
  ui_texts() { ui_dump | python3 /tmp/uihelp.py texts 2>/dev/null; }
  tap_text() { local xy; xy=$(ui_dump | python3 /tmp/uihelp.py tap "$1" "${2:-}" 2>/dev/null) && [ -n "$xy" ] && adb shell input tap $xy; }
  tap_field() { local xy; xy=$(ui_dump | python3 /tmp/uihelp.py field 2>/dev/null) && [ -n "$xy" ] && adb shell input tap $xy; }
  totp_now() {
    python3 - "$THROWAWAY_TOTP_SECRET" <<'PYEOF'
import base64, hashlib, hmac, struct, sys, time
s = sys.argv[1].replace(' ', '').upper()
s += '=' * ((8 - len(s) % 8) % 8)
key = base64.b32decode(s)
d = hmac.new(key, struct.pack('>Q', int(time.time()) // 30), hashlib.sha1).digest()
o = d[-1] & 0x0F
print('%06d' % ((struct.unpack('>I', d[o:o + 4])[0] & 0x7FFFFFFF) % 1000000))
PYEOF
  }
  dismiss_anr() {
    # A "System UI isn't responding" dialog covered all of run #13's
    # Phase 6. If it's up, tap "Wait" (keeps System UI alive) and recheck.
    for _ in 1 2 3; do
      if ui_texts | grep -qi "isn't responding"; then
        tap_text "Wait" || true
        sleep 4
      else
        return 0
      fi
    done
  }
  timeline() { echo "  [t+${1}s] $(ui_texts | tr '\n' '|' | head -c 300)"; }
  wait_for() {
    # $1 = FIELD or a text regex; $2 = max seconds; $3 = label.
    # Polls the UI, logging a text timeline, until the target appears.
    local pat="$1" max="$2" label="$3" waited=0
    while [ "$waited" -lt "$max" ]; do
      dismiss_anr
      if [ "$pat" = "FIELD" ]; then
        if ui_dump | python3 /tmp/uihelp.py field >/dev/null 2>&1; then
          echo "--- $label: field present after ${waited}s"; return 0
        fi
      elif ui_texts | grep -qiE "$pat"; then
        echo "--- $label: matched /$pat/ after ${waited}s"; return 0
      fi
      timeline "$waited"
      sleep 5; waited=$((waited + 5))
    done
    echo "--- $label: TIMEOUT after ${max}s"
    return 1
  }
  adb logcat -c >/dev/null 2>&1 || true
  echo "--- opening Settings add-account flow (classic GMS sign-in)"
  adb shell am start -a android.settings.ADD_ACCOUNT_SETTINGS >/dev/null 2>&1 || true
  sleep 5; dismiss_anr; shot screen-signin-0.png
  tap_text "Google" || tap_text "Add account" || true
  sleep 2; tap_text "Google" || true
  if wait_for FIELD 150 "email screen"; then
    dismiss_anr
    tap_field; sleep 1
    adb shell input text "$THROWAWAY_EMAIL"; sleep 1
    shot screen-signin-2.png
    tap_text "Next" || true
    if wait_for "show password|enter your password|forgot password" 90 "password screen"; then
      dismiss_anr
      tap_field; sleep 1
      adb shell input text "$THROWAWAY_PASSWORD"; sleep 1
      tap_text "Next" || true
      sleep 8; dismiss_anr; shot screen-signin-3.png
    else
      echo "SIGNIN_FLOW=no_password_screen"
      shot screen-signin-stuck.png
    fi
  else
    echo "SIGNIN_FLOW=no_email_field"
    shot screen-signin-stuck.png
  fi
  echo "--- 2-Step Verification handling (authenticator TOTP)"
  SIGNIN_VERDICT=""
  SV_TRIED=0
  for round in 1 2 3 4; do
    dismiss_anr
    ui_texts > "$OUT/signin-screen-texts-$round.txt" || true
    TXT=$(cat "$OUT/signin-screen-texts-$round.txt")
    if echo "$TXT" | grep -qiE "couldn.t sign you in|didn.t provide enough info"; then
      echo "--- Google risk-gate page reached (terminal for this flow)"
      SIGNIN_VERDICT="blocked_risk_gate"
      shot "screen-signin-2sv-$round.png"
      break
    fi
    if echo "$TXT" | grep -qiE "authenticator|verification code|enter the code|2-step|verify it.s you"; then
      if tap_field; then
        CODE=$(totp_now); adb shell input text "$CODE"; unset CODE; sleep 1
        tap_text "Next" || tap_text "Verify" || true
        sleep 8
      elif echo "$TXT" | grep -qi "choose how you want to sign in"; then
        tap_text "Authenticator" || tap_text "Google Authenticator" || true
        sleep 5
      elif [ "$SV_TRIED" = "0" ]; then
        SV_TRIED=1
        tap_text "Try another way" || true
        sleep 5
      else
        break
      fi
    elif echo "$TXT" | grep -qi "choose how you want to sign in"; then
      tap_text "Authenticator" || tap_text "Google Authenticator" || break
      sleep 5
    else
      break
    fi
    shot "screen-signin-2sv-$round.png"
  done
  echo "--- post-sign-in interstitials (agree/skip only)"
  for round in 1 2 3; do
    if tap_text "I agree"; then sleep 5;
    elif tap_text "Accept"; then sleep 5;
    elif tap_text "Agree"; then sleep 5;
    elif tap_text "No thanks"; then sleep 4;
    elif tap_text "Not now"; then sleep 4;
    elif tap_text "Skip"; then sleep 4;
    else break; fi
    shot "screen-signin-post-$round.png"
  done
  if adb shell dumpsys account 2>/dev/null | grep -q "$THROWAWAY_EMAIL"; then
    echo "SIGNIN_RESULT=account_added"
  elif [ -n "$SIGNIN_VERDICT" ]; then
    echo "SIGNIN_RESULT=$SIGNIN_VERDICT"
    ui_texts > "$OUT/signin-final-texts.txt" || true
    shot screen-signin-final.png
  else
    echo "SIGNIN_RESULT=not_confirmed"
    ui_texts > "$OUT/signin-final-texts.txt" || true
    shot screen-signin-final.png
  fi
  echo "--- Google One Benefits surface (observation only)"
  adb shell monkey -p com.google.android.apps.subscriptions.red -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 8; dismiss_anr; shot screen-benefits-0.png
  tap_text "Benefits" || true
  sleep 6; dismiss_anr; shot screen-benefits-1.png
  ui_texts > "$OUT/benefits-texts.txt" || true
  adb shell input swipe 540 1400 540 600 400 || true
  sleep 3; shot screen-benefits-2.png
  ui_texts >> "$OUT/benefits-texts.txt" || true
  echo "--- benefits lines mentioning oppo/offer/trial/month/free:"
  grep -iE "oppo|offer|trial|month|free" "$OUT/benefits-texts.txt" | head -10 || true
  adb logcat -d 2>/dev/null | grep -iE "auth|gms|addaccount|expresssignin|accountmanager|integrity|volley|cronet" | tail -80 > "$OUT/signin-logcat.txt" || true
fi

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
