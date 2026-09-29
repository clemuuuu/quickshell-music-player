#!/usr/bin/env bash
# Joue une vidéo YouTube en audio seul via mpv (visible dans le lecteur grâce à mpv-mpris).
# Un seul mpv à la fois : le précédent lancé par le lecteur est arrêté.
# Volume : dernier volume choisi dans le lecteur (fichier mpv-volume), 30 % par défaut,
# + égalisation du volume (loudnorm) comme le fait YouTube.
[[ "$1" =~ ^[A-Za-z0-9_-]{11}$ ]] || { echo "identifiant de vidéo invalide : $1" >&2; exit 1; }
sock="${XDG_RUNTIME_DIR:-/tmp}/music-player-mpv.sock"
vol=$(cat "$HOME/.local/share/music-player/mpv-volume" 2>/dev/null)
[[ "$vol" =~ ^[0-9]+$ ]] && (( vol <= 100 )) || vol=30
pkill -f -- "--input-ipc-server=$sock"
exec mpv --no-video --really-quiet --ytdl-format=bestaudio/best \
    --volume="$vol" --af='lavfi=[loudnorm=I=-16:TP=-1.5:LRA=11]' \
    --input-ipc-server="$sock" "https://www.youtube.com/watch?v=$1"
