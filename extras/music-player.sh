#!/usr/bin/env bash
# Lecteur musique Quickshell (~/.config/quickshell/music-player)
# À lier à un raccourci (voir extras/hyprland-keybinds.conf)
#   music-player.sh             → ouvre en fenêtre / remet en fenêtre s'il est collé / ferme
#   music-player.sh dock EDGE   → colle le lecteur sur un bord (left|right|top|bottom)
#                                (même bord une 2e fois = retour en fenêtre)
running() { pgrep -f "^qs -c music-player" >/dev/null; }
ipc() { qs -c music-player ipc call player "$@" 2>/dev/null; }

if [ "$1" = dock ]; then
    if running; then
        ipc dock "$2"
    else
        MUSIC_PLAYER_MODE=dock MUSIC_PLAYER_EDGE="$2" qs -c music-player -n -d >/dev/null 2>&1
    fi
else
    if running; then
        if [ "$(ipc getMode)" = dock ]; then ipc undock; else pkill -f "^qs -c music-player"; fi
    else
        qs -c music-player -n -d >/dev/null 2>&1
    fi
fi
