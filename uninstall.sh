#!/bin/bash
# Removes MicGate and its start-at-login entry. Leaves your mic unmuted.
launchctl bootout "gui/$(id -u)/local.micgate" 2>/dev/null || true
pkill -x MicGate 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.micgate.plist"
rm -rf "$HOME/Applications/MicGate.app"
defaults delete local.micgate 2>/dev/null || true
echo "MicGate removed."
echo "If your mic was muted when you removed it, open System Settings > Sound > Input and raise the input volume."
echo "Optional: also remove MicGate from Privacy & Security > Accessibility."
