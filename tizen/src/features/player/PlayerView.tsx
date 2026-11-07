import { Component, createSignal, onMount, onCleanup, Show, For } from 'solid-js';
import { AVPlayerService, FULL_SCREEN, TrackInfo } from '../../core/player/AVPlayerService';
import { HttpClient } from '../../core/net/HttpClient';
import { ItemRecord } from '../../core/storage/Database';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { spatialNav } from '../../ui/design/SpatialNav';
import { announce } from '../../ui/design/a11y';

export interface PlayerViewProps {
  item: ItemRecord;
  onExit: () => void;
  onNextChannel?: () => void;
  onPrevChannel?: () => void;
}

export const PlayerView: Component<PlayerViewProps> = (props) => {
  const player = AVPlayerService.getInstance();
  const net = HttpClient.getInstance();

  const [isPlaying, setIsPlaying] = createSignal(true);
  const [currentTimeMs, setCurrentTimeMs] = createSignal(0);
  const [durationMs, setDurationMs] = createSignal(0);
  const [showOsd, setShowOsd] = createSignal(true);
  const [isBuffering, setIsBuffering] = createSignal(false);
  const [bufferingPercent, setBufferingPercent] = createSignal(0);
  const [playerError, setPlayerError] = createSignal<string | null>(null);
  const [activeSubtitle, setActiveSubtitle] = createSignal<string>('');
  const [subtitleTimer, setSubtitleTimer] = createSignal<any>(null);
  const [audioTracks, setAudioTracks] = createSignal<TrackInfo[]>([]);
  const [activeAudioIndex, setActiveAudioIndex] = createSignal(0);
  const [subtitleTracks, setSubtitleTracks] = createSignal<TrackInfo[]>([]);
  const [activeSubIndex, setActiveSubIndex] = createSignal(-1);
  const [showChannelHud, setShowChannelHud] = createSignal(true);
  const [focusId] = spatialNav.getFocusSignal();

  let osdTimer: any = null;
  let hudTimer: any = null;
  let keyUnsub: (() => void) | null = null;

  const updateGrid = () => {
    if (playerError()) {
      spatialNav.setGrid([
        [
          { id: 'btn-player-retry', onSelect: retryPlayback },
          { id: 'btn-player-exit', onSelect: () => { player.stop(); props.onExit(); } },
        ],
      ]);
      return;
    }

    const isLive = props.item.kind === 'live';
    const actionRow = [
      {
        id: 'btn-osd-play-pause',
        onSelect: togglePlayPause,
      },
      ...(!isLive
        ? [
            { id: 'btn-osd-seek-back', onSelect: () => seekDelta(-10000) },
            { id: 'btn-osd-seek-fwd', onSelect: () => seekDelta(10000) },
          ]
        : [
            ...(props.onPrevChannel ? [{ id: 'btn-osd-prev-ch', onSelect: () => props.onPrevChannel?.() }] : []),
            ...(props.onNextChannel ? [{ id: 'btn-osd-next-ch', onSelect: () => props.onNextChannel?.() }] : []),
          ]),
      {
        id: 'btn-osd-audio-track',
        onSelect: cycleAudioTrack,
      },
      {
        id: 'btn-osd-sub-track',
        onSelect: cycleSubtitleTrack,
      },
    ];

    spatialNav.setGrid([actionRow]);
  };

  onMount(() => {
    // 1. Ensure AVPlay hardware video surface is sized to full screen
    player.setDisplayArea(FULL_SCREEN);

    // 2. Announce channel / title to Voice Guide screen reader
    const title = props.item.name_clean || props.item.name;
    announce(`Lecture de ${title}. Appuyez sur Bas pour afficher les contrôles de lecture.`);

    // 3. Set up player listeners
    player.setListener({
      onBufferingStart: () => {
        setIsBuffering(true);
        setPlayerError(null);
      },
      onBufferingProgress: (pct) => setBufferingPercent(pct),
      onBufferingComplete: () => {
        setIsBuffering(false);
        setIsPlaying(true);
      },
      onCurrentPlayTime: (ms) => {
        setCurrentTimeMs(ms);
        setDurationMs(player.getDuration());
      },
      onError: (err) => {
        console.error('Player error:', err);
        setPlayerError(err);
        setIsBuffering(false);
        announce(`Erreur : ${err}`);
        updateGrid();
      },
      onSubtitleChange: (text, duration) => {
        const clean = text?.trim();
        setActiveSubtitle(clean);
        if (subtitleTimer()) clearTimeout(subtitleTimer());
        if (clean) {
          const timeout = duration > 0 ? duration : 5000;
          setSubtitleTimer(setTimeout(() => setActiveSubtitle(''), timeout));
        }
      },
      onStallDetected: () => {
        console.warn('Playback stalled, attempting recovery...');
        player.pause();
        player.play();
      },
      onStreamCompleted: () => {
        if (props.item.kind !== 'live') {
          announce('Lecture terminée');
          props.onExit();
        }
      },
    });

    // Detect audio and subtitle tracks once metadata is parsed
    setTimeout(() => {
      const all = player.getTracks();
      const a = all.filter((t) => t.type === 'AUDIO');
      const s = all.filter((t) => t.type === 'TEXT');
      setAudioTracks(a);
      setSubtitleTracks(s);
    }, 2000);

    resetOsdTimer();
    triggerChannelHud();

    // Listen to remote keys
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleKey);
    updateGrid();
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
    if (osdTimer) clearTimeout(osdTimer);
    if (hudTimer) clearTimeout(hudTimer);
    if (subtitleTimer()) clearTimeout(subtitleTimer());
    player.stop();
  });

  const resetOsdTimer = () => {
    setShowOsd(true);
    if (osdTimer) clearTimeout(osdTimer);
    osdTimer = setTimeout(() => {
      setShowOsd(false);
    }, 5000);
  };

  const triggerChannelHud = () => {
    setShowChannelHud(true);
    if (hudTimer) clearTimeout(hudTimer);
    hudTimer = setTimeout(() => {
      setShowChannelHud(false);
    }, 4000);
  };

  const togglePlayPause = () => {
    if (isPlaying()) {
      player.pause();
      setIsPlaying(false);
      announce('Pause');
    } else {
      player.play();
      setIsPlaying(true);
      announce('Lecture');
    }
    resetOsdTimer();
  };

  const seekDelta = (deltaMs: number) => {
    const target = Math.max(0, currentTimeMs() + deltaMs);
    player.seekTo(target);
    const secs = Math.abs(Math.round(deltaMs / 1000));
    announce(deltaMs > 0 ? `Avance rapide de ${secs} secondes` : `Retour arrière de ${secs} secondes`);
    resetOsdTimer();
  };

  const cycleAudioTrack = () => {
    const tracks = audioTracks();
    if (tracks.length <= 1) {
      announce('Piste audio unique');
      return;
    }
    const nextIdx = (activeAudioIndex() + 1) % tracks.length;
    setActiveAudioIndex(nextIdx);
    player.selectTrack('AUDIO', tracks[nextIdx].index);
    const lang = tracks[nextIdx].extra_info?.language || `Piste ${nextIdx + 1}`;
    announce(`Piste audio : ${lang}`);
    resetOsdTimer();
  };

  const cycleSubtitleTrack = () => {
    const tracks = subtitleTracks();
    if (tracks.length === 0) {
      announce('Aucun sous-titre disponible sur ce flux');
      return;
    }
    // -1 = Disabled, 0..N = Track index
    const nextIdx = activeSubIndex() + 1 >= tracks.length ? -1 : activeSubIndex() + 1;
    setActiveSubIndex(nextIdx);
    if (nextIdx === -1) {
      player.setSubtitlesEnabled(false);
      setActiveSubtitle('');
      announce('Sous-titres désactivés');
    } else {
      player.setSubtitlesEnabled(true);
      player.selectTrack('TEXT', tracks[nextIdx].index);
      const lang = tracks[nextIdx].extra_info?.language || `Sous-titre ${nextIdx + 1}`;
      announce(`Sous-titres : ${lang}`);
    }
    resetOsdTimer();
  };

  const retryPlayback = async () => {
    setPlayerError(null);
    setIsBuffering(true);
    announce('Nouvelle tentative de connexion…');
    try {
      await player.open(props.item.stream_url, props.item.kind === 'live');
      player.play();
      updateGrid();
    } catch (err: any) {
      setPlayerError(err?.message || 'Échec de connexion');
      updateGrid();
    }
  };

  const handleKey = (key: RemoteKey): boolean => {
    if (key === 'BACK') {
      if (showOsd()) {
        setShowOsd(false);
        return true;
      }
      player.stop();
      props.onExit();
      return true;
    }

    if (key === 'PLAY' || key === 'PAUSE' || key === 'PLAY_PAUSE') {
      togglePlayPause();
      return true;
    }

    if (key === 'FAST_FORWARD') {
      seekDelta(30000);
      return true;
    }

    if (key === 'REWIND') {
      seekDelta(-30000);
      return true;
    }

    if (key === 'CHANNEL_UP' || (key === 'UP' && !showOsd() && props.item.kind === 'live')) {
      if (props.onNextChannel) {
        props.onNextChannel();
        triggerChannelHud();
        return true;
      }
    }

    if (key === 'CHANNEL_DOWN' || (key === 'DOWN' && !showOsd() && props.item.kind === 'live')) {
      if (props.onPrevChannel) {
        props.onPrevChannel();
        triggerChannelHud();
        return true;
      }
    }

    // Any arrow or enter key brings back the OSD
    if (key === 'UP' || key === 'DOWN' || key === 'LEFT' || key === 'RIGHT' || key === 'ENTER') {
      if (!showOsd()) {
        resetOsdTimer();
        return true;
      }
    }

    resetOsdTimer();
    return false;
  };

  const formatTime = (ms: number) => {
    const s = Math.floor(ms / 1000);
    const m = Math.floor(s / 60);
    const h = Math.floor(m / 60);
    const secs = s % 60;
    const mins = m % 60;
    if (h > 0) {
      return `${h}:${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
    }
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  const progressPct = () => {
    if (!durationMs()) return 0;
    return Math.min(100, (currentTimeMs() / durationMs()) * 100);
  };

  const audioLabel = () => {
    const tracks = audioTracks();
    if (tracks.length === 0) return 'Audio';
    const curr = tracks[activeAudioIndex()];
    return `Audio: ${curr?.extra_info?.language?.toUpperCase() || (activeAudioIndex() + 1)}`;
  };

  const subtitleLabel = () => {
    if (activeSubIndex() === -1) return 'Sous-titres : Désactivés';
    const curr = subtitleTracks()[activeSubIndex()];
    return `Sous-titres : ${curr?.extra_info?.language?.toUpperCase() || (activeSubIndex() + 1)}`;
  };

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        width: "100%",
        height: "100%",
        background: "transparent",
        overflow: "hidden",
      }}
      role="region"
      aria-label={`Lecteur vidéo : ${props.item.name_clean || props.item.name}`}
    >
      {/* 1. Channel HUD banner (briefly appears on channel switch / entry) */}
      <Show when={showChannelHud() && props.item.kind === 'live'}>
        <div class="tv-channel-hud" role="status" aria-live="polite">
          <div style={{
            background: "var(--buntu-gold)",
            color: "#000000",
            "font-weight": "800",
            "font-size": "20px",
            padding: "4px 12px",
            "border-radius": "6px",
          }}>
            {props.item.chno ? `CH ${props.item.chno}` : 'LIVE'}
          </div>
          <div>
            <div style={{ "font-size": "26px", "font-weight": "800", color: "#FFFFFF" }}>
              {props.item.name_clean || props.item.name}
            </div>
            <div style={{ "font-size": "18px", color: "var(--buntu-cyan)" }}>
              {props.item.group_title || 'Direct TV'}
            </div>
          </div>
        </div>
      </Show>

      {/* 2. Rate limit 429 warning banner */}
      <Show when={net.isRateLimited()}>
        <div style={{
          position: "absolute",
          top: "48px",
          left: "50%",
          transform: "translateX(-50%)",
          background: "var(--buntu-danger)",
          color: "#FFFFFF",
          padding: "16px 32px",
          "border-radius": "12px",
          "font-size": "24px",
          "font-weight": "800",
          "box-shadow": "0 8px 24px rgba(0,0,0,0.8)",
          "z-index": 100
        }} role="alert">
          Serveur saturé (HTTP 429). Reprise dans {net.getRateLimitSecondsRemaining()}s...
        </div>
      </Show>

      {/* 3. Buffering indicator */}
      <Show when={isBuffering() && !playerError()}>
        <div style={{
          position: "absolute",
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          background: "rgba(0,0,0,0.8)",
          padding: "24px 48px",
          "border-radius": "16px",
          display: "flex",
          "align-items": "center",
          gap: "16px",
          "z-index": 90
        }} role="status" aria-label="Chargement du flux vidéo">
          <div class="tv-spinner" style={{ width: "40px", height: "40px", "border-width": "4px" }} />
          <div style={{ "font-size": "24px", "font-weight": "700" }}>
            Chargement... {bufferingPercent() > 0 ? `${bufferingPercent()}%` : ''}
          </div>
        </div>
      </Show>

      {/* 4. Playback Error Screen */}
      <Show when={playerError()}>
        <div class="tv-player-error-card" role="alert">
          <div style={{ "font-size": "48px" }}>⚠️</div>
          <h2 style={{ "font-size": "32px", color: "var(--buntu-danger)", margin: 0 }}>
            Problème de lecture
          </h2>
          <p style={{ "font-size": "22px", color: "var(--buntu-text)", margin: 0 }}>
            {playerError()}
          </p>
          <div style={{ display: "flex", gap: "20px", "margin-top": "8px" }}>
            <button
              class={`tv-btn ${focusId() === 'btn-player-retry' ? 'focused' : ''}`}
              onClick={retryPlayback}
            >
              🔄 Réessayer
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-player-exit' ? 'focused' : ''}`}
              onClick={() => { player.stop(); props.onExit(); }}
            >
              ← Retour aux chaînes
            </button>
          </div>
        </div>
      </Show>

      {/* 5. Subtitle text rendering */}
      <Show when={activeSubtitle() && !showOsd()}>
        <div class="tv-subtitle-box" aria-live="off">
          {activeSubtitle()}
        </div>
      </Show>

      {/* 6. OSD Controls Overlay */}
      <Show when={showOsd() && !playerError()}>
        <div class="tv-osd">
          <div style={{ display: "flex", "justify-content": "space-between", "align-items": "flex-end" }}>
            <div>
              <div style={{ "font-size": "18px", color: "var(--buntu-cyan)", "font-weight": "800", "letter-spacing": "1px" }}>
                {props.item.kind === 'live' ? '● EN DIRECT' : 'FILM / SÉRIE'}
              </div>
              <h1 style={{ "font-size": "36px", "font-weight": "800", "margin-top": "4px" }}>
                {props.item.name_clean || props.item.name}
              </h1>
            </div>
            <div style={{ "font-size": "22px", color: "var(--buntu-text-muted)", "font-weight": "700" }}>
              {props.item.kind === 'live' ? 'Direct TV' : `${formatTime(currentTimeMs())} / ${formatTime(durationMs())}`}
            </div>
          </div>

          {/* Progress bar (VOD only) */}
          <Show when={props.item.kind !== 'live'}>
            <div class="tv-osd-progress-bg">
              <div class="tv-osd-progress-fill" style={{ width: `${progressPct()}%` }} />
            </div>
          </Show>

          {/* Action buttons */}
          <div style={{ display: "flex", gap: "16px", "margin-top": "12px", "align-items": "center" }}>
            <button
              class={`tv-btn ${focusId() === 'btn-osd-play-pause' ? 'focused' : ''}`}
              onClick={togglePlayPause}
              aria-label={isPlaying() ? 'Mettre en pause' : 'Reprendre la lecture'}
            >
              {isPlaying() ? '⏸ Pause' : '▶ Lecture'}
            </button>

            <Show when={props.item.kind !== 'live'}>
              <button
                class={`tv-btn ${focusId() === 'btn-osd-seek-back' ? 'focused' : ''}`}
                onClick={() => seekDelta(-10000)}
                aria-label="Reculer de 10 secondes"
              >
                ⏪ -10s
              </button>
              <button
                class={`tv-btn ${focusId() === 'btn-osd-seek-fwd' ? 'focused' : ''}`}
                onClick={() => seekDelta(10000)}
                aria-label="Avancer de 10 secondes"
              >
                ⏩ +10s
              </button>
            </Show>

            <Show when={props.item.kind === 'live'}>
              <Show when={props.onPrevChannel}>
                <button
                  class={`tv-btn ${focusId() === 'btn-osd-prev-ch' ? 'focused' : ''}`}
                  onClick={() => { props.onPrevChannel?.(); triggerChannelHud(); }}
                  aria-label="Chaîne précédente"
                >
                  ⏮ Chaîne précédente
                </button>
              </Show>
              <Show when={props.onNextChannel}>
                <button
                  class={`tv-btn ${focusId() === 'btn-osd-next-ch' ? 'focused' : ''}`}
                  onClick={() => { props.onNextChannel?.(); triggerChannelHud(); }}
                  aria-label="Chaîne suivante"
                >
                  ⏭ Chaîne suivante
                </button>
              </Show>
            </Show>

            <button
              class={`tv-btn ${focusId() === 'btn-osd-audio-track' ? 'focused' : ''}`}
              onClick={cycleAudioTrack}
              aria-label={audioLabel()}
            >
              🔊 {audioLabel()}
            </button>

            <button
              class={`tv-btn ${focusId() === 'btn-osd-sub-track' ? 'focused' : ''}`}
              onClick={cycleSubtitleTrack}
              aria-label={subtitleLabel()}
            >
              💬 {subtitleLabel()}
            </button>
          </div>
        </div>
      </Show>
    </div>
  );
};
