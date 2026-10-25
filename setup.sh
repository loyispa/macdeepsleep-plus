#!/bin/bash
#
# macdeepsleep-plus setup script
#   sudo bash setup.sh --install     install / update
#   sudo bash setup.sh --uninstall   remove
#   sudo bash setup.sh --status      show state
#
set -euo pipefail

BIN_DEST="/usr/local/bin/macdeepsleep"
CONF_DIR="/usr/local/etc"
CONF_DEST="$CONF_DIR/macdeepsleep.conf"
PLIST="/Library/LaunchDaemons/com.local.macdeepsleep.plist"
LOG_FILE="/var/log/macdeepsleep.log"
LABEL="com.local.macdeepsleep"
OLD_LABEL="com.eaedward.macdeepsleep"
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_M="$SRC_DIR/macdeepsleep.m"
SRC_BIN="$SRC_DIR/macdeepsleep"

info() { printf "\033[36m> %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m  ok %s\033[0m\n" "$*"; }
warn() { printf "\033[33m  !  %s\033[0m\n" "$*"; }
die()  { printf "\033[31m  x  %s\033[0m\n" "$*"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "macOS only"

cmd_status() {
    if [ -x "$BIN_DEST" ]; then
        "$BIN_DEST" --status
    else
        echo "not installed"
    fi
    echo
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        echo "daemon: running"
    else
        echo "daemon: not loaded"
    fi
    echo "log: $LOG_FILE"
}

cmd_uninstall() {
    [ "$EUID" -eq 0 ] || die "root required: sudo bash $0 uninstall"

    info "stopping daemon"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    ok "removed $PLIST"

    info "restoring network"
    networksetup -getairportpower en0 | grep -q "On" || networksetup -setairportpower en0 on
    ok "wi-fi is on"

    rm -f /var/db/macdeepsleep/state
    rmdir /var/db/macdeepsleep 2>/dev/null || true

    info "removing binary"
    rm -f "$BIN_DEST"
    ok "removed $BIN_DEST"

    warn "config kept at $CONF_DEST (remove manually if no longer needed)"
    printf "\n\033[32mUninstalled.\033[0m\n"
}

cmd_install() {
    [ "$EUID" -eq 0 ] || die "root required: sudo bash $0"

    # Remove the upstream daemon if still installed: two daemons would fight.
    if [ -f "$OLD_PLIST" ]; then
        warn "found upstream macdeepsleep, disabling it first"
        launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
        rm -f "$OLD_PLIST"
        rm -f /usr/local/bin/macdeepsleep
        ok "upstream daemon disabled"
    fi

    # 1. Build from source when possible, otherwise use the prebuilt binary.
    if [ -f "$SRC_M" ] && command -v clang >/dev/null 2>&1; then
        info "building from source"
        clang -fobjc-arc -O2 -Wall -Wno-unused-parameter \
              -framework Foundation -framework CoreWLAN \
              -framework IOBluetooth -framework IOKit \
              -o "$SRC_DIR/macdeepsleep.build" "$SRC_M" \
            || die "build failed - is the Command Line Tools package installed?"
        SRC_BIN="$SRC_DIR/macdeepsleep.build"
        ok "build finished"
    elif [ -f "$SRC_BIN" ]; then
        info "using prebuilt binary"
    else
        die "neither $SRC_M nor a prebuilt binary was found"
    fi

    # 2. Install the binary.
    info "installing binary"
    install -d /usr/local/bin
    install -m 755 -o root -g wheel "$SRC_BIN" "$BIN_DEST"
    ok "-> $BIN_DEST"

    # 3. Write the default config, never overwrite an existing one.
    install -d "$CONF_DIR"
    if [ ! -f "$CONF_DEST" ]; then
        cat > "$CONF_DEST" <<'EOF'
# macdeepsleep-plus configuration

# Also power off Bluetooth while sleeping.
#   0 = leave Bluetooth alone (default, recommended with a Bluetooth mouse/keyboard)
#   1 = power it off too (saves a little more, peripherals must reconnect on wake)
disable_bluetooth=0

# Bring down the awdl0 interface (AirDrop / Continuity peer-to-peer) while sleeping.
disable_awdl=1
EOF
        chmod 644 "$CONF_DEST"
        ok "-> ${CONF_DEST} (defaults)"
    else
        ok "-> ${CONF_DEST} (kept existing)"
    fi

    # 4. Install the launchd daemon.
    info "installing launchd daemon"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DEST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    ok "-> $PLIST"

    # 5. Load it.
    info "starting daemon"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
    sleep 1

    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        ok "running"
    else
        die "failed to start - see $LOG_FILE"
    fi

    printf "\n\033[32mInstalled.\033[0m\n\n"
    cat <<EOF
  status:  $BIN_DEST --status
  log:     tail -f $LOG_FILE

  Quick check:
    sudo pmset sleepnow        # sleep, then wake the machine
    tail -n 20 $LOG_FILE       # expect "cut:" then "restored (full wake, lid open)"
EOF
}

usage() {
    cat <<'EOF'
usage: sudo bash setup.sh [command]

  --install, -i     install or update   (default when no command is given)
  --uninstall, -u   remove
  --status, -s      print current state
  --help, -h        this help
EOF
}

case "${1:-install}" in
    --install|-i|install)     cmd_install ;;
    --uninstall|-u|uninstall) cmd_uninstall ;;
    --status|-s|status)       cmd_status ;;
    --help|-h|help)           usage ;;
    *)                        usage; exit 1 ;;
esac
