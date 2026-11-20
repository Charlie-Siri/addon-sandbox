#!/usr/bin/env bash
# Links SandboxDump into WoW Forever's AddOns folder (run once; /reload in game to load it).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WOW="${SANDBOX_WOW_DIR:-$HOME/Faugus/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_}"
LINK="$WOW/Interface/AddOns/SandboxDump"

if [ ! -d "$WOW/Interface/AddOns" ]; then
    echo "AddOns folder not found under: $WOW" >&2
    exit 1
fi
if [ -L "$LINK" ]; then
    echo "Already linked: $LINK -> $(readlink "$LINK")"
elif [ -e "$LINK" ]; then
    echo "Something else already exists at $LINK; not touching it." >&2
    exit 1
else
    ln -s "$SRC" "$LINK"
    echo "Linked $LINK -> $SRC"
fi
