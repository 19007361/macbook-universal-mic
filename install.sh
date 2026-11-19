#!/bin/bash
# Builds MicGate (if needed), installs it to ~/Applications and starts it at every login.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="$HERE/build/MicGate.app"
DEST="$HOME/Applications/MicGate.app"
PLIST="$HOME/Library/LaunchAgents/local.micgate.plist"

if [ ! -d "$SRC_APP" ]; then
  "$HERE/build.sh"
fi

# Stop an older copy if there is one (upgrade).
launchctl bootout "gui/$(id -u)/local.micgate" 2>/dev/null || true
pkill -x MicGate 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$SRC_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.micgate</string>
<key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/MicGate</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "MicGate is installed and running (look for the mic icon in your menu bar)."
echo
echo "ONE-TIME STEP for the Cmd+mic-key shortcut:"
echo "  System Settings > Privacy & Security > Accessibility > switch MicGate on."
echo "  (macOS may have just shown a prompt for this.)"
