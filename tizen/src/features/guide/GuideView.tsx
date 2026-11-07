import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, EpgProgramRecord, ItemRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface GuideViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
}

export const GuideView: Component<GuideViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const db = Database.getInstance();
  const [channels, setChannels] = createSignal<ItemRecord[]>([]);
  const [epgMap, setEpgMap] = createSignal<Record<string, { now?: EpgProgramRecord; next?: EpgProgramRecord }>>({});
  const [currentTime, setCurrentTime] = createSignal(
    new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })
  );
  const [focusId] = spatialNav.getFocusSignal();

  let timerId: any = null;

  onMount(async () => {
    timerId = setInterval(() => {
      setCurrentTime(new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }));
    }, 10000);

    const list = await engine.getCatalog('live', undefined, 0, 40);
    setChannels(list);

    const nowTs = Math.floor(Date.now() / 1000);
    const map: Record<string, { now?: EpgProgramRecord; next?: EpgProgramRecord }> = {};
    for (const ch of list) {
      if (ch.tvg_id) {
        map[ch.tvg_id] = await db.getEpgNowNext(ch.tvg_id, nowTs);
      }
    }
    setEpgMap(map);

    const grid = list.map((ch) => [
      {
        id: `guide-channel-${ch.id}`,
        onSelect: () => props.onPlayChannel(ch),
      },
    ]);
    spatialNav.setGrid(grid);
  });

  onCleanup(() => {
    if (timerId) clearInterval(timerId);
  });

  return (
    <div class="tv-container">
      {/* Header */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Guide des programmes (EPG)</span>
        </h1>
        <div class="tv-live-badge">
          <span>🕒 {currentTime()}</span>
          <span style={{ opacity: 0.5 }}>•</span>
          <span>{channels().length} chaînes</span>
        </div>
      </div>

      {/* Guide Rows */}
      <div
        role="list"
        aria-label="Liste des chaînes et programmes"
        class="tv-live-channels"
      >
        <For each={channels()}>
          {(ch) => {
            const epg = ch.tvg_id ? epgMap()[ch.tvg_id] : undefined;
            const nowTitle = epg?.now?.title || 'Programme en cours';
            const nextTitle = epg?.next?.title || 'À suivre';
            return (
              <div
                id={`guide-channel-${ch.id}`}
                role="button"
                tabindex="-1"
                aria-label={`Chaîne ${ch.name}. En ce moment: ${nowTitle}. Suivant: ${nextTitle}. Appuyez pour regarder.`}
                class={`tv-guide-row ${focusId() === `guide-channel-${ch.id}` ? 'focused' : ''}`}
                onClick={() => props.onPlayChannel(ch)}
              >
                {/* Channel Column: Number + Name */}
                <div class="tv-guide-channel-col">
                  <div class="tv-guide-num">
                    {ch.chno || '•'}
                  </div>
                  <div class="tv-guide-channel-text">
                    <div class="tv-guide-channel-name">{ch.name}</div>
                    <div class="tv-guide-channel-cat">{ch.group_title || 'Direct TV'}</div>
                  </div>
                </div>

                {/* Now Programme */}
                <div class="tv-guide-now-box">
                  <div class="tv-guide-now-header">
                    <span class="tv-guide-live-pill">
                      <span class="tv-guide-live-dot" />
                      DIRECT
                    </span>
                    <span class="tv-guide-now-title">{nowTitle}</span>
                  </div>
                  <div class="tv-guide-now-desc">
                    {epg?.now?.description || 'Aucune information détaillée sur le programme'}
                  </div>
                </div>

                {/* Next Programme */}
                <div class="tv-guide-next-box">
                  <div class="tv-guide-next-label">À SUIVRE</div>
                  <div class="tv-guide-next-title">{nextTitle}</div>
                </div>

                {/* Focused Action Pill */}
                <Show when={focusId() === `guide-channel-${ch.id}`}>
                  <div class="tv-watch-pill">
                    <span>▶</span>
                    <span>REGARDER</span>
                  </div>
                </Show>
              </div>
            );
          }}
        </For>
      </div>
    </div>
  );
};
