import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface SeriesViewProps {
  onSelectSeries: (series: ItemRecord) => void;
}

export const SeriesView: Component<SeriesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [seriesList, setSeriesList] = createSignal<ItemRecord[]>([]);
  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const cats = await engine.getCategories('series');
    setCategories(cats);
    await loadSeries(cats[0]);
  });

  const loadSeries = async (category?: string) => {
    setSelectedCat(category || '');
    const list = await engine.getCatalog('series', category, 0, 60);
    setSeriesList(list);

    const COLS = 5;
    const grid = [];
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((s) => ({
        id: `series-${s.id}`,
        onSelect: () => props.onSelectSeries(s),
      }));
      grid.push(row);
    }
    spatialNav.setGrid(grid);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Séries TV</h2>
        <div style={{ display: "flex", gap: "12px", "overflow-x": "auto", "max-width": "1000px" }}>
          <For each={categories().slice(0, 8)}>
            {(cat) => (
              <button
                class={`tv-nav-item ${selectedCat() === cat ? 'active' : ''}`}
                onClick={() => loadSeries(cat)}
              >
                {cat}
              </button>
            )}
          </For>
        </div>
      </div>

      <div style={{
        display: "grid",
        "grid-template-columns": "repeat(5, 1fr)",
        gap: "24px",
        "overflow-y": "auto",
        padding: "16px 0",
        flex: 1
      }}>
        <For each={seriesList()}>
          {(series) => (
            <div
              class={`tv-card tv-poster-card ${focusId() === `series-${series.id}` ? 'focused' : ''}`}
              onClick={() => props.onSelectSeries(series)}
              style={{ width: "100%", height: "400px" }}
            >
              <div
                class="tv-poster-img"
                style={{
                  height: "320px",
                  "background-image": series.logo_url ? `url(${series.logo_url})` : 'none',
                  "background-size": "cover",
                  "background-position": "center",
                }}
              />
              <div class="tv-poster-title">{series.name_clean || series.name}</div>
              <div style={{
                display: "flex",
                "justify-content": "space-between",
                padding: "0 12px 8px 12px",
                "font-size": "14px",
                color: "var(--buntu-text-muted)"
              }}>
                <span>Saison {series.season_num || 1}</span>
                <span style={{ color: "var(--buntu-cyan)" }}>
                  Ép. {series.episode_num || 1}
                </span>
              </div>
            </div>
          )}
        </For>
      </div>
    </div>
  );
};
