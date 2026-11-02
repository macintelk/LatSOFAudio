#!/bin/zsh
# install.sh — install the PREBUILT LatSOFAudio.kext to /Library/Extensions.
#
# Pure installer: no clang, no make, no compilation happens here. Build
# first with:
#
#     ./build.sh          # produces LatSOFAudio.kext next to this script
#
# Usage:
#   sudo ./install.sh              install to /Library/Extensions + load attempt
#   sudo ./install.sh --remove     unload + remove from /Library/Extensions
#                                  (also accepts --uninstall)
#   ./install.sh --status          installed? loaded? (no root needed)
#
# First-time loading of a third-party kext on macOS 11+ needs, ONCE:
#   1. Recovery -> Startup Security Utility -> Reduced Security, and tick
#      "Allow user management of kernel extensions from identified developers".
#   2. If `kmutil load` says approval is required: approve the kext in
#      System Settings -> Privacy & Security, then REBOOT. After approval
#      the kext loads automatically at every boot from /Library/Extensions.
#   On a hackintosh you typically already boot with the equivalent OpenCore
#   quirks; the approval prompt then either doesn't appear or is a no-op.
#
# No OpenCore config changes are needed for this install method: kextd
# scans /Library/Extensions at every boot.

set -e
ROOT=${0:A:h}
KEXT=LatSOFAudio.kext
SRC=$ROOT/$KEXT
DST=/Library/Extensions/$KEXT
PB=/usr/libexec/PlistBuddy

bundle_id()  { $PB -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" }
bundle_ver() { $PB -c "Print :CFBundleVersion"     "$1/Contents/Info.plist" }

loaded() {
    kmutil showloaded 2>/dev/null | grep -qi latsof && return 0
    kextstat 2>/dev/null | grep -qi latsof && return 0
    return 1
}

# --- status (no root needed) ----------------------------------------------
if [[ $1 == "--status" ]]; then
    if [[ -d $DST ]]; then
        echo "installed: yes ($DST)"
        echo "bundle id: $(bundle_id $DST)"
        echo "version:   $(bundle_ver $DST)"
    else
        echo "installed: no ($DST not present)"
    fi
    if loaded; then
        echo "loaded:    yes"
    else
        echo "loaded:    no"
    fi
    exit 0
fi

# --- everything below needs root -------------------------------------------
if [[ $EUID != 0 ]]; then
    echo "error: installing a kext needs root. Run:"
    echo "           sudo $0${1:+ $1}"
    exit 1
fi

# --- remove -----------------------------------------------------------------
if [[ $1 == "--remove" || $1 == "--uninstall" ]]; then
    if [[ ! -d $DST ]]; then
        echo "not installed ($DST not present) — nothing to remove."
        exit 0
    fi
    RBID=$(bundle_id $DST)
    if loaded; then
        echo "=== unload loaded copy ==="
        if ! kmutil unload -b "$RBID" 2>/dev/null; then
            if ! kextunload -b "$RBID" 2>/dev/null; then
                echo "  (unload failed — the reboot after removal will clear it)"
            fi
        fi
    fi
    rm -rf "$DST"
    echo "removed $DST"
    echo "If it had been loaded, reboot to flush the loaded copy."
    exit 0
fi

# --- install (default action) ------------------------------------------------
if [[ ! -d $SRC || ! -f $SRC/Contents/MacOS/LatSOFAudio ]]; then
    echo "error: $SRC not found (or has no kernel binary)."
    echo "       Build it first (clang is only needed for this step):"
    echo "           cd $ROOT && ./build.sh"
    exit 1
fi
BID=$(bundle_id $SRC)
VER=$(bundle_ver $SRC)
echo "kext: $KEXT   id=$BID   version=$VER"

# Never replace files under a loaded kext — unload the old copy first.
if loaded; then
    echo "=== unload currently loaded copy ==="
    if ! kmutil unload -b "$BID" 2>/dev/null; then
        if ! kextunload -b "$BID" 2>/dev/null; then
            echo "  (could not unload — reboot before installing; the old"
            echo "   version keeps running until the next reboot)"
        fi
    fi
fi

echo "=== install to $DST ==="
if [[ -d $DST ]]; then
    rm -rf "$DST"
fi
mkdir -p /Library/Extensions
ditto "$SRC" "$DST"
chown -R root:wheel "$DST"
find "$DST" -type d -exec chmod 0755 {} +
find "$DST" -type f -exec chmod 0644 {} +
find "$DST/Contents/MacOS" -type f -exec chmod 0755 {} +

echo "=== load attempt ==="
if kmutil load -p "$DST"; then
    sleep 2
    if loaded; then
        echo "loaded OK."
        echo "Watch the DSP bring-up:"
        echo "    log stream (predicate: eventMessage contains \"LatSOF\")"
    else
        echo "load command returned 0 but the kext is not listed as loaded yet;"
        echo "on macOS 11+ it may be queued in the auxiliary collection and will"
        echo "appear after the approval/reboot cycle below."
    fi
else
    echo
    echo "kmutil load did not complete — this is normal the first time."
    echo "  1. Approve the kext: System Settings -> Privacy & Security,"
    echo "     then REBOOT. It will load automatically at boot."
    echo "  2. Check afterwards:  $0 --status"
    echo "  Hackintosh: make sure the OpenCore kext security quirks match"
    echo "  your setup (e.g. AmfiPass / reduced security) before retrying."
fi

echo
echo "=== userspace half (do this once, no sudo) ==="
echo "  default input : cd latsof-default-input && ./install.sh"
echo "  mic gain      : sudo nvram latsof.micvol=0.75   # 0.0..1.0, 0.75 = 30 dB"
