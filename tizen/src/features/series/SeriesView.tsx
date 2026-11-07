import { Component, createSignal, onMount, For } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

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
    await loadSeries(cats[0], cats);
  });

  const loadSeries = async (category?: string, cats = categories()) => {
    setSelectedCat(category || '');
    const list = await engine.getCatalog('series', category, 0, 60);
    setSeriesList(list);

    const grid: FocusableItem[][] = [];
    const visibleCats = cats.slice(0, 8);
    if (visibleCats.length > 0) {
      grid.push(
        visibleCats.map((cat, idx) => ({
          id: `series-cat-${idx}`,
          onSelect: () => void loadSeries(cat, cats),
        }))
      );
    }

    const COLS = 5;
    for (let i = 0; i < list.length; i += COLS) {
      const row = list.slice(i, i + COLS).map((s) => ({
        id: `series-${s.id}`,
        onSelect: () => props.onSelectSeries(s),
      }));
      grid.push(row);
    }
    spatialNav.setGrid(grid, list.length > 0 && visibleCats.length > 0 ? 1 : 0, 0);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Séries TV</h2>
        <div style={{ display: "flex", gap: "12px", "overflow-x": "auto", "max-width": "1000px" }} role="tablist" aria-label="Catégories de séries">
          <For each={categories().slice(0, 8)}>
            {(cat, idx) => (
              <button
                id={`series-cat-${idx()}`}
                role="tab"
                tabindex="-1"
                aria-selected={selectedCat() === cat}
                aria-label={`Catégorie ${cat}`}
                class={`tv-nav-item ${selectedCat() === cat ? 'active' : ''} ${focusId() === `series-cat-${idx()}` ? 'focused' : ''}`}
                onClick={() => void loadSeries(cat)}
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
      }} role="list" aria-label="Catalogue des séries">
        <For each={seriesList()}>
          {(series) => (
            <div
              id={`series-${series.id}`}
              role="button"
              tabindex="-1"
              aria-label={`Série ${series.name_clean || series.name}, Saison ${series.season_num || 1}, Épisode ${series.episode_num || 1}`}
              class={`tv-card tv-poster-card ${focusId() === `series-${series.id}` ? 'focused' : ''}`}
              onClick={() => props.onSelectSeries(series)}
              style={{ width: "100%", height: "400px", cursor: "pointer" }}
            >
              <div
                class="tv-poster-img"
                style={{
                  height: "320px",
                  "background-image": series.logo_url ? `url(${series.logo_url})` : 'none',
                  "background-size": "cover",
                  "background-position": "center",
                  display: "flex",
                  "align-items": "center",
                  "justify-content": "center",
                  color: "var(--buntu-text-muted)",
                }}
              >
                {!series.logo_url && <span style={{ "font-size": "48px" }}>📺</span>}
              </div>
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
