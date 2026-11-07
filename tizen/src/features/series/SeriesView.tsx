import { Component, createSignal, onMount, For, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { createInfiniteScroller } from '../../core/pagination/InfiniteScrollController';
import { TvSearchBar } from '../../ui/components/TvSearchBar';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { getCategoryMeta, formatViewCount } from '../../core/utils/categoryMeta';
import { announce } from '../../ui/design/a11y';

export interface SeriesViewProps {
  onSelectSeries: (series: ItemRecord) => void;
}

export const SeriesView: Component<SeriesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const PAGE_SIZE = 25;

  const [categories, setCategories] = createSignal<string[]>([]);
  const [selectedCat, setSelectedCat] = createSignal<string>('');
  const [searchQuery, setSearchQuery] = createSignal<string>('');
  const [searchResults, setSearchResults] = createSignal<ItemRecord[]>([]);
  const [previewSeries, setPreviewSeries] = createSignal<ItemRecord | null>(null);
  const [isFav, setIsFav] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();

  const isSearchMode = () => searchQuery().trim().length > 0;
  const activeSeries = () => isSearchMode() ? searchResults() : scroller.items();

  const activePreviewSeries = (): ItemRecord | null => {
    return previewSeries() || (activeSeries().length > 0 ? activeSeries()[0] : null);
  };

  const previewTitle = () => {
    const s = activePreviewSeries();
    if (!s) return 'Séries TV';
    return s.name_clean && s.name_clean !== s.name ? s.name_clean : cleanMediaTitle(s.name).clean;
  };

  const scroller = createInfiniteScroller<ItemRecord>({
    pageSize: PAGE_SIZE,
    threshold: 10,
    maxItems: 300,
    fetchBatch: async (offset, limit) => {
      const cat = selectedCat();
      const [list, count] = await Promise.all([
        engine.getCatalog('series', cat, offset, limit),
        engine.countCatalog('series', cat),
      ]);
      return { items: list, total: count };
    },
    onBatchLoaded: (list, total) => {
      if (!isSearchMode()) {
        announce(`Séries, ${list.length} séries affichées sur ${total}`);
        if (!previewSeries() && list.length > 0) {
          updatePreview(list[0]);
        }
        rebuildGrid(categories(), list, true);
      }
    },
  });

  onMount(async () => {
    const cats = await engine.getCategories('series');
    setCategories(cats);
    if (cats.length > 0) {
      setSelectedCat(cats[0]);
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        updatePreview(items[0]);
      }
      rebuildGrid(cats, items, false);
      if (items.length > 0) {
        spatialNav.setFocusById(`series-${items[0].id}`);
      } else {
        spatialNav.setFocusById('series-cat-0');
      }
    } else {
      rebuildGrid([], [], false);
    }
  });

  const updatePreview = (series: ItemRecord) => {
    setPreviewSeries(series);
    setIsFav(series.is_favorite === 1);
  };

  const focusInput = (id: string) => {
    const el = document.getElementById(id);
    if (el) (el as HTMLInputElement).focus();
  };

  const handleSearch = async (query: string) => {
    setSearchQuery(query);
    if (!query.trim()) {
      setSearchResults([]);
      rebuildGrid(categories(), scroller.items(), false);
      return;
    }
    const results = await engine.searchCatalog(query, 'series', 60);
    setSearchResults(results);
    if (results.length > 0) {
      updatePreview(results[0]);
    }
    announce(`${results.length} résultats pour la recherche ${query}`);
    rebuildSearchGrid(results);
  };

  const handleClearSearch = () => {
    setSearchQuery('');
    setSearchResults([]);
    rebuildGrid(categories(), scroller.items(), false);
  };

  const handleToggleFav = async () => {
    const current = activePreviewSeries();
    if (!current) return;
    const next = await engine.toggleFavorite(current.id);
    setIsFav(next);
    announce(next ? 'Série ajoutée aux favoris' : 'Série retirée des favoris');
    if (selectedCat().includes('Favoris')) {
      await scroller.reset();
      const items = scroller.items();
      if (items.length > 0) {
        updatePreview(items[0]);
      } else {
        setPreviewSeries(null);
      }
      rebuildGrid(categories(), items, false);
    }
  };

  const rebuildSearchGrid = (results: ItemRecord[]) => {
    const grid: FocusableItem[][] = [];

    // Search bar row
    const searchRow: FocusableItem[] = [
      { id: 'series-search-input', onSelect: () => focusInput('series-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'series-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    for (let i = 0; i < results.length; i++) {
      const s = results[i];
      const row: FocusableItem[] = [
        {
          id: `series-${s.id}`,
          onFocus: () => updatePreview(s),
          onSelect: () => props.onSelectSeries(s),
        },
      ];
      if (i === 0) row.push({ id: 'btn-series-details', onSelect: () => props.onSelectSeries(s) });
      else if (i === 1) row.push({ id: 'btn-series-fav', onSelect: () => void handleToggleFav() });
      grid.push(row);
    }

    spatialNav.setGrid(grid, 0, 0, false);
  };

  const rebuildGrid = (cats: string[], list: ItemRecord[], preserveFocus = false) => {
    const grid: FocusableItem[][] = [];

    // Row 0: Search Bar
    const searchRow: FocusableItem[] = [
      { id: 'series-search-input', onSelect: () => focusInput('series-search-input') },
    ];
    if (searchQuery().trim()) {
      searchRow.push({ id: 'series-search-input-clear', onSelect: handleClearSearch });
    }
    grid.push(searchRow);

    const maxRows = Math.max(cats.length, list.length);

    for (let i = 0; i < maxRows; i++) {
      const row: FocusableItem[] = [];

      // Column 0: Categories (vertical list)
      if (cats.length > 0) {
        const catIdx = Math.min(i, cats.length - 1);
        const cat = cats[catIdx];
        row.push({
          id: `series-cat-${catIdx}`,
          onSelect: () => void handleSelectCategory(cat),
        });
      }

      // Column 1: Series list
      if (list.length > 0) {
        const seriesIdx = Math.min(i, list.length - 1);
        const s = list[seriesIdx];
        row.push({
          id: `series-${s.id}`,
          onFocus: () => {
            void scroller.checkTrigger(seriesIdx);
            updatePreview(s);
          },
          onSelect: () => props.onSelectSeries(s),
        });
      }

      // Column 2: Side action buttons for hero player
      if (i === 0) {
        row.push({
          id: 'btn-series-details',
          onSelect: () => activePreviewSeries() && props.onSelectSeries(activePreviewSeries()!),
        });
      } else if (i === 1) {
        row.push({ id: 'btn-series-fav', onSelect: () => void handleToggleFav() });
      }

      grid.push(row);
    }

    spatialNav.setGrid(grid, list.length > 0 ? 1 : 0, cats.length > 0 ? 1 : 0, preserveFocus);
  };

  const handleSelectCategory = async (cat: string) => {
    if (cat === selectedCat()) return;
    setSearchQuery('');
    setSearchResults([]);
    setSelectedCat(cat);
    await scroller.reset();
    const items = scroller.items();
    if (items.length > 0) {
      updatePreview(items[0]);
    }
    rebuildGrid(categories(), items, false);
    if (items.length > 0) {
      spatialNav.setFocusById(`series-${items[0].id}`);
    }
  };

  const handleContainerScroll = (e: Event) => {
    if (isSearchMode()) return;
    const el = e.currentTarget as HTMLElement;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 350) {
      void scroller.loadMore();
    }
  };

  return (
    <div style={{ width: "100%", height: "100%", overflow: "hidden" }}>
      <div class="tv-minimal-3col">
        {/* Column 1: Categories Sidebar */}
        <div class="tv-min-col-categories" role="tablist" aria-label="Catégories de séries">
          <h1 class="tv-min-col-title">
            <span>Séries TV</span>
          </h1>

          <div style={{ "margin-bottom": "14px" }}>
            <TvSearchBar
              id="series-search-input"
              placeholder="Rechercher une série..."
              value={searchQuery()}
              onInput={handleSearch}
              onClear={handleClearSearch}
              focusId={focusId()}
            />
          </div>

          <div class="tv-min-cat-list">
            <For each={categories()}>
              {(cat, idx) => {
                const meta = getCategoryMeta(cat);
                const isSelected = () => selectedCat() === cat;
                return (
                  <div
                    id={`series-cat-${idx()}`}
                    role="tab"
                    tabindex="-1"
                    aria-selected={isSelected()}
                    aria-label={`Catégorie ${cat}`}
                    class={`tv-min-cat-item ${isSelected() ? 'active' : ''} ${focusId() === `series-cat-${idx()}` ? 'focused' : ''}`}
                    onClick={() => void handleSelectCategory(cat)}
                  >
                    <div class="tv-min-cat-badge">{meta.icon}</div>
                    <div class="tv-min-cat-info">
                      <div class="tv-min-cat-name">{cat}</div>
                      <div class="tv-min-cat-count">
                        {isSelected() ? `${scroller.total()} Séries` : 'Séries'}
                      </div>
                    </div>
                  </div>
                );
              }}
            </For>
          </div>
        </div>

        {/* Column 2: Cards List with Infinite Scroll */}
        <div
          class="tv-min-col-cards"
          role="list"
          aria-label="Catalogue des séries"
          onScroll={handleContainerScroll}
        >
          <div class="tv-min-cards-scroll">
            <Show
              when={activeSeries().length > 0}
              fallback={
                <div style={{ padding: "48px 20px", "text-align": "center", color: "var(--buntu-text-muted)", "font-size": "18px" }}>
                  {isSearchMode()
                    ? `Aucune série ne correspond à "${searchQuery()}".`
                    : selectedCat().includes('Favoris')
                    ? 'Aucune série dans vos favoris. Appuyez sur ☆ Favori pour ajouter vos séries préférées !'
                    : 'Aucune série dans cette catégorie.'}
                </div>
              }
            >
              <For each={activeSeries()}>
                {(series) => {
                  const title = series.name_clean && series.name_clean !== series.name
                    ? series.name_clean
                    : cleanMediaTitle(series.name).clean;
                  const is4k = title.toLowerCase().includes('4k') || title.toLowerCase().includes('uhd');
                  const isSelected = () => activePreviewSeries()?.id === series.id;
                  return (
                    <div
                      id={`series-${series.id}`}
                      role="button"
                      tabindex="-1"
                      aria-label={`Série ${title}`}
                      class={`tv-min-media-card ${focusId() === `series-${series.id}` ? 'focused' : ''} ${isSelected() ? 'active' : ''}`}
                      onClick={() => props.onSelectSeries(series)}
                    >
                      <div class="tv-min-card-thumb">
                        <Show
                          when={series.logo_url}
                          fallback={<span style={{ "font-size": "32px" }}>🍿</span>}
                        >
                          <img
                            src={series.logo_url}
                            alt=""
                            loading="lazy"
                            referrerpolicy="no-referrer"
                            crossOrigin="anonymous"
                            onError={(e) => {
                              const target = e.currentTarget as HTMLElement;
                              target.style.display = 'none';
                              if (target.parentElement) {
                                target.parentElement.innerHTML = '<span style="font-size:32px;">🍿</span>';
                              }
                            }}
                          />
                        </Show>
                      </div>

                      <div class="tv-min-card-meta">
                        <div class="tv-min-card-title">{title}</div>
                        <div class="tv-min-card-views">
                          {series.season_num ? `Saison ${series.season_num} • ${formatViewCount(series.id)}` : formatViewCount(series.id)}
                        </div>
                        <div class="tv-min-card-tags">
                          <span class="tv-min-tag">{is4k ? '4K' : 'HD'}</span>
                          <span class="tv-min-tag">SÉRIE</span>
                          <Show when={series.episode_num}>
                            <span class="tv-min-tag" style={{ color: "var(--buntu-cyan)" }}>Ép. {series.episode_num}</span>
                          </Show>
                        </div>
                      </div>

                      <Show when={series.is_favorite === 1}>
                        <div class="tv-min-card-fav">★</div>
                      </Show>
                    </div>
                  );
                }}
              </For>
            </Show>

            {/* Infinite Scroll Loader */}
            <Show when={scroller.isLoading()}>
              <div style={{ "text-align": "center", padding: "16px", color: "var(--buntu-text-muted)" }}>
                Chargement des séries...
              </div>
            </Show>
          </div>
        </div>

        {/* Column 3: Hero Panel (16:9 Viewport + Details + Synopsis + Actions) */}
        <div class="tv-min-col-hero" role="region" aria-label="Aperçu de la série">
          <div id="tv-mini-viewport" class="tv-min-hero-viewport">
            <div class="tv-mini-mock-screen">
              <div class="tv-mini-live-tag" style={{ background: "rgba(245, 166, 35, 0.9)" }}>
                <span>🍿 SÉRIES TV</span>
              </div>
              <div class="tv-mini-hd-badge">1080p FHD</div>

              <div class="tv-mini-mock-art">
                <Show
                  when={activePreviewSeries()?.logo_url}
                  fallback={<span style={{ "font-size": "48px" }}>🍿</span>}
                >
                  <img
                    src={activePreviewSeries()!.logo_url}
                    alt=""
                    referrerpolicy="no-referrer"
                    crossOrigin="anonymous"
                    style={{ "max-width": "80px", "max-height": "80px", "object-fit": "contain" }}
                  />
                </Show>
              </div>

              <div class="tv-mini-mock-title">{previewTitle()}</div>
            </div>
          </div>

          {/* Now Playing Metadata Section */}
          <div class="tv-min-hero-info">
            <div class="tv-min-now-label">FICHE SÉRIE...</div>
            <h2 class="tv-min-hero-title">{previewTitle()}</h2>
            <p class="tv-min-hero-desc">
              {activePreviewSeries()?.plot || (activePreviewSeries()?.group_title ? `Série disponible dans le bouquet ${activePreviewSeries()!.group_title}. Tous les épisodes et saisons disponibles en qualité Full HD.` : 'Série télévisée complète avec saisons et épisodes.')}
            </p>

            {/* Progress Bar Timeline */}
            <div class="tv-min-hero-progress">
              <span class="tv-min-time">Saison {activePreviewSeries()?.season_num || 1}</span>
              <div class="tv-min-track">
                <div class="tv-min-fill" style={{ width: "60%" }}>
                  <div class="tv-min-knob" />
                </div>
              </div>
              <span class="tv-min-time">Épisode {activePreviewSeries()?.episode_num || 1}</span>
            </div>

            {/* Hero Action Buttons */}
            <div class="tv-min-hero-actions">
              <button
                id="btn-series-details"
                role="button"
                tabindex="-1"
                aria-label={`Voir les épisodes de ${previewTitle()}`}
                class={`tv-min-btn-play ${focusId() === 'btn-series-details' ? 'focused' : ''}`}
                onClick={() => activePreviewSeries() && props.onSelectSeries(activePreviewSeries()!)}
              >
                ▶ Voir les épisodes
              </button>

              <button
                id="btn-series-fav"
                role="button"
                tabindex="-1"
                aria-label="Basculer favori"
                class={`tv-min-btn-secondary ${focusId() === 'btn-series-fav' ? 'focused' : ''}`}
                onClick={() => void handleToggleFav()}
              >
                {isFav() ? '★ Retirer Favori' : '☆ Favori'}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
