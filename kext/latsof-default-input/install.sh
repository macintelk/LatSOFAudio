#!/bin/zsh
# install.sh — install the PREBUILT latsof-default-input binary and its
# LaunchAgent. No clang, no make, no Xcode Command Line Tools needed at
# install time — compilation happens once in ../build.sh:
#
#     cd ..
#     ./build.sh        # builds LatSOFAudio.kext AND latsof-default-input
#
# (or `make` in this directory, if you do have Command Line Tools).
#
# Usage:
#   ./install.sh             install binary + LaunchAgent, load agent
#   ./install.sh --unload    uninstall (unload agent, remove agent + binary)
#                            (also accepts -u or uninstall)
#
# No sudo. Installs into your own home directory:
#   binary -> ~/Library/Application Support/LatSOF/latsof-default-input
#   agent  -> ~/Library/LaunchAgents/local.latsof.default-input.plist

set -e
cd -- "${0:h}"

PROG=latsof-default-input
BINDIR="$HOME/Library/Application Support/LatSOF"
LABEL=local.latsof.default-input
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

# --- uninstall path -------------------------------------------------------
if [[ $1 == "--unload" || $1 == "-u" || $1 == "uninstall" ]]; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f  "$PLIST_DST"
    rm -f  "$BINDIR/$PROG"
    echo "Removed agent + binary. macOS falls back to the previous default input."
    exit 0
fi

# --- install ---------------------------------------------------------------
# The binary must already exist: build.sh (or make) built it next to this
# script. We only copy and register it here.
if [[ ! -x $PROG ]]; then
    echo "error: ./$PROG not found — nothing to install."
    echo "       Build it first (clang is only needed for this step):"
    echo "           cd .. && ./build.sh"
    echo "       or, with Command Line Tools installed:"
    echo "           make"
    exit 1
fi

# Verify the LatSOF kext is loaded — if not, the tool would wait 30 s at
# every login and then give up without having done anything.
if ! system_profiler SPAudioDataType 2>/dev/null | grep -qi latsof; then
    echo "WARNING: no LatSOF audio device found in SPAudioDataType."
    echo "         The tool waits up to 30 s at each login, but it won't do"
    echo "         anything until LatSOFAudio.kext is loaded."
    echo "         Continue anyway? (y/N)"
    read -q || exit 1
fi

echo "=== install binary ==="
mkdir -p "$BINDIR"
install -m 0755 "$PROG" "$BINDIR/$PROG"

echo "=== install LaunchAgent ==="
mkdir -p "$HOME/Library/LaunchAgents"
# Substitute the binary path into the plist so the agent calls this user's copy.
sed -e "s#@BINDIR@#$BINDIR#g" "$LABEL.plist" > "$PLIST_DST"

echo "=== load ==="
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "=== status ==="
launchctl list | grep "$LABEL" || true
echo "---"
echo "Installed. The agent runs ONCE at each login: waits up to 30 s for the"
echo "LatSOF device, sets it as the default input, then exits. It never runs"
echo "again during the session, so it never fights your later choices."
echo
echo "Logs:    log show --predicate 'processImagePath contains \"$PROG\"' --last 5m"
echo "Test:    \"$BINDIR/$PROG\" --dry-run"
echo "Remove:  $0 --unload   (or: make uninstall)"
