//@ pragma Env QS_NO_RELOAD_POPUP=1
// Évite un plantage rare de Qt (OpenSSL appelé en même temps par le cache des shaders et le réseau)
//@ pragma Env QT_DISABLE_SHADER_DISK_CACHE=1
//@ pragma Env QSG_RHI_DISABLE_DISK_CACHE=1

// Lecteur musique : pilote n'importe quel lecteur MPRIS (YouTube dans Chrome, mpv, Spotify…).
// Deux modes :
//   - "window" : fenêtre normale, qui se tuile
//   - "dock"   : collé sur un bord de l'écran, sort quand la souris passe sur la languette
// Lancer : extras/music-player.sh (ouvrir/fermer, coller à un bord)   |   couleurs : colors.json (généré par wallust, optionnel)
// Favoris / historique : ~/.local/share/music-player/library.json

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import QtMultimedia
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    // ---------- Couleurs ----------
    // Couleurs wallust (fond d'écran), relues quand le fond change
    property color wBg: "#101011"
    property color wFg: "#E8C7BC"
    property color wAccent: "#D6A797"
    property color wAccent2: "#BD5F40"
    property color wMuted: "#95756A"
    readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/music-player"
    readonly property string font: "JetBrains Mono"
    readonly property string iconFont: "FantasqueSansM Nerd Font"

    FileView {
        path: Quickshell.shellPath("colors.json")
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const c = JSON.parse(text());
                root.wBg = c.background;
                root.wFg = c.foreground;
                root.wAccent = c.color7;
                root.wAccent2 = c.color14;
                root.wMuted = c.color8;
            } catch (e) {
                console.warn("colors.json illisible :", e);
            }
        }
    }

    // ---------- Thèmes (bouton en haut à gauche) ----------
    readonly property var builtinThemes: [
        { id: "wallust", name: "Fond d'écran", light: false },
        { id: "rouge", name: "Rouge", light: false, bg: "#1a0b0d", fg: "#f3d6d6", accent: "#e5484d", accent2: "#8c1d24", muted: "#9a6b6e" },
        { id: "bleu", name: "Bleu nuit", light: false, bg: "#0b1020", fg: "#d6e2ff", accent: "#5b8cff", accent2: "#1e3a8a", muted: "#6b7aa6" },
        { id: "dark", name: "Blanc", light: false, bg: "#0a0a0a", fg: "#eaeaea", accent: "#f2f2f2", accent2: "#555555", muted: "#7a7a7a" },
        { id: "violet", name: "Violet", light: false, bg: "#140d1f", fg: "#eadcff", accent: "#b388ff", accent2: "#6a3fc2", muted: "#8a78a8" },
        { id: "vert", name: "Vert", light: false, bg: "#0b1612", fg: "#d8f3e6", accent: "#3ddc97", accent2: "#0f6b4a", muted: "#6f9b88" },
        // Thème vivant : teintes qui dérivent, anneau arc-en-ciel, aurores en fond qui réagissent aux basses
        { id: "aurore", name: "Aurore ✦", light: false, bg: "#07080f", fg: "#e8ecff", accent: "#9fb4ff", accent2: "#5b3fd1", muted: "#7d86a8" },
        // Thème vivant très sombre : sonar sur chaque battement, plancton lumineux, pochette éclairée par flashs
        { id: "abysse", name: "Abysse", light: false, bg: "#020306", fg: "#cfe9ef", accent: "#3ff0e0", accent2: "#0a3d4a", muted: "#4d6b73" }
    ]
    // Thèmes perso (ex. thèmes vidéo) : ~/.local/share/music-player/themes/themes.json
    // Tableau d'objets au même format que ci-dessus ; "video"/"poster" = fichiers du même dossier.
    property var extraThemes: []
    readonly property var themes: builtinThemes.concat(extraThemes)
    FileView {
        path: root.dataDir + "/themes/themes.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const t = JSON.parse(text());
                root.extraThemes = Array.isArray(t) ? t.filter(x => x && x.id && x.name) : [];
            } catch (e) {
                console.warn("themes.json illisible :", e);
            }
        }
    }

    property string themeId: "wallust"
    readonly property var theme: themes.find(t => t.id === themeId) ?? themes[0]
    readonly property bool wall: theme.id === "wallust"

    // Thèmes vidéo : fichiers dans ~/.local/share/music-player/themes/
    readonly property string themeVideo: theme.video ? "file://" + dataDir + "/themes/" + theme.video : ""
    readonly property string themePoster: theme.poster ? "file://" + dataDir + "/themes/" + theme.poster : ""
    readonly property bool aurora: theme.id === "aurore"
    // Teinte qui tourne en continu (thème Aurore)
    property real hue: 0.62
    NumberAnimation on hue {
        from: 0
        to: 1
        duration: 45000
        loops: Animation.Infinite
        running: root.aurora && root.onScreen
    }
    // Basses (moyenne des premières barres cava), pour faire pulser l'Aurore
    readonly property real bass: bars.length ? Math.min(1, (bars[0] + bars[1] + bars[2] + bars[3]) / 4 * 1.4) : 0

    // Horloge commune du plancton (25 images/s, seulement si visible)
    property real drift: 0
    Timer {
        interval: 40
        repeat: true
        running: root.abyss && root.onScreen
        onTriggered: root.drift += 0.04
    }

    // ---------- Détecteur de battements (thème Abysse) ----------
    // Un battement = les basses dépassent nettement leur moyenne récente.
    readonly property bool abyss: theme.id === "abysse"
    property real bassAvg: 0
    property real lastBeat: 0
    property real flash: 0          // 1 au battement, retombe à 0
    signal beat
    onBassChanged: {
        if (!abyss)
            return;
        // Réglé sur un vrai morceau (hardtekk ~170 BPM) : le son capté est faible
        // (volume vidéo + mixeur), donc seuil bas et moyenne très courte.
        bassAvg = bassAvg * 0.8 + bass * 0.2;
        const now = Date.now();
        if (bass > 0.03 && bass > bassAvg * 1.05 && now - lastBeat > 170) {
            lastBeat = now;
            flash = 1;
            flashFade.restart();
            beat();
        }
    }
    NumberAnimation {
        id: flashFade
        target: root
        property: "flash"
        to: 0
        duration: 650
        easing.type: Easing.OutQuad
    }

    property color bg: wall ? wBg : theme.bg
    property color fg: wall ? wFg : theme.fg
    property color accent: wall ? wAccent : aurora ? Qt.hsla(hue, 0.8, 0.68, 1) : theme.accent
    property color accent2: wall ? wAccent2 : aurora ? Qt.hsla((hue + 0.3) % 1, 0.75, 0.45, 1) : theme.accent2
    property color muted: wall ? wMuted : theme.muted
    Behavior on bg { ColorAnimation { duration: 350 } }
    Behavior on fg { ColorAnimation { duration: 350 } }
    Behavior on accent { enabled: !root.aurora; ColorAnimation { duration: 350 } }
    Behavior on accent2 { enabled: !root.aurora; ColorAnimation { duration: 350 } }
    Behavior on muted { ColorAnimation { duration: 350 } }

    function nextTheme() {
        const i = themes.findIndex(t => t.id === themeId);
        themeId = themes[(i + 1) % themes.length].id;
        settingsFile.setText(JSON.stringify({ theme: themeId }) + "\n");
    }
    FileView {
        id: settingsFile
        path: root.dataDir + "/settings.json"
        onLoaded: {
            try {
                const t = JSON.parse(text()).theme;
                if (typeof t === "string")
                    root.themeId = t;   // si le thème n'existe pas (ou pas encore), repli sur le 1er
            } catch (e) {}
        }
    }

    // ---------- Mode d'affichage ----------
    // Au lancement : MUSIC_PLAYER_MODE=dock MUSIC_PLAYER_EDGE=left (sinon fenêtre)
    property string mode: Quickshell.env("MUSIC_PLAYER_MODE") === "dock" ? "dock" : "window"
    property string edge: ["left", "right", "top", "bottom"].includes(Quickshell.env("MUSIC_PLAYER_EDGE")) ? Quickshell.env("MUSIC_PLAYER_EDGE") : "left"
    property var dockScreen: focusedScreen()

    function focusedScreen() {
        const name = Hyprland.focusedMonitor?.name;
        return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
    }

    IpcHandler {
        target: "player"

        // Coller sur un bord ; même bord une 2e fois = retour en fenêtre
        function dock(edge: string): void {
            if (!["left", "right", "top", "bottom"].includes(edge))
                return;
            if (root.mode === "dock" && root.edge === edge) {
                root.mode = "window";
                return;
            }
            root.dockScreen = root.focusedScreen();
            root.edge = edge;
            root.mode = "dock";
        }
        function undock(): void {
            root.mode = "window";
        }
        function getMode(): string {
            return root.mode;
        }
        // Ajouter / retirer le morceau en cours des favoris
        function favorite(): void {
            root.toggleFavorite();
        }
        // Passer à la source suivante (onglet / appli)
        function nextSource(): void {
            root.cyclePlayer();
        }
        // Source affichée (pour déboguer)
        function current(): string {
            return root.player?.dbusName ?? "";
        }
    }

    // ---------- Lecteur actif ----------
    // Avec l'extension mpris-tabs, chaque onglet Chrome est un lecteur à part :
    // on cache alors le lecteur "Chrome" natif (qui ne montre que le dernier onglet).
    readonly property var players: {
        const all = Mpris.players.values;
        const hasTabs = all.some(p => p.dbusName.includes("mpris_tabs"));
        return all.filter(p => !(hasTabs && p.dbusName.includes(".chromium.")));
    }
    // Source affichée (dbusName). Elle reste la même quand on la met en pause ;
    // elle change si on clique une autre pastille, ou si une autre source DÉMARRE.
    property string selectedName: ""
    readonly property MprisPlayer player: {
        const ps = players;
        if (!ps || ps.length === 0)
            return null;
        return ps.find(p => p.dbusName === selectedName) ?? ps.find(p => p.isPlaying) ?? ps[0];
    }
    readonly property bool playing: player?.isPlaying ?? false
    // Fige le choix, pour qu'une pause ne fasse pas sauter sur une autre source
    onPlayerChanged: Qt.callLater(() => {
        if (player && player.dbusName !== selectedName)
            selectedName = player.dbusName;
    })

    // Quand une autre source se met à jouer, on la suit
    property var lastPlaying: []
    readonly property var playingNames: players.filter(p => p.isPlaying).map(p => p.dbusName)
    onPlayingNamesChanged: {
        const started = playingNames.filter(n => !lastPlaying.includes(n));
        if (started.length)
            selectedName = started[0];
        lastPlaying = playingNames;
    }

    function selectPlayer(p) {
        selectedName = p.dbusName;
    }
    function cyclePlayer(dir) {
        if (players.length < 2)
            return;
        const step = dir === -1 ? -1 : 1;
        const cur = players.indexOf(player);
        selectedName = players[(cur + step + players.length) % players.length].dbusName;
    }

    // Nom court de la source : site de l'onglet, ou nom de l'appli
    function sourceLabel(p) {
        if (!p)
            return "";
        if (p.dbusName.includes("mpris_tabs")) {
            const host = ((p.metadata["xesam:url"] ?? "").match(/^https?:\/\/([^/]+)/)?.[1] ?? "").replace(/^www\./, "");
            if (host === "music.youtube.com")
                return "YT Music";
            if (host.endsWith("youtube.com") || host === "youtu.be")
                return "YouTube";
            return host || "Onglet";
        }
        return p.identity;
    }

    // Titres YouTube : on enlève "(Official Video)", " - Topic", etc.
    function cleanArtist(a) {
        return (a || "").replace(/\s*-\s*Topic$/i, "").replace(/VEVO$/i, "").trim();
    }
    function cleanTitle(t) {
        return (t || "").replace(/\s*[(\[][^)\]]*(official|lyric|audio|video|visuali[sz]er|clip|hd|4k|mv)[^)\]]*[)\]]/gi, "").trim();
    }
    readonly property var track: {
        let t = cleanTitle(player?.trackTitle);
        let a = cleanArtist(player?.trackArtist);
        // "Artiste - Titre" dans le titre de la vidéo
        const m = t.match(/^(.+?)\s+[-–—]\s+(.+)$/);
        if (m) {
            a = m[1];
            t = m[2];
        }
        return {
            title: t || "Titre inconnu",
            artist: a
        };
    }

    function videoIdOf(url) {
        return (url || "").match(/(?:[?&]v=|youtu\.be\/)([\w-]{11})/)?.[1] ?? "";
    }
    readonly property string currentVideoId: videoIdOf(player?.metadata["xesam:url"])

    readonly property string artUrl: {
        if (!player)
            return "";
        const a = player.trackArtUrl;
        // Miniatures YouTube : l'extension mpris-tabs donne une URL qui renvoie de l'AVIF,
        // illisible par Qt ; la version JPEG sans paramètres existe toujours.
        const ytId = a.match(/i\.ytimg\.com\/vi(?:_webp)?\/([\w-]{11})\//)?.[1] ?? "";
        if (ytId)
            return `https://i.ytimg.com/vi/${ytId}/hq720.jpg`;
        if (a)
            return a;
        return currentVideoId ? `https://i.ytimg.com/vi/${currentVideoId}/hq720.jpg` : "";
    }
    // hq720 n'existe pas pour toutes les vidéos : repli sur mqdefault (16:9, sans bandes noires)
    function artFallback(url) {
        return url.replace("/hq720.jpg", "/mqdefault.jpg");
    }

    function fmtTime(s) {
        if (!isFinite(s) || s < 0)
            s = 0;
        s = Math.floor(s);
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    // MPRIS ne pousse pas la position : on la redemande régulièrement
    Timer {
        interval: 250
        repeat: true
        running: root.playing
        onTriggered: root.player?.positionChanged()
    }

    // ---------- Visible à l'écran ? ----------
    // Hors écran (autre espace de travail, carte du bord rangée), on coupe
    // visualiseur et animations pour économiser le processeur.
    property bool dockOpen: false
    readonly property var myToplevel: Hyprland.toplevels.values.find(t => t.title === "Lecteur musique") ?? null
    readonly property bool onScreen: {
        if (mode === "dock")
            return dockOpen;
        const ws = myToplevel?.workspace;
        if (!ws || ws.name.startsWith("special"))
            return true;   // inconnu ou tiroir (special workspace) : on considère visible
        return ws.monitor ? ws.monitor.activeWorkspace === ws : ws.active;
    }
    // Quickshell ne connaît le titre / l'espace de sa propre fenêtre qu'après
    // avoir redemandé la liste à Hyprland : on la rafraîchit quand ça bouge.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["openwindow", "movewindowv2", "windowtitlev2", "workspacev2", "focusedmonv2", "moveworkspacev2"].includes(event.name))
                Hyprland.refreshToplevels();
        }
    }
    Timer {
        interval: 800
        running: true
        onTriggered: Hyprland.refreshToplevels()
    }

    // ---------- Visualiseur (cava) ----------
    property var bars: []
    Process {
        running: root.playing && root.onScreen
        command: ["cava", "-p", Quickshell.shellPath("cava.conf")]
        stdout: SplitParser {
            onRead: data => {
                root.bars = data.split(";").map(v => parseFloat(v) / 100).filter(v => !isNaN(v));
            }
        }
        onRunningChanged: if (!running) root.bars = []
    }

    // ---------- Paroles (lrclib.net) ----------
    property var lyrics: []
    property string lyricsState: "none"   // none | loading | synced | plain
    property string plainLyrics: ""
    property real lyricsScale: 1
    readonly property string trackKey: (player?.trackTitle ?? "") + "|" + (player?.trackArtist ?? "")
    onTrackKeyChanged: {
        lyrics = [];
        plainLyrics = "";
        lyricsState = player ? "loading" : "none";
        lyricsDelay.restart();
        listenedSecs = 0;
    }
    Timer {
        id: lyricsDelay
        interval: 700   // laisse le temps à la durée du morceau d'arriver
        onTriggered: root.fetchLyrics()
    }

    function httpGet(url, cb) {
        const x = new XMLHttpRequest();
        x.onreadystatechange = () => {
            if (x.readyState === XMLHttpRequest.DONE) {
                let json = null;
                try {
                    json = JSON.parse(x.responseText);
                } catch (e) {}
                cb(x.status, json);
            }
        };
        x.open("GET", url);
        x.send();
    }

    function parseLrc(s) {
        const out = [];
        for (const line of s.split("\n")) {
            const m = line.match(/^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/);
            if (m)
                out.push({
                    t: parseInt(m[1]) * 60 + parseFloat(m[2]),
                    text: m[3].trim()
                });
        }
        return out;
    }

    function fetchLyrics() {
        if (!player)
            return;
        const key = trackKey;
        const title = track.title.replace(/\s*[(\[][^)\]]*[)\]]/g, "").trim();
        const artist = track.artist;
        const len = player.length;
        const altered = /slowed|sped|speed ?up|nightcore|reverb/i.test(player.trackTitle ?? "");
        const base = "https://lrclib.net/api/search?";

        const pick = results => {
            if (!Array.isArray(results) || results.length === 0)
                return null;
            const synced = results.filter(r => r.syncedLyrics);
            const pool = synced.length ? synced : results;
            if (!altered && len > 0)
                pool.sort((a, b) => Math.abs(a.duration - len) - Math.abs(b.duration - len));
            return pool[0];
        };
        const apply = r => {
            if (key !== trackKey)
                return;   // le morceau a changé entre-temps
            if (!r) {
                lyricsState = "none";
                return;
            }
            // Version slowed / sped up : on étire le timing des paroles
            lyricsScale = (altered && r.duration > 0 && len > 0) ? len / r.duration : 1;
            if (r.syncedLyrics) {
                lyrics = parseLrc(r.syncedLyrics);
                lyricsState = "synced";
            } else if (r.plainLyrics) {
                plainLyrics = r.plainLyrics;
                lyricsState = "plain";
            } else {
                lyricsState = "none";
            }
        };

        const q1 = base + "track_name=" + encodeURIComponent(title) + (artist ? "&artist_name=" + encodeURIComponent(artist) : "");
        httpGet(q1, (status, res) => {
            const r = pick(res);
            if (r)
                return apply(r);
            httpGet(base + "q=" + encodeURIComponent((title + " " + artist).trim()), (s2, res2) => apply(pick(res2)));
        });
    }

    readonly property int lyricIndex: {
        const p = (player?.position ?? 0) / lyricsScale + 0.3;
        let i = -1;
        for (let k = 0; k < lyrics.length; k++) {
            if (lyrics[k].t <= p)
                i = k;
            else
                break;
        }
        return i;
    }

    // ---------- Favoris & historique ----------
    property var favorites: []
    property var history: []
    property string tab: "lyrics"   // lyrics | favorites | history (mode fenêtre)
    property int listenedSecs: 0
    property string resolvingKey: ""

    FileView {
        id: libFile
        path: root.dataDir + "/library.json"
        onLoaded: {
            try {
                const d = JSON.parse(text());
                root.favorites = d.favorites ?? [];
                root.history = d.history ?? [];
            } catch (e) {
                console.warn("library.json illisible :", e);
            }
        }
    }
    function saveLibrary() {
        libFile.setText(JSON.stringify({
            favorites: favorites,
            history: history
        }, null, 1));
    }

    readonly property string currentKey: player ? Qt.md5((track.title + "|" + track.artist).toLowerCase()) : ""
    readonly property bool isFavorite: currentKey !== "" && favorites.some(f => f.key === currentKey)

    function knownVideoId(key) {
        return (favorites.find(e => e.key === key) ?? history.find(e => e.key === key))?.videoId ?? "";
    }

    function currentEntry() {
        const key = currentKey;
        const vid = currentVideoId || knownVideoId(key);
        let art = "";
        if (vid) {
            art = `https://i.ytimg.com/vi/${vid}/hqdefault.jpg`;
        } else if (artUrl.startsWith("file://")) {
            // la pochette de Chrome est un fichier temporaire : on en garde une copie
            const dst = `${dataDir}/art/${key}.jpg`;
            Quickshell.execDetached(["cp", decodeURIComponent(artUrl.slice(7)), dst]);
            art = "file://" + dst;
        } else {
            art = artUrl;
        }
        return {
            key: key,
            title: track.title,
            artist: track.artist,
            query: (cleanArtist(player.trackArtist) + " " + (player.trackTitle ?? "")).trim(),
            art: art,
            videoId: vid
        };
    }

    function toggleFavorite() {
        if (!player)
            return;
        if (isFavorite)
            favorites = favorites.filter(f => f.key !== currentKey);
        else
            favorites = [currentEntry()].concat(favorites);
        saveLibrary();
    }
    function removeFavorite(key) {
        favorites = favorites.filter(f => f.key !== key);
        saveLibrary();
    }
    // Retire complètement un son des récents (entrée + pochette copiée si plus utilisée)
    function removeHistory(key) {
        const e = history.find(h => h.key === key);
        history = history.filter(h => h.key !== key);
        saveLibrary();
        const artDir = "file://" + dataDir + "/art/";
        if (e && e.art && e.art.startsWith(artDir) && !e.art.includes("..") && !favorites.some(f => f.art === e.art))
            Quickshell.execDetached(["rm", "-f", e.art.slice(7)]);
    }
    function addHistory() {
        if (!player)
            return;
        const e = currentEntry();
        e.at = Date.now();
        history = [e].concat(history.filter(h => h.key !== e.key)).slice(0, 50);
        saveLibrary();
    }
    function setVideoId(key, id) {
        favorites = favorites.map(e => e.key === key ? Object.assign({}, e, {
                    videoId: id,
                    art: `https://i.ytimg.com/vi/${id}/hqdefault.jpg`
                }) : e);
        history = history.map(e => e.key === key ? Object.assign({}, e, {
                    videoId: id,
                    art: `https://i.ytimg.com/vi/${id}/hqdefault.jpg`
                }) : e);
        saveLibrary();
    }

    // Une écoute compte dans l'historique après 20 s
    Timer {
        interval: 1000
        repeat: true
        running: root.playing
        onTriggered: {
            root.listenedSecs++;
            if (root.listenedSecs === 20)
                root.addHistory();
        }
    }

    // Retenir le volume de mpv pour les prochains favoris (lu par play.sh)
    FileView {
        id: mpvVolumeFile
        path: root.dataDir + "/mpv-volume"
    }
    readonly property bool isMpv: player?.dbusName.includes(".mpv") ?? false
    readonly property real mpvVolume: isMpv ? player.volume : -1
    onMpvVolumeChanged: if (mpvVolume >= 0) saveVolume.restart()
    Timer {
        id: saveVolume
        interval: 800
        onTriggered: if (root.mpvVolume >= 0) mpvVolumeFile.setText(Math.round(root.mpvVolume * 100) + "\n")
    }

    // Relancer un favori : mpv en arrière-plan (pas d'onglet YouTube, les autres sources continuent)
    function playEntry(e) {
        if (e.videoId)
            return startMpv(e.videoId);
        resolvingKey = e.key;
        resolver.command = ["yt-dlp", "--no-warnings", "--flat-playlist", "--print", "id", "ytsearch1:" + (e.query || (e.artist + " " + e.title))];
        resolver.running = true;
    }
    function startMpv(id) {
        Quickshell.execDetached([Quickshell.shellPath("play.sh"), id]);
    }
    Process {
        id: resolver
        stdout: StdioCollector {
            onStreamFinished: {
                const id = text.trim().split("\n")[0];
                if (/^[\w-]{11}$/.test(id)) {
                    root.setVideoId(root.resolvingKey, id);
                    root.startMpv(id);
                }
                root.resolvingKey = "";
            }
        }
    }

    // =====================================================================
    // Composants
    // =====================================================================

    // Bouton-icône
    component IconButton: Text {
        id: btn
        property bool enabledState: true
        signal activated
        font.family: root.iconFont
        font.pixelSize: 30
        color: root.fg
        opacity: enabledState ? 1 : 0.3
        scale: btnArea.pressed ? 0.9 : btnArea.containsMouse ? 1.12 : 1
        Behavior on scale {
            NumberAnimation {
                duration: 120
            }
        }
        MouseArea {
            id: btnArea
            anchors.fill: parent
            anchors.margins: -8
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (btn.enabledState) btn.activated()
        }
    }

    // Cœur favori du morceau en cours
    component HeartButton: IconButton {
        text: String.fromCodePoint(root.isFavorite ? 0xF02D1 : 0xF02D5)
        color: root.isFavorite ? root.accent : root.muted
        enabledState: root.player !== null
        onActivated: root.toggleFavorite()
    }

    // Pastille d'une source (onglet YouTube, Spotify, mpv…)
    component SourceChip: Rectangle {
        id: chip
        property var source
        readonly property bool active: source === root.player
        readonly property string shortTitle: {
            const t = root.cleanTitle(source?.trackTitle ?? "");
            return t.length > 22 ? t.slice(0, 21) + "…" : t;
        }
        implicitHeight: 26
        implicitWidth: chipRow.implicitWidth + 20
        radius: 13
        color: active ? Qt.alpha(root.accent, 0.28) : chipArea.containsMouse ? Qt.alpha(root.accent, 0.14) : Qt.alpha(root.fg, 0.06)
        border.color: active ? Qt.alpha(root.accent, 0.7) : Qt.alpha(root.fg, 0.12)
        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: chip.source?.isPlaying ? root.accent : Qt.alpha(root.muted, 0.6)
            }
            Text {
                text: root.sourceLabel(chip.source) + (root.players.length > 1 && chip.shortTitle ? " · " + chip.shortTitle : "")
                font.family: root.font
                font.pixelSize: 11
                font.bold: chip.active
                color: chip.active ? root.fg : root.muted
            }
        }
        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectPlayer(chip.source)
        }
    }

    // Disque : pochette ronde qui tourne + barres cava en cercle
    component Disc: Item {
        id: disc
        property real size: 200
        implicitWidth: size
        implicitHeight: size
        readonly property real r: size / 2
        readonly property real coverR: r * 0.64
        readonly property real maxBar: r - coverR - Math.max(6, size / 30)

        Repeater {
            model: 48   // anneau symétrique ; 48 barres = assez dense et plus léger que 72
            Item {
                id: barHolder
                required property int index
                x: disc.r
                y: disc.r
                rotation: index * 7.5
                Rectangle {
                    readonly property real v: {
                        const b = root.bars;
                        if (!b.length)
                            return 0;
                        const k = barHolder.index < 24 ? barHolder.index : 47 - barHolder.index;
                        return Math.min(1, b[Math.round(k * 35 / 23)] ?? 0);
                    }
                    width: Math.max(2, disc.size / 70)
                    radius: width / 2
                    height: width + v * disc.maxBar
                    x: -width / 2
                    y: -(disc.coverR + Math.max(4, disc.size / 45)) - height
                    color: root.aurora ? Qt.hsla((root.hue + barHolder.index / 48) % 1, 0.85, 0.55 + 0.25 * v, 1) : Qt.tint(root.accent2, Qt.alpha(root.accent, v))
                    opacity: root.abyss ? 0.12 + 0.88 * v * (0.7 + 0.3 * root.flash) : 0.35 + 0.65 * v
                    Behavior on height {
                        NumberAnimation {
                            duration: 70
                        }
                    }
                }
            }
        }

        // Sonar (thème Abysse) : une onde par battement, 3 anneaux réutilisés
        property int sonarNext: 0
        Repeater {
            id: sonarRings
            model: root.abyss ? 3 : 0
            Rectangle {
                id: ring
                required property int index
                anchors.centerIn: parent
                width: disc.coverR * 2
                height: width
                radius: width / 2
                color: "transparent"
                border.color: root.accent
                border.width: 2
                opacity: 0
                function fire() {
                    wave.restart();
                }
                ParallelAnimation {
                    id: wave
                    NumberAnimation {
                        target: ring
                        property: "width"
                        from: disc.coverR * 2
                        to: disc.size * 1.35
                        duration: 1400
                        easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        target: ring
                        property: "opacity"
                        from: 0.8
                        to: 0
                        duration: 1400
                        easing.type: Easing.OutQuad
                    }
                }
            }
        }
        Connections {
            target: root
            function onBeat() {
                if (!disc.visible || sonarRings.count === 0)
                    return;
                sonarRings.itemAt(disc.sonarNext % sonarRings.count)?.fire();
                disc.sonarNext++;
            }
        }

        // Halo autour de la pochette
        Rectangle {
            anchors.centerIn: parent
            width: disc.coverR * 2 + 8
            height: width
            radius: width / 2
            color: "transparent"
            border.color: root.accent
            border.width: root.aurora ? 2 + root.bass * 5 : 2
            opacity: root.playing ? (root.aurora ? 0.6 + root.bass * 0.4 : 0.8) : 0.3
            Behavior on opacity {
                NumberAnimation {
                    duration: 400
                }
            }
        }

        ClippingRectangle {
            id: cover
            anchors.centerIn: parent
            width: disc.coverR * 2
            height: width
            radius: width / 2
            color: Qt.lighter(root.bg, 1.6)

            Image {
                id: coverArt
                // Effet sombre fixe (calculé une fois) ; le flash est un voile par-dessus
                layer.enabled: root.abyss
                layer.effect: MultiEffect {
                    saturation: -0.55
                    brightness: -0.28
                }
                property bool fellBack: false
                readonly property string wanted: root.artUrl
                onWantedChanged: fellBack = false
                onStatusChanged: if (status === Image.Error) fellBack = true
                anchors.fill: parent
                source: fellBack ? root.artFallback(wanted) : wanted
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 512
                asynchronous: true
                cache: false
            }
            Text {
                anchors.centerIn: parent
                visible: coverArt.status !== Image.Ready
                text: String.fromCodePoint(0xF075A)   // note de musique
                font.family: root.iconFont
                font.pixelSize: cover.width * 0.35
                color: root.muted
            }
            // Flash de l'Abysse : voile lumineux sur la pochette au battement
            Rectangle {
                anchors.fill: parent
                visible: root.abyss
                color: root.accent
                opacity: root.flash * 0.28
            }
            // Trou central façon vinyle
            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.1
                height: width
                radius: width / 2
                color: root.bg
                border.color: Qt.alpha(root.accent, 0.7)
                border.width: 2
            }

            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 24000
                loops: Animation.Infinite
                running: true
                paused: !root.playing || !root.onScreen
            }
        }

        // Clic = pause, molette = volume (si le lecteur le permet)
        MouseArea {
            anchors.fill: parent
            onClicked: root.player?.togglePlaying()
            onWheel: wheel => {
                if (root.player?.volumeSupported)
                    root.player.volume = Math.max(0, Math.min(1, root.player.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)));
            }
        }
    }

    // Barre de progression (clic / glisser pour avancer)
    component ProgressBar: Item {
        id: progress
        implicitHeight: 16
        readonly property real ratio: root.player && root.player.length > 0 ? Math.min(1, root.player.position / root.player.length) : 0

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: seekArea.containsMouse ? 8 : 5
            radius: height / 2
            color: Qt.alpha(root.fg, 0.15)
            Behavior on height {
                NumberAnimation {
                    duration: 120
                }
            }
            Rectangle {
                width: parent.width * progress.ratio
                height: parent.height
                radius: parent.radius
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0
                        color: root.accent2
                    }
                    GradientStop {
                        position: 1
                        color: root.accent
                    }
                }
            }
        }
        Rectangle {
            width: 14
            height: 14
            radius: 7
            color: root.fg
            x: progress.width * progress.ratio - width / 2
            anchors.verticalCenter: parent.verticalCenter
            visible: seekArea.containsMouse && (root.player?.canSeek ?? false)
        }
        MouseArea {
            id: seekArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: (root.player?.canSeek ?? false) ? Qt.PointingHandCursor : Qt.ArrowCursor
            function seek(mx) {
                if (root.player?.canSeek && root.player.length > 0)
                    root.player.position = Math.max(0, Math.min(1, mx / width)) * root.player.length;
            }
            onPressed: mouse => seek(mouse.x)
            onPositionChanged: mouse => {
                if (pressed)
                    seek(mouse.x);
            }
        }
    }

    // Précédent / play-pause / suivant
    component Controls: RowLayout {
        id: controls
        property real k: 1   // échelle
        spacing: 26 * k

        IconButton {
            text: String.fromCodePoint(0xF04AE)   // précédent
            font.pixelSize: 30 * controls.k
            enabledState: root.player?.canGoPrevious ?? false
            onActivated: root.player.previous()
        }
        Rectangle {
            Layout.preferredWidth: 62 * controls.k
            Layout.preferredHeight: 62 * controls.k
            radius: width / 2
            color: root.accent
            scale: playArea.pressed ? 0.92 : playArea.containsMouse ? 1.06 : 1
            Behavior on scale {
                NumberAnimation {
                    duration: 120
                }
            }
            Text {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: root.playing ? 0 : 2 * controls.k
                text: String.fromCodePoint(root.playing ? 0xF03E4 : 0xF040A)   // pause / play
                font.family: root.iconFont
                font.pixelSize: 32 * controls.k
                color: root.bg
            }
            MouseArea {
                id: playArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.player?.togglePlaying()
            }
        }
        IconButton {
            text: String.fromCodePoint(0xF04AD)   // suivant
            font.pixelSize: 30 * controls.k
            enabledState: root.player?.canGoNext ?? false
            onActivated: root.player.next()
        }
    }

    // Volume du lecteur affiché (celui de la vidéo / de l'appli, pas le mixeur)
    component VolumeBar: RowLayout {
        id: vbar
        property real k: 1
        readonly property bool usable: (root.player?.volumeSupported ?? false) && (root.player?.canControl ?? false)
        readonly property real vol: usable ? Math.max(0, Math.min(1, root.player.volume)) : 0
        property real beforeMute: 0.3
        spacing: 10 * k
        opacity: usable ? 1 : 0.4

        function setVol(v) {
            if (usable)
                root.player.volume = Math.max(0, Math.min(1, v));
        }

        Text {
            text: String.fromCodePoint(vbar.vol <= 0.001 ? 0xF0581 : vbar.vol < 0.34 ? 0xF057F : vbar.vol < 0.67 ? 0xF0580 : 0xF057E)
            font.family: root.iconFont
            font.pixelSize: 18 * vbar.k
            color: root.muted
            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                cursorShape: vbar.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    // clic = couper / remettre le son
                    if (vbar.vol > 0.001) {
                        vbar.beforeMute = vbar.vol;
                        vbar.setVol(0);
                    } else {
                        vbar.setVol(vbar.beforeMute);
                    }
                }
            }
        }
        Item {
            id: vtrack
            Layout.fillWidth: true
            Layout.preferredHeight: 16
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: volArea.containsMouse ? 7 : 4
                radius: height / 2
                color: Qt.alpha(root.fg, 0.15)
                Behavior on height {
                    NumberAnimation {
                        duration: 120
                    }
                }
                Rectangle {
                    width: parent.width * vbar.vol
                    height: parent.height
                    radius: parent.radius
                    color: root.accent
                }
            }
            Rectangle {
                width: 12
                height: 12
                radius: 6
                color: root.fg
                x: vtrack.width * vbar.vol - width / 2
                anchors.verticalCenter: parent.verticalCenter
                visible: volArea.containsMouse && vbar.usable
            }
            MouseArea {
                id: volArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: vbar.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onPressed: mouse => vbar.setVol(mouse.x / width)
                onPositionChanged: mouse => {
                    if (pressed)
                        vbar.setVol(mouse.x / width);
                }
                onWheel: wheel => vbar.setVol(vbar.vol + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))
            }
        }
        Text {
            Layout.preferredWidth: 38 * vbar.k
            horizontalAlignment: Text.AlignRight
            text: vbar.usable ? Math.round(vbar.vol * 100) + "%" : "—"
            font.family: root.font
            font.pixelSize: 11 * vbar.k
            color: root.muted
        }
    }

    // Visualiseur en ligne (quand il n'y a plus la place pour le disque)
    component LinearVisualizer: Item {
        id: lv
        readonly property int count: 36
        Row {
            anchors.centerIn: parent
            spacing: Math.max(1, lv.width / lv.count * 0.35)
            Repeater {
                model: lv.count
                Rectangle {
                    required property int index
                    readonly property real v: {
                        const b = root.bars;
                        if (!b.length)
                            return 0;
                        // graves au centre, symétrique
                        const half = lv.count / 2;
                        const k = index < half ? half - 1 - index : index - half;
                        return Math.min(1, b[k * 2] ?? 0);
                    }
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(2, lv.width / lv.count * 0.65)
                    height: Math.max(3, v * lv.height)
                    radius: width / 2
                    color: root.aurora ? Qt.hsla((root.hue + index / lv.count) % 1, 0.85, 0.55 + 0.25 * v, 1) : Qt.tint(root.accent2, Qt.alpha(root.accent, v))
                    opacity: 0.4 + 0.6 * v
                    Behavior on height {
                        NumberAnimation {
                            duration: 70
                        }
                    }
                }
            }
        }
    }

    // ‹ • • ● • › : changer de source sans prendre de place
    component SourceSwitcher: RowLayout {
        spacing: 10
        IconButton {
            text: String.fromCodePoint(0xF0141)   // chevron gauche
            font.pixelSize: 20
            color: root.muted
            onActivated: root.cyclePlayer(-1)
        }
        Row {
            spacing: 5
            Layout.alignment: Qt.AlignVCenter
            Repeater {
                model: root.players
                Rectangle {
                    required property var modelData
                    readonly property bool active: modelData === root.player
                    anchors.verticalCenter: parent.verticalCenter
                    width: active ? 16 : 7
                    height: 7
                    radius: 3.5
                    color: active ? root.accent : modelData.isPlaying ? Qt.alpha(root.accent, 0.55) : Qt.alpha(root.fg, 0.25)
                    Behavior on width {
                        NumberAnimation {
                            duration: 150
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectPlayer(parent.modelData)
                    }
                }
            }
        }
        IconButton {
            text: String.fromCodePoint(0xF0142)   // chevron droit
            font.pixelSize: 20
            color: root.muted
            onActivated: root.cyclePlayer(1)
        }
    }

    // Bouton rond de thème : lune (sombre), soleil (clair), palette (fond d'écran)
    component ThemeButton: Item {
        id: tb
        width: 30
        height: 30
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: tbArea.containsMouse ? Qt.alpha(root.accent, 0.25) : Qt.alpha(root.bg, 0.55)
            border.color: Qt.alpha(root.accent, 0.45)
            Behavior on color {
                ColorAnimation {
                    duration: 150
                }
            }
        }
        Text {
            id: tbIcon
            anchors.centerIn: parent
            text: String.fromCodePoint(root.wall ? 0xF03D8 : root.aurora ? 0xF0674 : root.abyss ? 0xF0F01 : root.themeVideo ? 0xF0FCE : root.theme.light ? 0xF05A8 : 0xF0594)   // palette / étincelles / méduse / film / soleil / lune
            font.family: root.iconFont
            font.pixelSize: 16
            color: root.accent
            Behavior on rotation {
                NumberAnimation {
                    duration: 300
                    easing.type: Easing.OutBack
                }
            }
        }
        // Nom du thème, affiché un instant après le clic
        Rectangle {
            id: tbLabel
            anchors.left: parent.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: tbText.implicitWidth + 14
            height: 22
            radius: 11
            color: Qt.alpha(root.bg, 0.85)
            border.color: Qt.alpha(root.accent, 0.4)
            opacity: 0
            Text {
                id: tbText
                anchors.centerIn: parent
                text: root.theme.name
                font.family: root.font
                font.pixelSize: 11
                color: root.fg
            }
            SequentialAnimation {
                id: labelAnim
                NumberAnimation {
                    target: tbLabel
                    property: "opacity"
                    to: 1
                    duration: 150
                }
                PauseAnimation {
                    duration: 1000
                }
                NumberAnimation {
                    target: tbLabel
                    property: "opacity"
                    to: 0
                    duration: 400
                }
            }
        }
        MouseArea {
            id: tbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.nextTheme();
                tbIcon.rotation += 360;
                labelAnim.restart();
            }
        }
    }

    // Liste de favoris ou d'historique
    component LibraryList: Item {
        id: libList
        property var entries: []
        property string emptyText: ""
        property bool removable: false   // croix pour retirer (liste des récents)

        Text {
            anchors.centerIn: parent
            width: parent.width
            visible: libList.entries.length === 0
            text: libList.emptyText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.family: root.font
            font.pixelSize: 12
            font.italic: true
            color: Qt.alpha(root.muted, 0.8)
        }

        ListView {
            id: list
            anchors.fill: parent
            clip: true
            spacing: 4
            model: libList.entries
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property bool isCurrent: modelData.key === root.currentKey
                readonly property bool isFav: root.favorites.some(f => f.key === modelData.key)
                width: list.width
                height: 52
                radius: 10
                color: rowArea.containsMouse ? Qt.alpha(root.accent, 0.14) : isCurrent ? Qt.alpha(root.accent, 0.08) : "transparent"
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.playEntry(row.modelData)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 10
                    spacing: 12

                    ClippingRectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 8
                        color: Qt.lighter(root.bg, 1.6)
                        Image {
                            id: thumb
                            anchors.fill: parent
                            source: row.modelData.art || ""
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 96
                            asynchronous: true
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: thumb.status !== Image.Ready
                            text: String.fromCodePoint(0xF075A)
                            font.family: root.iconFont
                            font.pixelSize: 18
                            color: root.muted
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.title
                            font.family: root.font
                            font.pixelSize: 13
                            font.bold: row.isCurrent
                            color: row.isCurrent ? root.accent : root.fg
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.resolvingKey === row.modelData.key ? "Chargement…" : (row.modelData.artist || "—")
                            font.family: root.font
                            font.pixelSize: 11
                            color: root.muted
                            elide: Text.ElideRight
                        }
                    }
                    IconButton {
                        text: String.fromCodePoint(row.isFav ? 0xF02D1 : 0xF02D5)
                        font.pixelSize: 18
                        color: row.isFav ? root.accent : root.muted
                        opacity: row.isFav || rowArea.containsMouse ? 1 : 0.4
                        onActivated: {
                            if (row.isFav) {
                                root.removeFavorite(row.modelData.key);
                            } else {
                                root.favorites = [row.modelData].concat(root.favorites);
                                root.saveLibrary();
                            }
                        }
                    }
                    IconButton {
                        visible: libList.removable
                        text: String.fromCodePoint(0xF0156)   // croix
                        font.pixelSize: 16
                        color: root.muted
                        opacity: rowArea.containsMouse ? 1 : 0.35
                        onActivated: root.removeHistory(row.modelData.key)
                    }
                }
            }
        }
    }

    // Onglet cliquable (Paroles / Favoris / Récents)
    component TabButton: Text {
        id: tabBtn
        property string name
        property string label
        readonly property bool active: root.tab === name
        text: label
        font.family: root.font
        font.pixelSize: 12
        font.bold: active
        color: active ? root.accent : root.muted
        Rectangle {
            anchors.top: parent.bottom
            anchors.topMargin: 3
            width: parent.width
            height: 2
            radius: 1
            color: root.accent
            opacity: tabBtn.active ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onClicked: root.tab = tabBtn.name
        }
    }

    // Fond : pochette très floutée + dégradé
    component ArtBackground: Item {
        id: artBg
        property bool allowVideo: false        // vidéo seulement dans la fenêtre ; ailleurs, image fixe
        property bool horizontalShade: false   // assombrir vers la droite (texte à droite) ou vers le bas

        // Thème vidéo : boucle en fond (en pause quand le lecteur est caché)
        Loader {
            anchors.fill: parent
            active: root.themeVideo !== ""
            sourceComponent: artBg.allowVideo ? videoBg : posterBg
        }
        Component {
            id: videoBg
            Video {
                id: vid
                source: root.themeVideo
                loops: MediaPlayer.Infinite
                fillMode: VideoOutput.PreserveAspectCrop
                muted: true
                Component.onCompleted: if (root.onScreen) play()
                Connections {
                    target: root
                    function onOnScreenChanged() {
                        if (root.onScreen)
                            vid.play();
                        else
                            vid.pause();
                    }
                }
            }
        }
        Component {
            id: posterBg
            Image {
                source: root.themePoster
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }
        // Dégradé pour garder le texte lisible sur la vidéo
        Rectangle {
            anchors.fill: parent
            visible: root.themeVideo !== ""
            gradient: Gradient {
                orientation: artBg.horizontalShade ? Gradient.Horizontal : Gradient.Vertical
                GradientStop {
                    position: 0
                    color: Qt.alpha(root.bg, 0.1)
                }
                GradientStop {
                    position: 0.45
                    color: Qt.alpha(root.bg, 0.35)
                }
                GradientStop {
                    position: 1
                    color: Qt.alpha(root.bg, 0.88)
                }
            }
        }
        // Nappes de lumière qui dérivent (thème Aurore), gonflent sur les basses.
        // Dégradés circulaires (pas de flou recalculé à chaque image : bien plus léger).
        Item {
            anchors.fill: parent
            visible: root.aurora
            opacity: 0.55
            Repeater {
                model: root.aurora ? 3 : 0
                Shape {
                    id: blob
                    required property int index
                    property real t: index * 2.1
                    readonly property real base: Math.max(artBg.width, artBg.height) * 0.8
                    readonly property color tint: Qt.hsla((root.hue + index * 0.22) % 1, 0.85, 0.5, 1)
                    width: base
                    height: base
                    x: artBg.width * (0.5 + 0.38 * Math.cos(t)) - width / 2
                    y: artBg.height * (0.5 + 0.32 * Math.sin(t * 1.3 + index)) - height / 2
                    scale: 1 + root.bass * 0.3
                    Behavior on scale {
                        NumberAnimation {
                            duration: 120
                        }
                    }
                    ShapePath {
                        strokeColor: "transparent"
                        fillGradient: RadialGradient {
                            centerX: blob.base / 2
                            centerY: blob.base / 2
                            centerRadius: blob.base / 2
                            focalX: blob.base / 2
                            focalY: blob.base / 2
                            GradientStop {
                                position: 0
                                color: blob.tint
                            }
                            GradientStop {
                                position: 0.45
                                color: Qt.alpha(blob.tint, 0.45)
                            }
                            GradientStop {
                                position: 1
                                color: "transparent"
                            }
                        }
                        PathAngleArc {
                            centerX: blob.base / 2
                            centerY: blob.base / 2
                            radiusX: blob.base / 2
                            radiusY: blob.base / 2
                            startAngle: 0
                            sweepAngle: 360
                        }
                    }
                    NumberAnimation on t {
                        from: blob.index * 2.1
                        to: blob.index * 2.1 + Math.PI * 2
                        duration: 16000 + blob.index * 6000
                        loops: Animation.Infinite
                        running: root.aurora && root.onScreen
                    }
                }
            }
        }
        // Plancton lumineux (thème Abysse) : remonte lentement, s'illumine sur les battements
        Item {
            anchors.fill: parent
            visible: root.abyss
            clip: true
            Repeater {
                model: root.abyss ? 22 : 0
                Rectangle {
                    id: mote
                    required property int index
                    readonly property real sz: 1.5 + Math.random() * 2.5
                    readonly property real baseOp: 0.12 + Math.random() * 0.3
                    readonly property real offset: Math.random()          // point de départ aléatoire
                    readonly property real xr: Math.random()
                    readonly property real speed: 1 / (18 + Math.random() * 16)   // un tour en 18 à 34 s
                    width: sz
                    height: sz
                    radius: sz / 2
                    color: root.accent
                    x: xr * artBg.width
                    y: (artBg.height + 10) * (1 - (root.drift * speed + offset) % 1) - 5
                    opacity: Math.min(1, baseOp + root.flash * 0.75)
                }
            }
        }
        Image {
            property bool fellBack: false
            readonly property string wanted: root.artUrl
            onWantedChanged: fellBack = false
            onStatusChanged: if (status === Image.Error) fellBack = true
            anchors.fill: parent
            source: fellBack ? root.artFallback(wanted) : wanted
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 256
            asynchronous: true
            cache: false
            opacity: status === Image.Ready && root.themeVideo === "" ? (root.abyss ? 0.12 : root.aurora ? 0.3 : 0.6) : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 600
                }
            }
            layer.enabled: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1
                blurMax: 64
                saturation: 0.2
            }
        }
        Rectangle {
            anchors.fill: parent
            visible: root.themeVideo === ""
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: Qt.alpha(root.bg, 0.35)
                }
                GradientStop {
                    position: 1
                    color: Qt.alpha(root.bg, 0.88)
                }
            }
        }
    }

    // =====================================================================
    // Mode fenêtre
    // =====================================================================
    LazyLoader {
        active: root.mode === "window"

        FloatingWindow {
            id: win
            title: "Lecteur musique"
            implicitWidth: 860
            implicitHeight: 460
            color: root.bg

            readonly property bool wide: width > height * 1.15
            // Petite tuile : on ne garde que visualiseur, boutons et volume
            readonly property bool compact: width < 500 || (wide ? height < 380 : height < 620)
            // Toute petite : boutons + volume sur une ligne, visualiseur en fond
            readonly property bool tiny: compact && height < 170

            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: event => {
                    if (!root.player)
                        return;
                    if (event.key === Qt.Key_Space)
                        root.player.togglePlaying();
                    else if (event.key === Qt.Key_N)
                        root.player.next();
                    else if (event.key === Qt.Key_P)
                        root.player.previous();
                    else if (event.key === Qt.Key_F)
                        root.toggleFavorite();
                    else if (event.key === Qt.Key_Right && root.player.canSeek)
                        root.player.position = Math.min(root.player.length, root.player.position + 5);
                    else if (event.key === Qt.Key_Left && root.player.canSeek)
                        root.player.position = Math.max(0, root.player.position - 5);
                }

                ArtBackground {
                    anchors.fill: parent
                    allowVideo: true
                    horizontalShade: win.wide && !win.compact
                }

                ThemeButton {
                    x: 8
                    y: 8
                    z: 10
                }

                Loader {
                    anchors.fill: parent
                    active: !win.compact
                    sourceComponent: Component {
                        GridLayout {
                            anchors.fill: parent
                            anchors.margins: 28
                            columns: win.wide ? 2 : 1
                            columnSpacing: 36
                            rowSpacing: 18

                            Disc {
                                size: win.wide ? Math.min(win.height - 56, win.width * 0.45) : Math.min(win.width - 56, win.height * 0.42)
                                Layout.preferredWidth: size
                                Layout.preferredHeight: size
                                Layout.alignment: Qt.AlignCenter
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 6

                                // Lecteur (clic = changer s'il y en a plusieurs) + favori
                                RowLayout {
                                    visible: root.player !== null
                                    Layout.fillWidth: true
                                    // Une pastille par source ; clic = la choisir
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: root.players
                                            SourceChip {
                                                required property var modelData
                                                source: modelData
                                            }
                                        }
                                    }
                                    HeartButton {
                                        Layout.alignment: Qt.AlignTop
                                        font.pixelSize: 24
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    text: root.player ? root.track.title : "Rien en lecture"
                                    font.family: root.font
                                    font.pixelSize: 26
                                    horizontalAlignment: win.wide ? Text.AlignLeft : Text.AlignHCenter
                                    font.bold: true
                                    color: root.fg
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.player ? root.track.artist : "Lance une musique, ou un de tes favoris ci-dessous"
                                    font.family: root.font
                                    font.pixelSize: 15
                                    horizontalAlignment: win.wide ? Text.AlignLeft : Text.AlignHCenter
                                    color: root.player ? root.accent : root.muted
                                    elide: Text.ElideRight
                                }

                                ProgressBar {
                                    visible: root.player !== null
                                    Layout.fillWidth: true
                                    Layout.topMargin: 14
                                }
                                RowLayout {
                                    visible: root.player !== null
                                    Layout.fillWidth: true
                                    Text {
                                        text: root.fmtTime(root.player?.position ?? 0)
                                        font.family: root.font
                                        font.pixelSize: 12
                                        color: root.muted
                                    }
                                    Item {
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        text: root.fmtTime(root.player?.length ?? 0)
                                        font.family: root.font
                                        font.pixelSize: 12
                                        color: root.muted
                                    }
                                }

                                Controls {
                                    visible: root.player !== null
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: 4
                                }
                                VolumeBar {
                                    visible: root.player !== null
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredWidth: Math.min(parent.width, 320)
                                    Layout.topMargin: 2
                                }

                                // Onglets
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 12
                                    spacing: 20
                                    TabButton {
                                        name: "lyrics"
                                        label: "Paroles"
                                    }
                                    TabButton {
                                        name: "favorites"
                                        label: "Favoris" + (root.favorites.length ? ` (${root.favorites.length})` : "")
                                    }
                                    TabButton {
                                        name: "history"
                                        label: "Récents"
                                    }
                                }

                                // Contenu de l'onglet
                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.topMargin: 8
                                    Layout.minimumHeight: 0
                                    clip: true
                                    opacity: height > 50 ? 1 : 0

                                    // Paroles synchronisées
                                    Item {
                                        anchors.fill: parent
                                        visible: root.tab === "lyrics"

                                        ListView {
                                            id: lyricsView
                                            anchors.fill: parent
                                            visible: root.lyricsState === "synced"
                                            model: root.lyrics
                                            interactive: false
                                            spacing: 6
                                            currentIndex: Math.max(0, root.lyricIndex)
                                            highlightRangeMode: ListView.StrictlyEnforceRange
                                            preferredHighlightBegin: height / 2 - 14
                                            preferredHighlightEnd: height / 2 + 14
                                            highlightMoveDuration: 450
                                            delegate: Text {
                                                required property var modelData
                                                required property int index
                                                readonly property bool current: index === root.lyricIndex
                                                width: lyricsView.width
                                                horizontalAlignment: win.wide ? Text.AlignLeft : Text.AlignHCenter
                                                text: modelData.text || "♪"
                                                wrapMode: Text.WordWrap
                                                font.family: root.font
                                                font.pixelSize: current ? 17 : 14
                                                font.bold: current
                                                color: current ? root.fg : root.muted
                                                opacity: current ? 1 : Math.max(0.15, 0.6 - Math.abs(index - root.lyricIndex) * 0.12)
                                                Behavior on opacity {
                                                    NumberAnimation {
                                                        duration: 300
                                                    }
                                                }
                                            }
                                        }
                                        Text {
                                            anchors.fill: parent
                                            visible: root.lyricsState === "plain"
                                            text: root.plainLyrics
                                            wrapMode: Text.WordWrap
                                            font.family: root.font
                                            font.pixelSize: 13
                                            color: root.muted
                                            horizontalAlignment: win.wide ? Text.AlignLeft : Text.AlignHCenter
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            visible: root.lyricsState === "loading" || root.lyricsState === "none"
                                            text: !root.player ? "" : root.lyricsState === "loading" ? "Recherche des paroles…" : "Pas de paroles pour ce morceau"
                                            font.family: root.font
                                            font.pixelSize: 12
                                            font.italic: true
                                            color: Qt.alpha(root.muted, 0.7)
                                        }
                                    }

                                    LibraryList {
                                        anchors.fill: parent
                                        visible: root.tab === "favorites"
                                        entries: root.favorites
                                        emptyText: "Aucun favori pour l'instant.\nClique sur le cœur pendant une musique (ou touche F)."
                                    }
                                    LibraryList {
                                        anchors.fill: parent
                                        visible: root.tab === "history"
                                        entries: root.history
                                        removable: true
                                        emptyText: "Les musiques écoutées plus de 20 s apparaîtront ici."
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- Mode compact ----
                Loader {
                    anchors.fill: parent
                    active: win.compact
                    sourceComponent: Component {
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: win.tiny ? 8 : 14
                            spacing: win.tiny ? 4 : 8

                            LinearVisualizer {
                                parent: win.contentItem
                                visible: win.tiny
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height * 0.7
                                opacity: 0.35
                                z: -1
                            }

                            Item {
                                visible: win.tiny
                                Layout.fillHeight: true
                            }
                            SourceSwitcher {
                                visible: root.players.length > 1
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Item {
                                id: visArea
                                visible: !win.tiny
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.minimumHeight: 22
                                readonly property real discSize: Math.min(width, height)
                                Disc {
                                    anchors.centerIn: parent
                                    size: visArea.discSize
                                    visible: visArea.discSize >= 90
                                }
                                LinearVisualizer {
                                    anchors.fill: parent
                                    visible: visArea.discSize < 90
                                }
                            }

                            Text {
                                visible: root.player === null
                                Layout.alignment: Qt.AlignHCenter
                                text: "Rien en lecture"
                                font.family: root.font
                                font.pixelSize: 13
                                color: root.muted
                            }
                            ProgressBar {
                                visible: root.player !== null
                                Layout.fillWidth: true
                                implicitHeight: 12
                            }
                            GridLayout {
                                visible: root.player !== null
                                Layout.fillWidth: true
                                columns: win.tiny ? 2 : 1
                                columnSpacing: 12
                                rowSpacing: 8
                                Controls {
                                    k: win.tiny ? 0.5 : Math.max(0.55, Math.min(0.9, win.width / 460))
                                    Layout.alignment: Qt.AlignHCenter
                                }
                                VolumeBar {
                                    k: win.tiny ? 0.75 : 0.85
                                    Layout.fillWidth: true
                                }
                            }
                            Item {
                                visible: win.tiny
                                Layout.fillHeight: true
                            }
                        }
                    }
                }
            }
        }
    }

    // =====================================================================
    // Mode bord d'écran : languette + carte qui sort au survol
    // =====================================================================
    LazyLoader {
        active: root.mode === "dock"

        PanelWindow {
            id: dock
            screen: root.dockScreen
            readonly property bool vertical: root.edge === "left" || root.edge === "right"   // bord vertical
            readonly property int cardW: 400
            readonly property int cardH: 172
            readonly property int gap: 10          // écart carte / bord quand elle est sortie
            readonly property int handleLen: 90
            readonly property int handleZone: 10   // épaisseur de la zone de survol quand c'est rangé

            anchors {
                left: root.edge === "left"
                right: root.edge === "right"
                top: root.edge === "top"
                bottom: root.edge === "bottom"
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "music-player-dock"
            color: "transparent"
            implicitWidth: vertical ? cardW + gap : cardW
            implicitHeight: vertical ? cardH : cardH + gap

            // Seule la partie visible attrape la souris
            mask: Region {
                item: dock.open ? openZone : hotZone
            }
            // Carte sortie : toute la surface (carte + écart au bord) garde le survol
            Item {
                id: openZone
                anchors.fill: parent
            }

            property bool open: false
            onOpenChanged: root.dockOpen = open
            Component.onDestruction: root.dockOpen = false
            HoverHandler {
                onHoveredChanged: {
                    if (hovered) {
                        closeDelay.stop();
                        dock.open = true;
                    } else {
                        closeDelay.restart();
                    }
                }
            }
            Timer {
                id: closeDelay
                interval: 450
                onTriggered: dock.open = false
            }

            // Zone de survol collée au bord (quand la carte est rangée)
            Item {
                id: hotZone
                width: dock.vertical ? dock.handleZone : dock.handleLen + 40
                height: dock.vertical ? dock.handleLen + 40 : dock.handleZone
                x: root.edge === "right" ? dock.width - width : root.edge === "left" ? 0 : (dock.width - width) / 2
                y: root.edge === "bottom" ? dock.height - height : root.edge === "top" ? 0 : (dock.height - height) / 2
            }

            // Languette
            Rectangle {
                width: dock.vertical ? 5 : dock.handleLen
                height: dock.vertical ? dock.handleLen : 5
                radius: 3
                x: root.edge === "right" ? dock.width - width - 2 : root.edge === "left" ? 2 : (dock.width - width) / 2
                y: root.edge === "bottom" ? dock.height - height - 2 : root.edge === "top" ? 2 : (dock.height - height) / 2
                color: root.accent
                opacity: dock.open ? 0 : root.playing ? 0.95 : 0.5
                Behavior on opacity {
                    NumberAnimation {
                        duration: 200
                    }
                }
                SequentialAnimation on scale {
                    running: root.playing && !dock.open
                    loops: Animation.Infinite
                    NumberAnimation {
                        to: 1.15
                        duration: 900
                        easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                        to: 1
                        duration: 900
                        easing.type: Easing.InOutSine
                    }
                }
            }

            // Carte
            ClippingRectangle {
                id: card
                width: dock.cardW
                height: dock.cardH
                radius: 18
                color: root.bg
                border.color: Qt.alpha(root.accent, 0.35)
                border.width: 1

                x: {
                    if (root.edge === "left")
                        return dock.open ? dock.gap : -dock.cardW - 2;
                    if (root.edge === "right")
                        return dock.open ? 0 : dock.width + 2;
                    return 0;
                }
                y: {
                    if (root.edge === "top")
                        return dock.open ? dock.gap : -dock.cardH - 2;
                    if (root.edge === "bottom")
                        return dock.open ? 0 : dock.height + 2;
                    return 0;
                }
                Behavior on x {
                    NumberAnimation {
                        duration: 260
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on y {
                    NumberAnimation {
                        duration: 260
                        easing.type: Easing.OutCubic
                    }
                }

                ArtBackground {
                    anchors.fill: parent
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 12

                    Disc {
                        size: dock.cardH - 24
                        Layout.preferredWidth: size
                        Layout.preferredHeight: size
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: root.player ? root.track.title : "Rien en lecture"
                                font.family: root.font
                                font.pixelSize: 15
                                font.bold: true
                                color: root.fg
                                elide: Text.ElideRight
                            }
                            IconButton {
                                visible: root.players.length > 1
                                text: String.fromCodePoint(0xF04E1)   // changer de source
                                font.pixelSize: 17
                                color: root.muted
                                onActivated: root.cyclePlayer()
                            }
                            HeartButton {
                                font.pixelSize: 18
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.player ? root.track.artist + (root.players.length > 1 ? "  ·  " + root.sourceLabel(root.player) : "") : ""
                            font.family: root.font
                            font.pixelSize: 12
                            color: root.accent
                            elide: Text.ElideRight
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                        ProgressBar {
                            visible: root.player !== null
                            Layout.fillWidth: true
                        }
                        Controls {
                            visible: root.player !== null
                            k: 0.62
                            Layout.alignment: Qt.AlignHCenter
                        }
                        VolumeBar {
                            visible: root.player !== null
                            k: 0.8
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }
}
