import { Component, createSignal, createEffect, onMount, onCleanup, Show, For, untrack } from 'solid-js';
import { aspectModeLabel, AVPlayerService, FULL_SCREEN, TrackInfo, VideoAspectMode } from '../../core/player/AVPlayerService';
import { HttpClient } from '../../core/net/HttpClient';
import { EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import { isSameLiveChannel } from '../../core/engine/livePlayerHelpers';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { spatialNav } from '../../ui/design/SpatialNav';
import { announce } from '../../ui/design/a11y';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database } from '../../core/storage/Database';
import { InfoChips, InfoProgress } from '../../ui/components/InfoParts';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { detectChannelQuality } from '../../core/utils/categoryMeta';
import { formatClock, formatDuration, formatRuntime, percentOf } from '../../core/utils/timeFormat';
import { createPlayerInfo } from './playerInfo';
import { AssistantModal } from '../assistant/AssistantModal';
import { LocalSyncService } from '../../core/sync/LocalSyncService';
import { getUpNextPrefs, upNextChain } from '../../core/player/upNext';
import { getSubtitlePrefs, subtitleBoxStyle } from '../../core/player/subtitlePrefs';
import { isUhdTitle } from '../../core/player/uhd';

export interface PlayerViewProps {
  item: ItemRecord;
  onExit: () => void;
  onNextChannel?: () => void;
  onPrevChannel?: () => void;
  /** OK on a film of the « À suivre » shelf: play it next. */
  onPlayNext?: (item: ItemRecord) => void;
  canRecall?: boolean;
  onRecall?: () => void;
  onSelectChannelNumber?: (chno: number) => Promise<ItemRecord | null>;
  onSwitchStream?: (item: ItemRecord) => void;
  liveCategory?: string;
  isZapPending?: boolean;
}

export const PlayerView: Component<PlayerViewProps> = (props) => {
  const player = AVPlayerService.getInstance();
  const net = HttpClient.getInstance();

  const [isPlaying, setIsPlaying] = createSignal(true);
  const [currentTimeMs, setCurrentTimeMs] = createSignal(0);
  const [durationMs, setDurationMs] = createSignal(
    props.item.duration_ms > 0 ? props.item.duration_ms : player.getDuration()
  );
  const [liveSeekOffsetMs, setLiveSeekOffsetMs] = createSignal(0);
  const [showOsd, setShowOsd] = createSignal(true);
  const [isBuffering, setIsBuffering] = createSignal(true);
  const [bufferingPercent, setBufferingPercent] = createSignal(0);
  const [brokenTag, setBrokenTag] = createSignal(props.item.is_broken === 1);
  let brokenUnsubscribe: (() => void) | null = null;
  const [playerError, setPlayerError] = createSignal<string | null>(null);
  const [activeSubtitle, setActiveSubtitle] = createSignal<string>('');
  const [subtitleTimer, setSubtitleTimer] = createSignal<any>(null);
  const [audioTracks, setAudioTracks] = createSignal<TrackInfo[]>([]);
  const [activeAudioIndex, setActiveAudioIndex] = createSignal(0);
  const [subtitleTracks, setSubtitleTracks] = createSignal<TrackInfo[]>([]);
  const [activeSubIndex, setActiveSubIndex] = createSignal(-1);
  const [showChannelHud, setShowChannelHud] = createSignal(true);
  const [showAssistant, setShowAssistant] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();
  const [seekToast, setSeekToast] = createSignal('');
  const [channelDigits, setChannelDigits] = createSignal('');
  const [aspectMode, setAspectMode] = createSignal<VideoAspectMode>(player.getAspectMode());
  const [sleepMinutes, setSleepMinutes] = createSignal(0);
  const [sleepRemainingSecs, setSleepRemainingSecs] = createSignal(0);
  const [audioOnly, setAudioOnly] = createSignal(false);
  const [liveReturnChannel, setLiveReturnChannel] = createSignal<ItemRecord | null>(null);
  const [mirrors, setMirrors] = createSignal<ItemRecord[]>([]);
  const [showMirrors, setShowMirrors] = createSignal(false);
  const [showMiniGuide, setShowMiniGuide] = createSignal(false);
  const [miniGuideChannels, setMiniGuideChannels] = createSignal<ItemRecord[]>([]);
  const [miniGuideEpg, setMiniGuideEpg] = createSignal<Record<number, EpgProgramRecord | undefined>>({});
  let digitTimer: ReturnType<typeof setTimeout> | null = null;
  let sleepInterval: ReturnType<typeof setInterval> | null = null;
  let failoverCount = 0;
  const triedMirrorIds = new Set<number>();
  let lastLiveFamilyItem: ItemRecord | null = null;
  // « À suivre »: films similar to the one that plays, at the bottom of the controls.
  const [similar, setSimilar] = createSignal<ItemRecord[]>([]);
  let endShelfShown = false;
  // A film that pauses to load after it has played: say why (speed), once the viewer did not just seek.
  const [rebuffers, setRebuffers] = createSignal(0);
  let hasPlayedOnce = false;
  let userPaused = false;
  let lastSeekAt = 0;
  const isUhd = () => info.stream()?.quality === '4K' || isUhdTitle(props.item);
  const slowStreamMessage = () =>
    isUhd()
      ? { title: 'Débit trop faible pour ce film 4K', hint: 'Un câble Ethernet ou une version HD aident.' }
      : { title: 'Débit trop faible pour ce flux', hint: 'Le serveur ou le réseau est lent : un câble Ethernet aide.' };
  // Countdown before the first suggestion starts by itself (null: none running). `stillWatching`: the limit of films in a row.
  const [countdown, setCountdown] = createSignal<number | null>(null);
  const [stillWatching, setStillWatching] = createSignal(false);
  let countdownTimer: ReturnType<typeof setInterval> | null = null;

  const stopCountdown = () => {
    if (countdownTimer) clearInterval(countdownTimer);
    countdownTimer = null;
    setCountdown(null);
  };

  /** A film chosen by a key press (shelf) starts the chain over; one started by the countdown adds to it. */
  const playNext = (film: ItemRecord, automatic = false) => {
    stopCountdown();
    if (automatic) upNextChain.advance();
    else upNextChain.reset();
    props.onPlayNext?.(film);
  };

  const startCountdown = () => {
    const first = similar()[0];
    if (!first) return;
    stopCountdown();
    if (upNextChain.isStillWatchingDue()) {
      setStillWatching(true);
      announce('Toujours là ? Choisissez un film pour continuer.');
      return;
    }
    let left = getUpNextPrefs().seconds;
    setCountdown(left);
    announce(`Film suivant dans ${left} secondes : ${filmTitle(first)}. Retour pour annuler.`);
    countdownTimer = setInterval(() => {
      left -= 1;
      if (left <= 0) {
        playNext(first, true);
      } else {
        setCountdown(left);
      }
    }, 1000);
  };

  // Clock, decoded stream facts, TV program and favorite flag shown over the picture.
  const info = createPlayerInfo(() => props.item, {
    player,
    db: Database.getInstance(),
    engine: CndEngine.getInstance(),
  });

  const isLive = () => props.item.kind === 'live';
  const title = () => props.item.name_clean || cleanMediaTitle(props.item.name).clean;
  const qualityChip = () => {
    const q = info.stream()?.quality || detectChannelQuality(props.item.name);
    return q ? { text: q, tone: q === '4K' ? ('uhd' as const) : ('quality' as const) } : null;
  };
  /** The program on air now (the guide may start with a program that has not begun yet). */
  const epgNow = () => {
    const first = info.epg()[0];
    return first && first.start_ts <= info.nowTs() ? first : undefined;
  };
  const epgNext = () => info.epg().filter((p) => p.start_ts > info.nowTs()).slice(0, 2);
  const minutesLeft = (endTs: number) => Math.max(0, Math.ceil((endTs - info.nowTs()) / 60));
  const kindLabel = () => {
    if (isLive()) return '● EN DIRECT';
    if (props.item.kind === 'episode') {
      return `ÉPISODE${props.item.season_num ? ` S${props.item.season_num}` : ''}${props.item.episode_num ? `E${props.item.episode_num}` : ''}`;
    }
    return 'FILM';
  };
  /** When a film ends if it keeps playing, as a clock time. */
  const endsAt = () => (durationMs() > 0 ? formatClock(info.nowTs() + (durationMs() - currentTimeMs()) / 1000) : '');

  const MAX_RETRIES = 3;
  const [retryCount, setRetryCount] = createSignal(1);
  let retryTimer: any = null;
  let connectionTimeoutTimer: any = null;
  let osdTimer: any = null;
  let hudTimer: any = null;
  let keyUnsub: (() => void) | null = null;
  let hasResumed = false;
  let lastBroadcastMs = 0;

  // Live stream that stops answering mid-playback: reopen it again and again (1 s, 2 s, 4 s, 8 s, 15 s) while the
  // screen says what is happening; only then ask the viewer (retry / next channel). 0 = not reconnecting.
  const RECONNECT_DELAYS_MS = [1000, 2000, 4000, 8000, 15000];
  const [reconnectAttempt, setReconnectAttempt] = createSignal(0);
  let reconnectTimer: any = null;
  let reconnectWatch: any = null;

  const clearDigitTimer = () => {
    if (digitTimer) clearTimeout(digitTimer);
    digitTimer = null;
  };

  const stopSleepTimer = () => {
    if (sleepInterval) clearInterval(sleepInterval);
    sleepInterval = null;
    setSleepMinutes(0);
    setSleepRemainingSecs(0);
  };

  const clearTimers = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (reconnectWatch) {
      clearTimeout(reconnectWatch);
      reconnectWatch = null;
    }
    if (retryTimer) {
      clearTimeout(retryTimer);
      retryTimer = null;
    }
    if (connectionTimeoutTimer) {
      clearTimeout(connectionTimeoutTimer);
      connectionTimeoutTimer = null;
    }
  };

  const focusErrorAction = () => {
    spatialNav.setFocusById('btn-player-retry');
    setTimeout(() => {
      if (playerError()) {
        spatialNav.setFocusById('btn-player-retry');
      }
    }, 50);
  };

  const startConnectionWatchdog = (expectedItemId: number) => {
    if (props.item.kind !== 'live') return;
    if (connectionTimeoutTimer) clearTimeout(connectionTimeoutTimer);
    connectionTimeoutTimer = setTimeout(() => {
      if (props.item.id === expectedItemId && isBuffering() && !playerError()) {
        console.warn(`[PlayerView] Stream connection timeout (attempt ${retryCount()}/${MAX_RETRIES})`);
        handleStreamError('Délai d’attente du serveur IPTV dépassé');
      }
    }, 12000);
  };

  const giveUpReconnecting = () => {
    setReconnectAttempt(0);
    setIsBuffering(false);
    setPlayerError('Le serveur ne répond plus.');
    announce('Le serveur ne répond plus. Réessayez ou changez de chaîne.');
    updateGrid();
    focusErrorAction();
  };

  const scheduleReconnect = (expectedItemId: number) => {
    const attempt = reconnectAttempt() + 1;
    if (attempt > RECONNECT_DELAYS_MS.length) {
      giveUpReconnecting();
      return;
    }
    setReconnectAttempt(attempt);
    setIsBuffering(true);
    announce(`Connexion perdue… reconnexion ${attempt} sur ${RECONNECT_DELAYS_MS.length}`);
    reconnectTimer = setTimeout(async () => {
      reconnectTimer = null;
      if (props.item.id !== expectedItemId) return;
      try {
        // Through the engine: it closes the old connection first (one connection at the provider), keeps the
        // account's local settings and re-arms the stream health.
        await CndEngine.getInstance().play(props.item, { force: true });
      } catch {
        if (props.item.id === expectedItemId) scheduleReconnect(expectedItemId);
        return;
      }
      if (props.item.id !== expectedItemId) return;
      // Playing again is detected by `finishBuffering`; if nothing moves within 10 s, the next attempt.
      reconnectWatch = setTimeout(() => {
        reconnectWatch = null;
        if (props.item.id === expectedItemId && reconnectAttempt() > 0) scheduleReconnect(expectedItemId);
      }, 10000);
    }, RECONNECT_DELAYS_MS[attempt - 1]);
  };

  const startReconnect = () => {
    if (props.item.kind !== 'live' || playerError() || reconnectAttempt() > 0) return;
    scheduleReconnect(props.item.id);
  };

  const executeRetry = async (expectedItemId: number) => {
    if (props.item.id !== expectedItemId) return;
    clearTimers();
    setPlayerError(null);
    setIsBuffering(true);
    startConnectionWatchdog(expectedItemId);
    try {
      await player.open(props.item.stream_url, props.item.kind === 'live');
      if (props.item.id !== expectedItemId) return;
      player.play();
    } catch (err: any) {
      if (props.item.id !== expectedItemId) return;
      handleStreamError(err?.message || 'Échec de connexion');
    }
  };

  const handleStreamError = (errorMsg: string) => {
    clearTimers();
    if (props.item.kind === 'live' && failoverCount < 2) {
      const candidate = mirrors().find((m) => !triedMirrorIds.has(m.id));
      if (candidate && props.onSwitchStream) {
        failoverCount += 1;
        triedMirrorIds.add(candidate.id);
        setBrokenTag(true);
        props.item.is_broken = 1;
        void Database.getInstance().setBroken(props.item.id, true);
        const mirrorName = candidate.name_clean || candidate.name;
        showToast(`📡 Bascule auto : ${mirrorName}`);
        announce(`Flux indisponible, bascule vers ${mirrorName}`);
        props.onSwitchStream(candidate);
        return;
      }
    }
    if (props.item.kind === 'live' && retryCount() < MAX_RETRIES) {
      const nextAttempt = retryCount() + 1;
      setRetryCount(nextAttempt);
      setIsBuffering(true);
      announce(`Connexion… tentative ${nextAttempt} sur ${MAX_RETRIES}`);
      retryTimer = setTimeout(() => {
        void executeRetry(props.item.id);
      }, 1200);
      return;
    }

    setIsBuffering(false);
    setPlayerError(errorMsg);
    announce(`Erreur de lecture : ${errorMsg}`);

    setReconnectAttempt(0);
    // Mark channel as broken in DB & locally
    if (props.item.kind === 'live') {
      setBrokenTag(true);
      props.item.is_broken = 1;
      void Database.getInstance().setBroken(props.item.id, true);
    }

    updateGrid();
    focusErrorAction();
  };

  const startOverUrl = () => {
    if (!isLive()) return null;
    const prog = epgNow();
    if (!prog) return null;
    return CndEngine.getInstance().buildCatchupUrl(props.item, prog, info.nowTs());
  };

  const updateGrid = (preserveFocus = false) => {
    const isLiveItem = props.item.kind === 'live';
    if (playerError()) {
      const errorRow = [
        { id: 'btn-player-retry', onSelect: retryPlayback },
        ...(props.onNextChannel && isLiveItem
          ? [{ id: 'btn-player-next', onSelect: () => props.onNextChannel?.() }]
          : []),
        { id: 'btn-player-exit', onSelect: () => { player.stop(); props.onExit(); } },
      ];
      spatialNav.setGrid([errorRow], 0, 0, false);
      return;
    }

    if (showMiniGuide()) {
      const channelRows = miniGuideChannels().map((ch) => [
        {
          id: `miniguide-ch-${ch.id}`,
          onSelect: () => selectMiniGuideChannel(ch),
        },
      ]);
      const closeRow = [{ id: 'btn-miniguide-close', onSelect: () => closeMiniGuide() }];
      spatialNav.setGrid([...channelRows, closeRow], 0, 0, false);
      return;
    }

    if (showMirrors()) {
      const mirrorRow = [
        { id: `mirror-item-${props.item.id}`, onSelect: () => closeMirrors() },
        ...mirrors().map((m) => ({
          id: `mirror-item-${m.id}`,
          onSelect: () => selectMirror(m),
        })),
        { id: 'btn-mirrors-close', onSelect: () => closeMirrors() },
      ];
      spatialNav.setGrid([mirrorRow], 0, 0, false);
      return;
    }

    const progressRow = [
      {
        id: 'osd-progress-bar',
        onSelect: () => togglePlayPause(),
      },
    ];

    const actionRow = [
      {
        id: 'btn-osd-play-pause',
        onSelect: () => togglePlayPause(),
      },
      { id: 'btn-osd-seek-back', onSelect: () => seekDelta(-10000) },
      { id: 'btn-osd-seek-fwd', onSelect: () => seekDelta(10000) },
      ...(!isLiveItem ? [{ id: 'btn-osd-skip-intro', onSelect: () => { seekDelta(85000); showToast('Intro passée (+85 s)'); } }] : []),
      ...(isLiveItem
        ? [
            ...(props.onPrevChannel ? [{ id: 'btn-osd-prev-ch', onSelect: () => props.onPrevChannel?.() }] : []),
            ...(props.onNextChannel ? [{ id: 'btn-osd-next-ch', onSelect: () => props.onNextChannel?.() }] : []),
            ...(props.canRecall && props.onRecall ? [{ id: 'btn-osd-recall', onSelect: () => triggerRecall() }] : []),
            ...(startOverUrl() ? [{ id: 'btn-osd-startover', onSelect: () => startOverProgram() }] : []),
            { id: 'btn-osd-miniguide', onSelect: () => toggleMiniGuide() },
            ...(mirrors().length > 0 ? [{ id: 'btn-osd-mirrors', onSelect: () => toggleMirrors() }] : []),
          ]
        : []),
      ...(liveReturnChannel()
        ? [{ id: 'btn-osd-return-live', onSelect: () => returnToLive() }]
        : []),
      ...(!liveReturnChannel()
        ? [{ id: 'btn-osd-fav', onSelect: () => void toggleFavorite() }]
        : []),
      { id: 'btn-osd-aspect', onSelect: () => toggleAspectMode() },
      { id: 'btn-osd-sleep', onSelect: () => cycleSleepTimer() },
      { id: 'btn-osd-audio-only', onSelect: () => toggleAudioOnly() },
      {
        id: 'btn-osd-audio-track',
        onSelect: () => cycleAudioTrack(),
      },
      {
        id: 'btn-osd-sub-track',
        onSelect: () => cycleSubtitleTrack(),
      },
      {
        id: 'btn-osd-assistant',
        onSelect: () => setShowAssistant(true),
      },
    ];

    const shelfRow = !isLiveItem
      ? similar().map((film) => ({ id: `player-next-${film.id}`, onSelect: () => playNext(film) }))
      : [];
    spatialNav.setGrid(
      shelfRow.length > 0 ? [progressRow, actionRow, shelfRow] : [progressRow, actionRow],
      1,
      0,
      preserveFocus
    );
  };

  const filmTitle = (film: ItemRecord) =>
    film.name_clean && film.name_clean !== film.name ? film.name_clean : cleanMediaTitle(film.name).clean;

  // Films that resemble the one playing: looked up when a film starts (local catalogue, one short API call).
  createEffect(() => {
    const current = props.item;
    setSimilar([]);
    endShelfShown = false;
    stopCountdown();
    setStillWatching(false);
    if (current.kind !== 'movie') return;
    const id = current.id;
    void CndEngine.getInstance()
      .getSimilarMovies(current)
      .then((list) => {
        if (props.item.id !== id) return;
        setSimilar(list);
        updateGrid();
      })
      .catch(() => {});
  });

  // Some Samsung firmwares omit buffering-complete, especially when the view attaches after
  // playback starts. Advancing play time is also proof that the stream has recovered.
  const finishBuffering = () => {
    const hadError = !!playerError();
    clearTimers();
    setReconnectAttempt(0);
    hasPlayedOnce = true;
    setIsBuffering(false);
    if (!userPaused && player.getState() !== 'PAUSED') {
      setIsPlaying(true);
    }
    setPlayerError(null);
    setRetryCount(1);
    setBrokenTag(false);
    if (props.item.kind === 'live' && props.item.is_broken) {
      props.item.is_broken = 0;
      void Database.getInstance().setBroken(props.item.id, false);
    }
    if (!hasResumed && props.item.kind !== 'live') {
      hasResumed = true;
      // The engine already moved the stream to the saved position when it started it: do not seek twice.
      if (!CndEngine.getInstance().takeResumed(props.item.id) && props.item.playback_position_ms > 0) {
        player.seekTo(props.item.playback_position_ms);
      }
    }
    if (hadError) updateGrid();
  };

  const loadLiveMirrors = (liveItem: ItemRecord) => {
    if (liveItem.kind !== 'live') {
      setMirrors([]);
      return;
    }
    const targetId = liveItem.id;
    void CndEngine.getInstance()
      .findMirrors(liveItem)
      .then((list) => {
        if (props.item.id === targetId) {
          setMirrors(list);
          updateGrid(true);
        }
      })
      .catch(() => {});
  };

  let previousItemId: number | null = null;
  createEffect(() => {
    const currentItem = props.item;
    const currentId = currentItem.id;
    if (previousItemId === null) {
      previousItemId = currentId;
      if (currentItem.kind === 'live') {
        lastLiveFamilyItem = currentItem;
        triedMirrorIds.add(currentId);
        loadLiveMirrors(currentItem);
      }
      return;
    }
    if (previousItemId === currentId) return;
    previousItemId = currentId;
    setBrokenTag(currentItem.is_broken === 1);
    if (currentId > 0) setLiveReturnChannel(null);

    if (currentItem.kind === 'live') {
      if (!lastLiveFamilyItem || !isSameLiveChannel(lastLiveFamilyItem, currentItem)) {
        failoverCount = 0;
        triedMirrorIds.clear();
      }
      lastLiveFamilyItem = currentItem;
      triedMirrorIds.add(currentId);
      loadLiveMirrors(currentItem);
    } else {
      setMirrors([]);
      setShowMirrors(false);
      setShowMiniGuide(false);
    }

    clearTimers();
    setReconnectAttempt(0);
    setRebuffers(0);
    hasPlayedOnce = false;
    userPaused = false;
    setRetryCount(1);
    setPlayerError(null);
    setIsBuffering(true);
    setBufferingPercent(0);
    setCurrentTimeMs(0);
    setDurationMs(currentItem.duration_ms > 0 ? currentItem.duration_ms : 0);
    setLiveSeekOffsetMs(0);
    hasResumed = false;
    updateGrid();
    triggerChannelHud();
    startConnectionWatchdog(currentId);
  });

  createEffect(() => {
    void isLive();
    void Boolean(startOverUrl());
    void (mirrors().length > 0);
    void Boolean(props.canRecall);
    void Boolean(liveReturnChannel());
    untrack(() => {
      if (!showMiniGuide() && !showMirrors() && !playerError()) {
        updateGrid(true);
      }
    });
  });

  onMount(() => {
    brokenUnsubscribe = Database.getInstance().onBrokenChange((id, broken) => {
      if (props.item.id !== id) return;
      props.item.is_broken = broken ? 1 : 0;
      setBrokenTag(broken);
    });
    // 1. Ensure AVPlay hardware video surface is sized to full screen
    player.setDisplayArea(FULL_SCREEN);

    // 2. Announce channel / title to Voice Guide screen reader
    const title = props.item.name_clean || props.item.name;
    announce(`Lecture de ${title}. Appuyez sur Bas pour afficher les contrôles de lecture.`);

    // 3. Set up player listeners
    player.setListener({
      onBufferingStart: () => {
        if (userPaused || player.getState() === 'PAUSED') return;
        setIsBuffering(true);
        setPlayerError(null);
        if (props.item.kind !== 'live' && hasPlayedOnce && Date.now() - lastSeekAt > 8000) setRebuffers((n) => n + 1);
      },
      onBufferingProgress: (pct) => {
        if (userPaused || player.getState() === 'PAUSED') return;
        setBufferingPercent(pct);
      },
      onBufferingComplete: finishBuffering,
      onCurrentPlayTime: (ms) => {
        if (userPaused || player.getState() === 'PAUSED') return;
        const advancing = ms > currentTimeMs();
        if (advancing && (isBuffering() || playerError() || retryTimer || connectionTimeoutTimer)) {
          finishBuffering();
        }
        setCurrentTimeMs(ms);
        const avDuration = player.getDuration();
        if (avDuration > 0 || props.item.duration_ms <= 0) {
          setDurationMs(avDuration > 0 ? avDuration : props.item.duration_ms > 0 ? props.item.duration_ms : 0);
        }
        // The film is ending: bring up what to watch next and keep it on screen.
        const total = player.getDuration();
        if (!endShelfShown && props.item.kind === 'movie' && total > 0 && ms / total >= 0.97 && similar().length > 0) {
          endShelfShown = true;
          if (osdTimer) clearTimeout(osdTimer);
          setShowOsd(true);
          updateGrid();
          setTimeout(() => spatialNav.setFocusById(`player-next-${similar()[0].id}`), 0);
        }
        if (props.item.kind !== 'live' && Math.abs(ms - lastBroadcastMs) >= 15000) {
          lastBroadcastMs = ms;
          void LocalSyncService.getInstance().broadcastProgress(
            props.item.stable_hash,
            ms,
            player.getDuration(),
            false
          );
        }
      },
      onError: (err) => {
        console.error('Player error:', err);
        handleStreamError(err);
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
        if (props.item.kind === 'live') {
          startReconnect();
          return;
        }
        player.pause();
        player.play();
      },
      onStreamCompleted: () => {
        // A film with suggestions does not close the player: the shelf and the countdown take over.
        if (props.item.kind === 'movie' && similar().length > 0) {
          void LocalSyncService.getInstance().broadcastProgress(props.item.stable_hash, durationMs(), durationMs(), true);
          announce('Lecture terminée');
          setShowOsd(true);
          if (osdTimer) clearTimeout(osdTimer);
          updateGrid();
          setTimeout(() => spatialNav.setFocusById(`player-next-${similar()[0].id}`), 0);
          if (getUpNextPrefs().auto) startCountdown();
          return;
        }
        if (props.item.kind !== 'live') {
          void LocalSyncService.getInstance().broadcastProgress(
            props.item.stable_hash,
            durationMs(),
            durationMs(),
            true
          );
          announce('Lecture terminée');
          props.onExit();
        }
      },
      onStateChange: (state) => {
        if (state === 'PAUSED') {
          userPaused = true;
          setIsPlaying(false);
          setIsBuffering(false);
        } else if (state === 'PLAYING') {
          userPaused = false;
          setIsPlaying(true);
          setIsBuffering(false);
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
    startConnectionWatchdog(props.item.id);
  });

  onCleanup(() => {
    stopCountdown();
    upNextChain.reset(); // leaving the player: the next evening starts a new chain
    brokenUnsubscribe?.();
    clearTimers();
    if (props.item.kind !== 'live' && currentTimeMs() > 0) {
      void LocalSyncService.getInstance().broadcastProgress(
        props.item.stable_hash,
        currentTimeMs(),
        durationMs(),
        false
      );
    }
    // Where the film stopped, before the stream is closed below.
    void CndEngine.getInstance().saveProgress();
    if (keyUnsub) keyUnsub();
    if (osdTimer) clearTimeout(osdTimer);
    if (hudTimer) clearTimeout(hudTimer);
    if (toastTimer) clearTimeout(toastTimer);
    if (subtitleTimer()) clearTimeout(subtitleTimer());
    clearDigitTimer();
    stopSleepTimer();
    player.stop();
  });

  const resetOsdTimer = () => {
    setShowOsd(true);
    if (osdTimer) clearTimeout(osdTimer);
    osdTimer = null;
    if (isPlaying()) {
      osdTimer = setTimeout(() => {
        setShowOsd(false);
      }, 5000);
    }
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
      userPaused = true;
      clearTimers();
      setIsBuffering(false);
      player.pause();
      setIsPlaying(false);
      announce('Pause');
      if (props.item.kind !== 'live') {
        void LocalSyncService.getInstance().broadcastProgress(
          props.item.stable_hash,
          currentTimeMs(),
          durationMs(),
          false
        );
      }
    } else {
      userPaused = false;
      player.play();
      setIsPlaying(true);
      announce('Lecture');
    }
    resetOsdTimer();
  };

  let toastTimer: any = null;
  const showToast = (text: string) => {
    setSeekToast(text);
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => setSeekToast(''), 1300);
  };

  const toggleFavorite = async () => {
    const next = await info.toggleFavorite();
    announce(next ? 'Ajouté aux favoris' : 'Retiré des favoris');
    showToast(next ? '★ Ajouté aux favoris' : '☆ Retiré des favoris');
    resetOsdTimer();
  };

  const effectiveDurationMs = (): number => {
    if (isLive()) {
      const prog = epgNow();
      if (prog && prog.end_ts > prog.start_ts) {
        return Math.max(60_000, (prog.end_ts - prog.start_ts) * 1000);
      }
    }
    if (durationMs() > 0) return durationMs();
    if (props.item.duration_ms > 0) return props.item.duration_ms;
    return Math.max(currentTimeMs() + 60_000, 3_600_000);
  };

  const liveNaturalMs = (): number => {
    const prog = epgNow();
    if (!prog || prog.end_ts <= prog.start_ts) return 0;
    const progDuration = Math.max(60_000, (prog.end_ts - prog.start_ts) * 1000);
    return Math.max(0, Math.min(progDuration, (info.nowTs() - prog.start_ts) * 1000));
  };

  const effectivePositionMs = (): number => {
    const total = effectiveDurationMs();
    if (isLive() && epgNow()) {
      return Math.max(0, Math.min(total, liveNaturalMs() + liveSeekOffsetMs()));
    }
    return Math.max(0, Math.min(total, currentTimeMs()));
  };

  const seekToPositionMs = (targetMs: number, toastMessage?: string, spokenMessage?: string) => {
    const total = effectiveDurationMs();
    const clamped = Math.max(0, Math.min(total, Math.round(targetMs)));
    if (isLive() && epgNow()) {
      setLiveSeekOffsetMs(clamped - liveNaturalMs());
    }
    setCurrentTimeMs(clamped);
    lastSeekAt = Date.now();
    player.seekTo(clamped);
    const toast = toastMessage || `⏩ ${formatTime(clamped)}`;
    showToast(toast);
    announce(spokenMessage || `Position : ${formatTime(clamped)}`);
    resetOsdTimer();
  };

  const seekDelta = (deltaMs: number) => {
    const target = effectivePositionMs() + deltaMs;
    const secs = Math.abs(Math.round(deltaMs / 1000));
    seekToPositionMs(
      target,
      deltaMs > 0 ? `⏩ +${secs} s` : `⏪ −${secs} s`,
      deltaMs > 0 ? `Avance rapide de ${secs} secondes` : `Retour arrière de ${secs} secondes`
    );
  };

  const seekToRatio = (ratio: number) => {
    const clampedRatio = Math.max(0, Math.min(1, ratio));
    const target = Math.round(effectiveDurationMs() * clampedRatio);
    seekToPositionMs(target);
  };

  const handleProgressPointer = (el: HTMLElement, clientX: number) => {
    const rect = el.getBoundingClientRect();
    const width = rect.width > 0 ? rect.width : 1920;
    const left = rect.width > 0 ? rect.left : 0;
    const ratio = Math.max(0, Math.min(1, (clientX - left) / width));
    seekToRatio(ratio);
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
    clearTimers();
    userPaused = false;
    setReconnectAttempt(0);
    setRetryCount(1);
    setPlayerError(null);
    setIsBuffering(true);
    announce('Nouvelle tentative de connexion…');
    updateGrid();
    startConnectionWatchdog(props.item.id);
    try {
      await player.open(props.item.stream_url, props.item.kind === 'live');
      player.play();
    } catch (err: any) {
      handleStreamError(err?.message || 'Échec de connexion');
    }
  };

  const toggleAudioOnly = () => {
    const next = !audioOnly();
    setAudioOnly(next);
    if (next) {
      setShowOsd(false);
      announce("Mode audio uniquement activé. Appuyez sur OK ou Retour pour rallumer l'écran.");
    } else {
      showToast('Écran rallumé');
      resetOsdTimer();
    }
  };

  const formatSleepRemaining = () => {
    const total = sleepRemainingSecs();
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
  };

  const commitChannelDigits = async () => {
    clearDigitTimer();
    const raw = channelDigits();
    setChannelDigits('');
    const num = Number.parseInt(raw, 10);
    if (!Number.isFinite(num) || num <= 0 || !props.onSelectChannelNumber) return;
    const hit = await props.onSelectChannelNumber(num);
    if (!hit) {
      showToast(`Chaîne ${num} introuvable`);
      announce(`Chaîne ${num} introuvable`);
    } else {
      triggerChannelHud();
    }
  };

  const pushChannelDigit = (digit: string) => {
    clearDigitTimer();
    const next = (channelDigits() + digit).slice(0, 4);
    setChannelDigits(next);
    digitTimer = setTimeout(() => {
      void commitChannelDigits();
    }, 1200);
  };

  const triggerRecall = () => {
    setShowMirrors(false);
    setShowMiniGuide(false);
    props.onRecall?.();
    triggerChannelHud();
    resetOsdTimer();
  };

  const startOverProgram = () => {
    const prog = epgNow();
    const url = startOverUrl();
    if (!prog || !url || !props.onSwitchStream) return;
    setLiveReturnChannel(props.item);
    setShowMirrors(false);
    setShowMiniGuide(false);
    const duration = Math.max(0, (prog.end_ts - prog.start_ts) * 1000);
    const replayItem: ItemRecord = {
      ...props.item,
      id: -Math.abs(props.item.id || 1),
      kind: 'movie',
      name_clean: `${title()} · Replay`,
      stream_url: url,
      playback_position_ms: 0,
      duration_ms: duration,
      plot: prog.description || prog.title,
    };
    announce(`Revoir depuis le début : ${prog.title}`);
    props.onSwitchStream(replayItem);
  };

  const returnToLive = () => {
    const target = liveReturnChannel();
    if (!target || !props.onSwitchStream) return;
    setLiveReturnChannel(null);
    announce(`Retour au direct : ${target.name_clean || target.name}`);
    props.onSwitchStream(target);
  };

  const closeMiniGuide = () => {
    setShowMiniGuide(false);
    resetOsdTimer();
    updateGrid();
  };

  const toggleMiniGuide = () => {
    if (showMiniGuide()) {
      closeMiniGuide();
      return;
    }
    setShowMirrors(false);
    if (osdTimer) clearTimeout(osdTimer);
    setShowOsd(false);
    setShowMiniGuide(true);
    const cat = props.liveCategory || props.item.group_title || '';
    void (async () => {
      const list = await CndEngine.getInstance().getCatalog('live', cat || undefined, 0, 80);
      const channels = list.filter((ch) => ch.kind === 'live');
      setMiniGuideChannels(channels);
      const epgEntries = await Promise.all(
        channels.slice(0, 30).map(async (ch) => {
          if (!ch.tvg_id) return [ch.id, undefined] as const;
          const { now } = await Database.getInstance()
            .getEpgNowNext(ch.tvg_id, info.nowTs())
            .catch(() => ({ now: undefined }));
          return [ch.id, now] as const;
        })
      );
      const map: Record<number, EpgProgramRecord | undefined> = {};
      for (const [id, prog] of epgEntries) map[id] = prog;
      setMiniGuideEpg(map);
      updateGrid();
      if (channels.length > 0) {
        const active = channels.find((c) => c.id === props.item.id) ?? channels[0];
        setTimeout(() => spatialNav.setFocusById(`miniguide-ch-${active.id}`), 0);
      }
    })();
  };

  const selectMiniGuideChannel = (ch: ItemRecord) => {
    setShowMiniGuide(false);
    props.onSwitchStream?.(ch);
    triggerChannelHud();
    resetOsdTimer();
  };

  const closeMirrors = () => {
    setShowMirrors(false);
    resetOsdTimer();
    updateGrid();
  };

  const toggleMirrors = () => {
    if (showMirrors()) {
      closeMirrors();
      return;
    }
    setShowMiniGuide(false);
    if (osdTimer) clearTimeout(osdTimer);
    setShowOsd(false);
    setShowMirrors(true);
    updateGrid();
    setTimeout(() => spatialNav.setFocusById(`mirror-item-${props.item.id}`), 0);
  };

  const selectMirror = (mirror: ItemRecord) => {
    failoverCount = 0;
    triedMirrorIds.clear();
    triedMirrorIds.add(mirror.id);
    setShowMirrors(false);
    props.onSwitchStream?.(mirror);
    triggerChannelHud();
    resetOsdTimer();
  };

  const toggleAspectMode = () => {
    const next = player.cycleAspectMode();
    setAspectMode(next);
    const label = aspectModeLabel(next);
    showToast(`📐 Format : ${label}`);
    announce(`Format vidéo : ${label}`);
    resetOsdTimer();
  };

  const SLEEP_PRESETS = [0, 15, 30, 60, 90];
  const cycleSleepTimer = () => {
    const idx = SLEEP_PRESETS.indexOf(sleepMinutes());
    const nextMin = SLEEP_PRESETS[(idx + 1) % SLEEP_PRESETS.length];
    if (sleepInterval) clearInterval(sleepInterval);
    sleepInterval = null;
    setSleepMinutes(nextMin);
    if (nextMin === 0) {
      setSleepRemainingSecs(0);
      showToast('🌙 Minuteur de veille désactivé');
      announce('Minuteur de veille désactivé');
    } else {
      setSleepRemainingSecs(nextMin * 60);
      showToast(`🌙 Arrêt programmé dans ${nextMin} min`);
      announce(`Arrêt programmé dans ${nextMin} minutes`);
      sleepInterval = setInterval(() => {
        const nextSecs = sleepRemainingSecs() - 1;
        if (nextSecs <= 0) {
          stopSleepTimer();
          announce('Minuteur de veille écoulé : arrêt de la lecture');
          player.stop();
          props.onExit();
        } else {
          setSleepRemainingSecs(nextSecs);
        }
      }, 1000);
    }
    resetOsdTimer();
  };

  const handleKey = (key: RemoteKey): boolean => {
    if (audioOnly() && (key === 'BACK' || key === 'ENTER' || key === 'UP' || key === 'DOWN' || key === 'LEFT' || key === 'RIGHT')) {
      setAudioOnly(false);
      showToast('Écran rallumé');
      resetOsdTimer();
      return true;
    }
    if (showMiniGuide() && key === 'BACK') {
      closeMiniGuide();
      return true;
    }
    if (showMirrors() && key === 'BACK') {
      closeMirrors();
      return true;
    }
    if ((isLive() || liveReturnChannel()) && key.startsWith('NUM_') && !playerError()) {
      pushChannelDigit(key.slice(4));
      return true;
    }
    if (channelDigits() && key === 'ENTER') {
      void commitChannelDigits();
      return true;
    }
    // BACK during the countdown only cancels it; the next BACK leaves the player as usual.
    if (key === 'BACK' && countdown() !== null) {
      stopCountdown();
      announce('Lecture automatique annulée');
      return true;
    }
    if (key === 'BACK') {
      // BACK always leaves the player and returns to the screen that opened it (no OSD detour).
      player.stop();
      props.onExit();
      return true;
    }

    if (key === 'PAUSE') {
      if (!playerError()) {
        if (isPlaying()) togglePlayPause();
        else resetOsdTimer();
        return true;
      }
    }

    if (key === 'PLAY') {
      if (!playerError()) {
        if (!isPlaying()) togglePlayPause();
        else resetOsdTimer();
        return true;
      }
    }

    if (key === 'PLAY_PAUSE') {
      if (!playerError()) {
        togglePlayPause();
        return true;
      }
    }

    if (key === 'FAST_FORWARD') {
      if (!playerError()) {
        seekDelta(30000);
        return true;
      }
    }

    if (key === 'REWIND') {
      if (!playerError()) {
        seekDelta(-30000);
        return true;
      }
    }

    if (key === 'CHANNEL_UP' || (key === 'UP' && (!showOsd() || playerError()) && !showMiniGuide() && !showMirrors() && props.item.kind === 'live')) {
      if (props.onNextChannel) {
        props.onNextChannel();
        triggerChannelHud();
        return true;
      }
    }

    if (key === 'CHANNEL_DOWN' || (key === 'DOWN' && (!showOsd() || playerError()) && !showMiniGuide() && !showMirrors() && props.item.kind === 'live')) {
      if (props.onPrevChannel) {
        props.onPrevChannel();
        triggerChannelHud();
        return true;
      }
    }

    if (playerError()) {
      return false;
    }

    if (showMiniGuide() || showMirrors()) {
      return false;
    }

    if (showOsd() && focusId() === 'osd-progress-bar') {
      if (key === 'LEFT') {
        seekDelta(-10000);
        return true;
      }
      if (key === 'RIGHT') {
        seekDelta(10000);
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
    const total = effectiveDurationMs();
    if (total <= 0) return 0;
    return Math.min(100, Math.max(0, (effectivePositionMs() / total) * 100));
  };

  const InteractiveProgressBar = (label: string) => (
    <div
      id="osd-progress-bar"
      role="slider"
      tabindex="-1"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={Math.round(effectiveDurationMs() / 1000)}
      aria-valuenow={Math.round(effectivePositionMs() / 1000)}
      class={`tv-osd-progress-bg ${focusId() === 'osd-progress-bar' ? 'focused' : ''}`}
      onClick={(e) => handleProgressPointer(e.currentTarget, e.clientX)}
      onMouseMove={(e) => {
        if (e.buttons === 1) handleProgressPointer(e.currentTarget, e.clientX);
      }}
    >
      <div class="tv-osd-progress-fill" style={{ width: `${progressPct()}%` }} />
      <div class="tv-osd-progress-thumb" style={{ left: `${progressPct()}%` }} />
    </div>
  );

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
      {/* 1. Channel banner: briefly on entry / channel change, with what is on air */}
      <Show when={showChannelHud() && isLive()}>
        <div class="tv-channel-hud" role="status" aria-live="polite">
          <div class="tv-hud-badge">{props.item.chno ? `CH ${props.item.chno}` : 'LIVE'}</div>
          <div class="tv-hud-main">
            <div class="tv-hud-name">{title()}</div>
            <div class="tv-hud-sub">{props.item.group_title || 'Direct TV'}</div>
            <Show when={epgNow()}>
              <div class="tv-hud-now">
                <span class="when">{formatClock(epgNow()!.start_ts)}</span> {epgNow()!.title}
              </div>
              <InfoProgress percent={percentOf(info.nowTs() - epgNow()!.start_ts, epgNow()!.end_ts - epgNow()!.start_ts)} />
            </Show>
          </div>
        </div>
      </Show>

      {/* 1b. Direct 0-9 channel entry badge */}
      <Show when={channelDigits()}>
        <div class="tv-digit-hud" role="status" aria-live="polite">
          CH {channelDigits()}
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
          <div>
          <div style={{ "font-size": "24px", "font-weight": "700" }}>
            {props.isZapPending
              ? `Zapping vers ${title()}…`
              : isLive()
                ? reconnectAttempt() > 0
                  ? `Connexion perdue… reconnexion (${reconnectAttempt()}/${RECONNECT_DELAYS_MS.length})`
                  : `Connexion… (tentative ${retryCount()}/${MAX_RETRIES})`
                : rebuffers() > 0
                  ? slowStreamMessage().title
                  : `Chargement... ${bufferingPercent() > 0 ? `${bufferingPercent()}%` : ''}`}
          </div>
          <Show when={!isLive() && rebuffers() > 0}>
            <div style={{ "font-size": "16px", color: "var(--buntu-text-muted)" }}>{slowStreamMessage().hint}</div>
          </Show>
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
          <Show when={isLive() && brokenTag()}>
            <p style={{ "font-size": "16px", color: "var(--buntu-text-muted)", margin: "4px 0 0 0" }}>
              Cette chaîne a été marquée temporairement hors service (HS).
            </p>
          </Show>
          <Show when={isLive() && !brokenTag()}>
            <p style={{ "font-size": "16px", color: "var(--buntu-text-muted)", margin: "4px 0 0 0" }}>
              Le serveur a coupé la diffusion. « Réessayer » rouvre la chaîne, « Chaîne suivante » en change.
            </p>
          </Show>
          <div style={{ display: "flex", gap: "20px", "margin-top": "12px" }}>
            <button
              id="btn-player-retry"
              class={`tv-btn ${focusId() === 'btn-player-retry' ? 'focused' : ''}`}
              onClick={retryPlayback}
            >
              🔄 Réessayer
            </button>
            <Show when={props.onNextChannel && isLive()}>
              <button
                id="btn-player-next"
                class={`tv-btn ${focusId() === 'btn-player-next' ? 'focused' : ''}`}
                onClick={() => props.onNextChannel?.()}
              >
                ⏭ Chaîne suivante
              </button>
            </Show>
            <button
              id="btn-player-exit"
              class={`tv-btn ${focusId() === 'btn-player-exit' ? 'focused' : ''}`}
              onClick={() => { player.stop(); props.onExit(); }}
            >
              ← Retour aux chaînes
            </button>
          </div>
        </div>
      </Show>

      {/* 5. Audio-only black screen curtain */}
      <Show when={audioOnly() && !playerError()}>
        <div
          id="audio-only-curtain"
          class="tv-audio-only-curtain"
          onClick={() => toggleAudioOnly()}
        >
          <div style={{ "font-size": "24px", "font-weight": "700", color: "var(--buntu-text-muted)", "margin-bottom": "8px" }}>
            🎵 Audio uniquement — {title()}
          </div>
          <div style={{ "font-size": "16px", color: "var(--buntu-text-muted)" }}>
            Appuyez sur OK ou Retour pour rallumer l’écran
          </div>
        </div>
      </Show>

      {/* 6. Subtitle text rendering */}
      <Show when={activeSubtitle() && !showOsd()}>
        <div class="tv-subtitle-box" style={subtitleBoxStyle(getSubtitlePrefs())} aria-live="off">
          {activeSubtitle()}
        </div>
      </Show>

      {/* 6. Short confirmation (seek, favorite) */}
      <Show when={seekToast()}>
        <div class="tv-seek-toast" role="status">
          {seekToast()}
        </div>
      </Show>

      {/* 7. Top bar: sleep pill, what the TV decodes and the clock */}
      <Show when={showOsd() && !showMiniGuide() && !showMirrors() && !playerError()}>
        <div class="tv-osd-top">
          <Show when={sleepRemainingSecs() > 0}>
            <div class="tv-sleep-pill" role="status">🌙 {formatSleepRemaining()}</div>
          </Show>
          <Show when={info.stream()}>
            <div class="tv-osd-tech">
              <Show when={info.stream()!.height > 0}>
                <span>
                  {info.stream()!.width}×{info.stream()!.height}
                </span>
              </Show>
              <Show when={info.stream()!.videoCodec}>
                <span>{info.stream()!.videoCodec}</span>
              </Show>
              <Show when={info.stream()!.audioCodec}>
                <span>
                  {info.stream()!.audioCodec}
                  {info.stream()!.audioChannels ? ` ${info.stream()!.audioChannels}` : ''}
                </span>
              </Show>
            </div>
          </Show>
          <div class="tv-osd-clock">{info.clock()}</div>
        </div>
      </Show>

      {/* 8. Controls and information */}
      <Show when={showOsd() && !showMiniGuide() && !showMirrors() && !playerError()}>
        <div class="tv-osd">
          <div class="tv-osd-head">
            <div class="tv-osd-heading">
              <div class="tv-osd-kicker">
                {kindLabel()}
                <Show when={isLive() && props.item.chno}>
                  <span class="tv-osd-chno"> · CH {props.item.chno}</span>
                </Show>
              </div>
              <h1 class="tv-osd-title">{title()}</h1>
            </div>
            <Show when={!isLive()}>
              <div class="tv-osd-clockline">
                {formatDuration(effectivePositionMs())} / {formatDuration(durationMs())}
              </div>
            </Show>
          </div>

          <InfoChips
            chips={
              isLive()
                ? [
                    brokenTag() ? { text: '⚠ HORS SERVICE', tone: 'quality' as const } : null,
                    qualityChip(),
                    props.item.country ? { text: props.item.country.toUpperCase() } : null,
                    props.item.language ? { text: props.item.language.toUpperCase() } : null,
                    (props.item.catchup_days || 0) > 0 ? { text: `↺ Replay ${props.item.catchup_days} j` } : null,
                    props.item.group_title ? { text: props.item.group_title } : null,
                  ]
                : [
                    qualityChip(),
                    props.item.imdb_rating && props.item.imdb_rating > 0
                      ? { text: `★ ${props.item.imdb_rating.toFixed(1)}`, tone: 'rating' }
                      : null,
                    props.item.year ? { text: String(props.item.year) } : null,
                    durationMs() > 0 ? { text: formatRuntime(durationMs()) } : null,
                    props.item.language ? { text: props.item.language.toUpperCase() } : null,
                    props.item.container_ext ? { text: props.item.container_ext.toUpperCase() } : null,
                    props.item.group_title ? { text: props.item.group_title } : null,
                  ]
            }
          />

          {/* Live: the program on air and the next ones */}
          <Show when={isLive()}>
            <Show
              when={epgNow()}
              fallback={
                <>
                  <div class="tv-osd-note">Pas de guide pour cette chaîne.</div>
                  {InteractiveProgressBar('Barre de progression du direct')}
                </>
              }
            >
              <div class="tv-osd-program">
                <div class="tv-osd-label">
                  EN CE MOMENT · {formatClock(epgNow()!.start_ts)} – {formatClock(epgNow()!.end_ts)} · il reste{' '}
                  {minutesLeft(epgNow()!.end_ts) >= 60
                    ? formatRuntime(minutesLeft(epgNow()!.end_ts) * 60000)
                    : `${minutesLeft(epgNow()!.end_ts)} min`}
                </div>
                <div class="tv-osd-program-title">{epgNow()!.title}</div>
                {InteractiveProgressBar('Barre de progression du direct')}
                <Show when={epgNow()!.description}>
                  <p class="tv-osd-desc">{epgNow()!.description}</p>
                </Show>
              </div>
            </Show>
            <Show when={epgNext().length > 0}>
              <div class="tv-osd-next">
                <span class="tv-osd-label">À SUIVRE</span>
                <For each={epgNext()}>
                  {(program) => (
                    <span class="tv-osd-next-item">
                      <span class="when">{formatClock(program.start_ts)}</span> {program.title}
                    </span>
                  )}
                </For>
              </div>
            </Show>
          </Show>

          {/* Film / episode: progress, end time and synopsis */}
          <Show when={!isLive()}>
            {InteractiveProgressBar('Barre de progression de la lecture')}
            <Show when={durationMs() > 0}>
              <div class="tv-osd-note">
                Il reste {formatRuntime(Math.max(0, durationMs() - effectivePositionMs()))} · se termine à {endsAt()}
              </div>
            </Show>
            <Show when={props.item.plot}>
              <p class="tv-osd-desc">{props.item.plot}</p>
            </Show>
          </Show>

          {/* Action buttons */}
          <div class="tv-osd-actions">
            <button
              id="btn-osd-play-pause"
              class={`tv-btn ${focusId() === 'btn-osd-play-pause' ? 'focused' : ''}`}
              onClick={togglePlayPause}
              aria-label={isPlaying() ? 'Mettre en pause' : 'Reprendre la lecture'}
            >
              {isPlaying() ? '⏸ Pause' : '▶ Lecture'}
            </button>

            <button
              id="btn-osd-seek-back"
              class={`tv-btn ${focusId() === 'btn-osd-seek-back' ? 'focused' : ''}`}
              onClick={() => seekDelta(-10000)}
              aria-label="Reculer de 10 secondes"
            >
              ⏪ −10 s
            </button>
            <button
              id="btn-osd-seek-fwd"
              class={`tv-btn ${focusId() === 'btn-osd-seek-fwd' ? 'focused' : ''}`}
              onClick={() => seekDelta(10000)}
              aria-label="Avancer de 10 secondes"
            >
              ⏩ +10 s
            </button>

            <Show when={!isLive()}>
              <button
                id="btn-osd-skip-intro"
                class={`tv-btn ${focusId() === 'btn-osd-skip-intro' ? 'focused' : ''}`}
                onClick={() => { seekDelta(85000); showToast('Intro passée (+85 s)'); }}
                aria-label="Passer l'intro de 85 secondes"
              >
                ⏭ Passer l'intro (+85 s)
              </button>
            </Show>

            <Show when={isLive()}>
              <Show when={props.onPrevChannel}>
                <button
                  id="btn-osd-prev-ch"
                  class={`tv-btn ${focusId() === 'btn-osd-prev-ch' ? 'focused' : ''}`}
                  onClick={() => { props.onPrevChannel?.(); triggerChannelHud(); }}
                  aria-label="Chaîne précédente"
                >
                  ⏮ Précédente
                </button>
              </Show>
              <Show when={props.onNextChannel}>
                <button
                  id="btn-osd-next-ch"
                  class={`tv-btn ${focusId() === 'btn-osd-next-ch' ? 'focused' : ''}`}
                  onClick={() => { props.onNextChannel?.(); triggerChannelHud(); }}
                  aria-label="Chaîne suivante"
                >
                  ⏭ Suivante
                </button>
              </Show>
              <Show when={props.canRecall && props.onRecall}>
                <button
                  id="btn-osd-recall"
                  class={`tv-btn ${focusId() === 'btn-osd-recall' ? 'focused' : ''}`}
                  onClick={triggerRecall}
                  aria-label="Revenir à la chaîne précédente"
                >
                  ↺ Dernière
                </button>
              </Show>
              <Show when={startOverUrl()}>
                <button
                  id="btn-osd-startover"
                  class={`tv-btn ${focusId() === 'btn-osd-startover' ? 'focused' : ''}`}
                  onClick={startOverProgram}
                  aria-label="Revoir le programme depuis le début"
                >
                  ↺ Début
                </button>
              </Show>
              <button
                id="btn-osd-miniguide"
                class={`tv-btn ${focusId() === 'btn-osd-miniguide' ? 'focused' : ''}`}
                onClick={toggleMiniGuide}
                aria-label="Ouvrir la liste des chaînes"
              >
                📋 Chaînes
              </button>
              <Show when={mirrors().length > 0}>
                <button
                  id="btn-osd-mirrors"
                  class={`tv-btn ${focusId() === 'btn-osd-mirrors' ? 'focused' : ''}`}
                  onClick={toggleMirrors}
                  aria-label="Choisir une source ou qualité alternative"
                >
                  📡 Sources ({mirrors().length + 1})
                </button>
              </Show>
            </Show>

            <Show when={liveReturnChannel()}>
              <button
                id="btn-osd-return-live"
                class={`tv-btn ${focusId() === 'btn-osd-return-live' ? 'focused' : ''}`}
                onClick={returnToLive}
                aria-label="Revenir au direct"
              >
                📡 Direct
              </button>
            </Show>

            <Show when={!liveReturnChannel()}>
              <button
                id="btn-osd-fav"
                class={`tv-btn ${focusId() === 'btn-osd-fav' ? 'focused' : ''}`}
                onClick={() => void toggleFavorite()}
                aria-label={info.isFavorite() ? 'Retirer des favoris' : 'Ajouter aux favoris'}
              >
                {info.isFavorite() ? '★ Favori' : '☆ Favori'}
              </button>
            </Show>

            <button
              id="btn-osd-aspect"
              class={`tv-btn ${focusId() === 'btn-osd-aspect' ? 'focused' : ''}`}
              onClick={toggleAspectMode}
              aria-label={`Format vidéo : ${aspectModeLabel(aspectMode())}`}
            >
              📐 {aspectModeLabel(aspectMode())}
            </button>

            <button
              id="btn-osd-sleep"
              class={`tv-btn ${focusId() === 'btn-osd-sleep' ? 'focused' : ''}`}
              onClick={cycleSleepTimer}
              aria-label="Configurer le minuteur de veille"
            >
              🌙 {sleepMinutes() > 0 ? `${sleepMinutes()}m` : 'Veille'}
            </button>

            <button
              id="btn-osd-audio-only"
              class={`tv-btn ${focusId() === 'btn-osd-audio-only' ? 'focused' : ''}`}
              onClick={toggleAudioOnly}
              aria-label="Mode audio uniquement avec écran noir"
            >
              🎵 Écran noir
            </button>

            <button
              id="btn-osd-audio-track"
              class={`tv-btn ${focusId() === 'btn-osd-audio-track' ? 'focused' : ''}`}
              onClick={cycleAudioTrack}
              aria-label={audioLabel()}
            >
              🔊 {audioLabel()}
              <Show when={audioTracks().length > 1}>
                <span class="tv-btn-count"> · {audioTracks().length} pistes</span>
              </Show>
            </button>

            <button
              id="btn-osd-sub-track"
              class={`tv-btn ${focusId() === 'btn-osd-sub-track' ? 'focused' : ''}`}
              onClick={cycleSubtitleTrack}
              aria-label={subtitleLabel()}
            >
              💬 {subtitleLabel()}
            </button>

            <button
              id="btn-osd-assistant"
              class={`tv-btn ${focusId() === 'btn-osd-assistant' ? 'focused' : ''}`}
              onClick={() => setShowAssistant(true)}
              aria-label="Ouvrir l'assistant IA"
            >
              ✨ Assistant
            </button>
          </div>

          <Show when={!isLive() && similar().length > 0}>
            <div class="tv-osd-next" role="group" aria-label="À suivre : films similaires">
              <Show when={countdown() !== null}>
                <div class="tv-osd-countdown" role="status" aria-live="polite">
                  Film suivant dans <b>{countdown()} s</b> : {filmTitle(similar()[0])} · <b>OK</b> lancer maintenant · <b>RETOUR</b> annuler
                </div>
              </Show>
              <Show when={stillWatching()}>
                <div class="tv-osd-countdown" role="status">Toujours là ? Choisissez un film pour continuer.</div>
              </Show>
              <div class="tv-osd-next-label">À SUIVRE · FILMS SIMILAIRES</div>
              <div class="tv-osd-next-row">
                <For each={similar()}>
                  {(film) => (
                    <button
                      id={`player-next-${film.id}`}
                      type="button"
                      tabindex="-1"
                      class={`tv-osd-next-card ${focusId() === `player-next-${film.id}` ? 'focused' : ''}`}
                      aria-label={`Lire ensuite : ${filmTitle(film)}`}
                      onClick={() => playNext(film)}
                    >
                      <span class="tv-osd-next-title">{filmTitle(film)}</span>
                      <span class="tv-osd-next-meta">
                        {[film.year || cleanMediaTitle(film.name).year, film.imdb_rating && film.imdb_rating > 0 ? `★ ${film.imdb_rating.toFixed(1)}` : '', film.group_title]
                          .filter(Boolean)
                          .join(' · ')}
                      </span>
                    </button>
                  )}
                </For>
              </div>
            </div>
          </Show>

          <div class="tv-osd-hints">
            <span><b>◀ ▶ ▲ ▼</b> naviguer</span>
            <span><b>OK</b> valider</span>
            <Show when={isLive()}>
              <span><b>CH +/−</b> zapper · <b>0–9</b> numéro</span>
            </Show>
            <Show when={!isLive()}>
              <span><b>⏪ ⏩</b> ±30 s</span>
            </Show>
            <span><b>RETOUR</b> quitter</span>
          </div>
        </div>
      </Show>

      {/* 9. Transparent Mini-Guide Drawer (AVPlay stays visible on the right) */}
      <Show when={showMiniGuide() && !playerError()}>
        <div class="tv-miniguide-drawer" role="dialog" aria-label="Liste des chaînes en direct">
          <div class="tv-miniguide-header">
            <div class="tv-miniguide-title">Chaînes · {props.liveCategory || props.item.group_title || 'Tout'}</div>
            <button
              id="btn-miniguide-close"
              class={`tv-btn ${focusId() === 'btn-miniguide-close' ? 'focused' : ''}`}
              onClick={closeMiniGuide}
            >
              ✕ Fermer
            </button>
          </div>
          <div class="tv-miniguide-list">
            <For each={miniGuideChannels()}>
              {(ch) => (
                <button
                  id={`miniguide-ch-${ch.id}`}
                  class={`tv-miniguide-row ${ch.id === props.item.id ? 'active' : ''} ${focusId() === `miniguide-ch-${ch.id}` ? 'focused' : ''}`}
                  onClick={() => selectMiniGuideChannel(ch)}
                >
                  <span class="tv-miniguide-chno">{ch.chno ? ch.chno : '•'}</span>
                  <span class="tv-miniguide-info">
                    <div class="tv-miniguide-name">{ch.name_clean || cleanMediaTitle(ch.name).clean}</div>
                    <Show when={miniGuideEpg()[ch.id]}>
                      <div class="tv-miniguide-epg">{miniGuideEpg()[ch.id]!.title}</div>
                    </Show>
                  </span>
                </button>
              )}
            </For>
          </div>
        </div>
      </Show>

      {/* 10. Quality & Mirrors Bar */}
      <Show when={showMirrors() && !playerError()}>
        <div class="tv-mirrors-bar" role="dialog" aria-label="Sources alternatives">
          <div class="tv-osd-label">QUALITÉ ET MIROIRS DISPONIBLES</div>
          <div class="tv-mirrors-row">
            <button
              id={`mirror-item-${props.item.id}`}
              class={`tv-btn ${focusId() === `mirror-item-${props.item.id}` ? 'focused' : ''}`}
              onClick={closeMirrors}
            >
              ✓ {title()} (actuel)
            </button>
            <For each={mirrors()}>
              {(mirror) => (
                <button
                  id={`mirror-item-${mirror.id}`}
                  class={`tv-btn ${focusId() === `mirror-item-${mirror.id}` ? 'focused' : ''}`}
                  onClick={() => selectMirror(mirror)}
                >
                  {mirror.name_clean || cleanMediaTitle(mirror.name).clean}
                </button>
              )}
            </For>
            <button
              id="btn-mirrors-close"
              class={`tv-btn ${focusId() === 'btn-mirrors-close' ? 'focused' : ''}`}
              onClick={closeMirrors}
            >
              ✕ Fermer
            </button>
          </div>
        </div>
      </Show>

      <Show when={showAssistant()}>
        <AssistantModal
          onClose={() => {
            setShowAssistant(false);
            updateGrid();
          }}
          onPlayItem={(newItem) => {
            setShowAssistant(false);
            player.open(newItem.stream_url, newItem.kind === 'live');
            player.play();
          }}
        />
      </Show>
    </div>
  );
};
