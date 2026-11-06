import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface LiveViewProps {
  onPlayChannel: (channel: ItemRecord) => void;
}

export const LiveView: Component<LiveViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCategory, setSelectedCategory] = createSignal<string>('');
  const [channels, setChannels] = createSignal<ItemRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const cats = await engine.getCategories('live');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCategory(cats[0]);
      await loadChannels(cats[0]);
    }
  });

  const loadChannels = async (category: string) => {
    const list = await engine.getCatalog('live', category, 0, 50);
    setChannels(list);

    // Build spatial navigation grid:
    // Left column: categories
    // Right column: channels in category
    const grid = list.map((ch, idx) => [
      {
        id: `channel-${ch.id}`,
        onSelect: () => props.onPlayChannel(ch),
        onFocus: () => {
          // Inline audio/video preview when settling on channel
          engine.play(ch);
        },
      },
    ]);
    spatialNav.setGrid(grid);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Direct TV</h2>
        <div style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
          {channels().length} chaînes disponibles
        </div>
      </div>

      <div style={{ display: "flex", gap: "32px", flex: 1, "overflow-y": "hidden" }}>
        {/* Categories Sidebar */}
        <div style={{
          width: "360px",
          display: "flex",
          "flex-direction": "column",
          gap: "8px",
          "overflow-y": "auto",
          "border-right": "1px solid var(--buntu-border)",
          "padding-right": "16px"
        }}>
          <For each={categories()}>
            {(cat) => (
              <div
                class={`tv-nav-item ${selectedCategory() === cat ? 'active' : ''}`}
                onClick={() => {
                  setSelectedCategory(cat);
                  loadChannels(cat);
                }}
                style={{ cursor: "pointer" }}
              >
                {cat}
              </div>
            )}
          </For>
        </div>

        {/* Channels List */}
        <div style={{ flex: 1, display: "flex", "flex-direction": "column", gap: "12px", "overflow-y": "auto" }}>
          <For each={channels()}>
            {(ch) => (
              <div
                class={`tv-card ${focusId() === `channel-${ch.id}` ? 'focused' : ''}`}
                style={{
                  padding: "16px 24px",
                  display: "flex",
                  "align-items": "center",
                  gap: "24px",
                }}
                onClick={() => props.onPlayChannel(ch)}
              >
                <div style={{
                  "font-size": "24px",
                  "font-weight": "800",
                  color: "var(--buntu-cyan)",
                  width: "48px"
                }}>
                  {ch.chno || '•'}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ "font-size": "22px", "font-weight": "700" }}>{ch.name}</div>
                  <div style={{ "font-size": "16px", color: "var(--buntu-text-muted)" }}>
                    {ch.group_title || 'Général'}
                  </div>
                </div>
                <div style={{ "font-size": "14px", color: "var(--buntu-gold)" }}>
                  {ch.catchup_days ? `Replay ${ch.catchup_days}j` : ''}
                </div>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
};

