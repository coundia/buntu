import { Component, createSignal, onMount, For } from 'solid-js';
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
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const list = await engine.getCatalog('live', undefined, 0, 30);
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

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Guide des programmes (EPG)</h2>
        <div style={{ color: "var(--buntu-text-muted)" }}>
          {new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}
        </div>
      </div>

      <div
        role="list"
        aria-label="Liste des chaînes et programmes"
        style={{ display: "flex", "flex-direction": "column", gap: "12px", "overflow-y": "auto", flex: 1 }}
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
                class={`tv-card ${focusId() === `guide-channel-${ch.id}` ? 'focused' : ''}`}
                style={{
                  padding: "16px 24px",
                  display: "flex",
                  "align-items": "center",
                  gap: "24px",
                  cursor: "pointer",
                }}
                onClick={() => props.onPlayChannel(ch)}
              >
                <div style={{ width: "240px" }}>
                  <div style={{ "font-size": "20px", "font-weight": "700" }}>{ch.name}</div>
                  <div style={{ "font-size": "14px", color: "var(--buntu-text-muted)" }}>{ch.group_title}</div>
                </div>

                {/* Now Programme */}
                <div style={{ flex: 1, background: "var(--buntu-slate-light)", padding: "12px", "border-radius": "8px" }}>
                  <div style={{ "font-size": "18px", "font-weight": "600", color: "var(--buntu-cyan)" }}>
                    EN CE MOMENT: {nowTitle}
                  </div>
                  <div style={{ "font-size": "14px", color: "var(--buntu-text-muted)", "margin-top": "4px" }}>
                    {epg?.now?.description || 'Aucune information détaillée'}
                  </div>
                </div>

                {/* Next Programme */}
                <div style={{ width: "320px", background: "rgba(255,255,255,0.05)", padding: "12px", "border-radius": "8px" }}>
                  <div style={{ "font-size": "16px", "font-weight": "600" }}>
                    SUIVANT: {nextTitle}
                  </div>
                </div>
              </div>
            );
          }}
        </For>
      </div>
    </div>
  );
};

