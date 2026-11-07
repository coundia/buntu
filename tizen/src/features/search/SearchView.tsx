import { Component, createSignal, For, Show, onMount } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

export interface SearchViewProps {
  onSelectResult: (item: ItemRecord) => void;
}

export const SearchView: Component<SearchViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [query, setQuery] = createSignal('');
  const [selectedKind, setSelectedKind] = createSignal<'all' | 'live' | 'movie' | 'series'>('all');
  const [results, setResults] = createSignal<any[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  const FILTER_TABS: { key: 'all' | 'live' | 'movie' | 'series'; label: string }[] = [
    { key: 'all', label: 'Tout' },
    { key: 'live', label: 'Direct TV' },
    { key: 'movie', label: 'Films & VOD' },
    { key: 'series', label: 'Séries TV' },
  ];

  const KEYBOARD_ROWS = [
    ['A', 'B', 'C', 'D', 'E', 'F', '1', '2', '3'],
    ['G', 'H', 'I', 'J', 'K', 'L', '4', '5', '6'],
    ['M', 'N', 'O', 'P', 'Q', 'R', '7', '8', '9'],
    ['S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '0'],
    ['ESPACE', 'EFFACER', 'RECHERCHER'],
  ];

  const rebuildGrid = (resList: any[]) => {
    const prevFocus = spatialNav.getCurrentFocusId();

    // Row 0: Filter Tabs
    const tabRow: FocusableItem[] = FILTER_TABS.map((tab) => ({
      id: `search-tab-${tab.key}`,
      onSelect: () => {
        setSelectedKind(tab.key);
        void performSearch();
      },
    }));

    // Keyboard Rows
    const kbRows: FocusableItem[][] = KEYBOARD_ROWS.map((row) =>
      row.map((k) => ({
        id: `key-${k}`,
        onSelect: () => void handleKeyClick(k),
      }))
    );

    // Results Rows
    const resRows: FocusableItem[][] = resList.map((res, idx) => [
      {
        id: `search-res-${idx}`,
        onSelect: () => props.onSelectResult(res.candidate as any),
      },
    ]);

    spatialNav.setGrid([tabRow, ...kbRows, ...resRows]);
    if (prevFocus.startsWith('key-') || prevFocus.startsWith('search-tab-')) {
      spatialNav.setFocusById(prevFocus);
    }
  };

  onMount(() => {
    rebuildGrid([]);
  });

  const handleKeyClick = async (char: string) => {
    let next = query();
    if (char === 'ESPACE') {
      next += ' ';
    } else if (char === 'EFFACER') {
      next = next.slice(0, -1);
    } else if (char === 'RECHERCHER') {
      await performSearch();
      return;
    } else {
      next += char;
    }
    setQuery(next);
    await performSearch();
  };

  const performSearch = async () => {
    const q = query().trim();
    if (!q) {
      setResults([]);
      rebuildGrid([]);
      return;
    }
    const kindFilter = selectedKind() === 'all' ? undefined : selectedKind();
    const res = await engine.search(q, kindFilter);
    setResults(res);
    rebuildGrid(res);
  };

  return (
    <div class="tv-container">
      {/* Header */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Recherche Globale IPTV</span>
        </h1>

        {/* Filter Pills */}
        <div style={{ display: "flex", "margin-left": "24px" }} role="tablist" aria-label="Filtres de recherche">
          <For each={FILTER_TABS}>
            {(tab) => (
              <button
                id={`search-tab-${tab.key}`}
                role="tab"
                tabindex="-1"
                aria-selected={selectedKind() === tab.key}
                class={`tv-category-pill ${selectedKind() === tab.key ? 'active' : ''} ${focusId() === `search-tab-${tab.key}` ? 'focused' : ''}`}
                onClick={() => {
                  setSelectedKind(tab.key);
                  void performSearch();
                }}
              >
                {tab.label}
              </button>
            )}
          </For>
        </div>

        <div class="tv-live-badge">
          <span>{results().length} résultats</span>
        </div>
      </div>

      <div style={{ display: "flex", flex: 1, "overflow-y": "hidden" }}>
        {/* On-Screen Keyboard */}
        <div style={{ width: "620px", "margin-right": "32px", "flex-shrink": 0 }} role="group" aria-label="Clavier virtuel">
          {/* Query input display */}
          <div style={{
            background: "var(--buntu-slate)",
            padding: "14px 24px",
            "border-radius": "12px",
            "font-size": "24px",
            "font-weight": "700",
            border: "2px solid var(--buntu-border)",
            "margin-bottom": "20px",
            color: query() ? "#FFFFFF" : "var(--buntu-text-muted)"
          }}>
            {query() || 'Saisissez votre recherche...'}
          </div>

          <For each={KEYBOARD_ROWS}>
            {(row) => (
              <div style={{ display: "flex", "margin-bottom": "8px" }}>
                <For each={row}>
                  {(k) => (
                    <button
                      id={`key-${k}`}
                      tabindex="-1"
                      aria-label={`Touche ${k === 'ESPACE' ? 'Espace' : k === 'EFFACER' ? 'Effacer un caractère' : k === 'RECHERCHER' ? 'Lancer la recherche' : k}`}
                      class={`tv-btn ${focusId() === `key-${k}` ? 'focused' : ''}`}
                      style={{
                        padding: k.length > 1 ? "12px 24px" : "12px 20px",
                        "font-size": "18px",
                        "min-width": k.length === 1 ? "54px" : "auto",
                        "margin-right": "8px",
                      }}
                      onClick={() => void handleKeyClick(k)}
                    >
                      {k}
                    </button>
                  )}
                </For>
              </div>
            )}
          </For>
        </div>

        {/* Search Results List */}
        <div
          role="list"
          aria-label="Résultats de recherche"
          class="tv-live-channels"
        >
          <For each={results()}>
            {(res, idx) => (
              <div
                id={`search-res-${idx()}`}
                role="button"
                tabindex="-1"
                aria-label={`Résultat: ${res.candidate.name_clean || res.candidate.name}, catégorie ${res.candidate.group_title || 'générale'}, type ${res.candidate.kind}`}
                class={`tv-channel-row ${focusId() === `search-res-${idx()}` ? 'focused' : ''}`}
                onClick={() => props.onSelectResult(res.candidate as any)}
              >
                {/* Kind Badge */}
                <div class="tv-channel-num" style={{ "font-size": "14px", "min-width": "80px" }}>
                  {res.candidate.kind === 'live' ? 'DIRECT' : res.candidate.kind === 'series' ? 'SÉRIE' : 'FILM'}
                </div>

                {/* Candidate Info */}
                <div class="tv-channel-info">
                  <div class="tv-channel-name">
                    {res.candidate.name_clean || res.candidate.name}
                  </div>
                  <div class="tv-channel-meta">
                    {res.candidate.group_title || 'Général'} • {res.candidate.year || '2024'}
                  </div>
                </div>

                {/* Action Pill */}
                <Show when={focusId() === `search-res-${idx()}`}>
                  <div class="tv-watch-pill">
                    <span>▶</span>
                    <span>VOIR</span>
                  </div>
                </Show>
              </div>
            )}
          </For>

          <Show when={results().length === 0 && query().trim().length > 0}>
            <div style={{ "text-align": "center", color: "var(--buntu-text-muted)", padding: "48px 0", "font-size": "20px" }}>
              Aucun résultat trouvé pour "{query()}" dans {selectedKind() === 'all' ? 'le catalogue' : selectedKind()}.
            </div>
          </Show>
        </div>
      </div>
    </div>
  );
};
