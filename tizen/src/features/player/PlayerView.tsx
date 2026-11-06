import { Component, createSignal, onMount, onCleanup, Show } from 'solid-js';
import { AVPlayerService, TrackInfo } from '../../core/player/AVPlayerService';
import { HttpClient } from '../../core/net/HttpClient';
import { ItemRecord } from '../../core/storage/Database';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { spatialNav } from '../../ui/design/SpatialNav';

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
  const [rateLimitWaitSecs, setRateLimitWaitSecs] = createSignal(0);
  const [subtitleOffsetMs, setSubtitleOffsetMs] = createSignal(0);
  const [audioTracks, setAudioTracks] = createSignal<TrackInfo[]>([]);
  const [activeAudioIndex, setActiveAudioIndex] = createSignal(0);
  const [subtitleTracks, setSubtitleTracks] = createSignal<TrackInfo[]>([]);
  const [activeSubIndex, setActiveSubIndex] = createSignal(-1);
  const [focusId] = spatialNav.getFocusSignal();

  let osdTimer: any = null;
  let keyUnsub: (() => void) | null = null;

  onMount(() => {
    player.setListener({
      onBufferingStart: () => setIsBuffering(true),
      onBufferingProgress: (pct) => setBufferingPercent(pct),
      onBufferingComplete: () => setIsBuffering(false),
      onCurrentPlayTime: (ms) => {
        setCurrentTimeMs(ms);
        setDurationMs(player.getDuration());
      },
      onError: (err) => {
        console.error('Player error:', err);
      },
      onStallDetected: () => {
        console.warn('Playback stalled, attempting recovery...');
        player.pause();
        player.play();
      },
    });

    // Detect tracks
    setTimeout(() => {
      const all = player.getTracks();
      setAudioTracks(all.filter((t) => t.type === 'AUDIO'));
      setSubtitleTracks(all.filter((t) => t.type === 'TEXT'));
    }, 1500);

    resetOsdTimer();

    // Listen to remote keys
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleKey);

    spatialNav.setGrid([
      [
        {
          id: 'btn-osd-play-pause',
          onSelect: togglePlayPause,
        },
        {
          id: 'btn-osd-seek-back',
          onSelect: () => seekDelta(-10000),
        },
        {
          id: 'btn-osd-seek-fwd',
          onSelect: () => seekDelta(10000),
        },
        {
          id: 'btn-osd-sub-sync',
          onSelect: adjustSubtitleSync,
        },
      ],
    ]);
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
    if (osdTimer) clearTimeout(osdTimer);
  });

  const resetOsdTimer = () => {
    setShowOsd(true);
    if (osdTimer) clearTimeout(osdTimer);
    osdTimer = setTimeout(() => {
      setShowOsd(false);
    }, 5000);
  };

  const togglePlayPause = () => {
    if (isPlaying()) {
      player.pause();
      setIsPlaying(false);
    } else {
      player.play();
      setIsPlaying(true);
    }
    resetOsdTimer();
  };

  const seekDelta = (deltaMs: number) => {
    const target = Math.max(0, currentTimeMs() + deltaMs);
    player.seekTo(target);
    resetOsdTimer();
  };

  const adjustSubtitleSync = () => {
    const nextOffset = (subtitleOffsetMs() + 250) % 2000;
    setSubtitleOffsetMs(nextOffset);
    player.setSubtitlePosition(nextOffset);
    resetOsdTimer();
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

    if (key === 'CHANNEL_UP') {
      props.onNextChannel?.();
      return true;
    }

    if (key === 'CHANNEL_DOWN') {
      props.onPrevChannel?.();
      return true;
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

  return (
    <div style={{ position: "absolute", top: 0, left: 0, width: "1920px", height: "1080px" }}>
      {/* Rate limit 429 warning banner */}
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
        }}>
          Serveur saturé (HTTP 429). Reprise dans {net.getRateLimitSecondsRemaining()}s...
        </div>
      </Show>

      {/* Buffering spinner */}
      <Show when={isBuffering()}>
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
        }}>
          <div style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>⏳</div>
          <div style={{ "font-size": "24px", "font-weight": "700" }}>
            Chargement... {bufferingPercent() > 0 ? `${bufferingPercent()}%` : ''}
          </div>
        </div>
      </Show>

      {/* OSD Overlay */}
      <Show when={showOsd()}>
        <div class="tv-osd">
          <div style={{ display: "flex", "justify-content": "space-between", "align-items": "flex-end" }}>
            <div>
              <div style={{ "font-size": "16px", color: "var(--buntu-cyan)", "font-weight": "700" }}>
                {props.item.kind === 'live' ? 'EN DIRECT' : 'FILM / SÉRIE'}
              </div>
              <h1 style={{ "font-size": "36px", "font-weight": "800", "margin-top": "4px" }}>
                {props.item.name_clean || props.item.name}
              </h1>
            </div>
            <div style={{ "font-size": "20px", color: "var(--buntu-text-muted)" }}>
              {formatTime(currentTimeMs())} / {formatTime(durationMs())}
            </div>
          </div>

          {/* Progress bar */}
          <div class="tv-osd-progress-bg">
            <div class="tv-osd-progress-fill" style={{ width: `${progressPct()}%` }} />
          </div>

          {/* Action buttons */}
          <div style={{ display: "flex", gap: "16px", "margin-top": "8px" }}>
            <button
              class={`tv-btn ${focusId() === 'btn-osd-play-pause' ? 'focused' : ''}`}
              onClick={togglePlayPause}
            >
              {isPlaying() ? '⏸ Pause' : '▶ Lecture'}
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-osd-seek-back' ? 'focused' : ''}`}
              onClick={() => seekDelta(-10000)}
            >
              ⏪ -10s
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-osd-seek-fwd' ? 'focused' : ''}`}
              onClick={() => seekDelta(10000)}
            >
              ⏩ +10s
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-osd-sub-sync' ? 'focused' : ''}`}
              onClick={adjustSubtitleSync}
            >
              💬 Synchro Sous-titres ({subtitleOffsetMs()}ms)
            </button>
          </div>
        </div>
      </Show>
    </div>
  );
};
