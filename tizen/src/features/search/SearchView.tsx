import { Component, createSignal, For, onMount } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';

export interface SearchViewProps {
  onSelectResult: (item: ItemRecord) => void;
}

export const SearchView: Component<SearchViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [query, setQuery] = createSignal('');
  const [results, setResults] = createSignal<any[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  const KEYBOARD_ROWS = [
    ['A', 'B', 'C', 'D', 'E', 'F', '1', '2', '3'],
    ['G', 'H', 'I', 'J', 'K', 'L', '4', '5', '6'],
    ['M', 'N', 'O', 'P', 'Q', 'R', '7', '8', '9'],
    ['S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '0'],
    ['ESPACE', 'EFFACER', 'RECHERCHER'],
  ];

  const rebuildGrid = (resList: any[]) => {
    const prevFocus = spatialNav.getCurrentFocusId();
    const kbRows: FocusableItem[][] = KEYBOARD_ROWS.map((row) =>
      row.map((k) => ({
        id: `key-${k}`,
        onSelect: () => void handleKeyClick(k),
      }))
    );
    const resRows: FocusableItem[][] = resList.map((res, idx) => [
      {
        id: `search-res-${idx}`,
        onSelect: () => props.onSelectResult(res.candidate as any),
      },
    ]);
    spatialNav.setGrid([...kbRows, ...resRows]);
    if (prevFocus.startsWith('key-')) {
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
    const res = await engine.search(q);
    setResults(res);
    rebuildGrid(res);
  };

  return (
    <div class="tv-container">
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Recherche Instantanée</h2>
        <div style={{
          background: "var(--buntu-slate)",
          padding: "12px 24px",
          "border-radius": "8px",
          "min-width": "400px",
          "font-size": "24px",
          border: "2px solid var(--buntu-border)"
        }}>
          {query() || 'Saisissez votre recherche...'}
        </div>
      </div>

      <div style={{ display: "flex", gap: "48px", flex: 1, "overflow-y": "hidden" }}>
        {/* On-Screen Keyboard */}
        <div style={{ display: "flex", "flex-direction": "column", gap: "12px" }}>
          <For each={KEYBOARD_ROWS}>
            {(row) => (
              <div style={{ display: "flex", gap: "8px" }}>
                <For each={row}>
                  {(k) => (
                    <button
                      class={`tv-btn ${focusId() === `key-${k}` ? 'focused' : ''}`}
                      style={{
                        padding: k.length > 1 ? "12px 24px" : "12px 20px",
                        "font-size": "18px",
                        "min-width": k.length === 1 ? "56px" : "auto"
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

        {/* Search Results */}
        <div style={{ flex: 1, display: "flex", "flex-direction": "column", gap: "12px", "overflow-y": "auto" }}>
          <For each={results()}>
            {(res, idx) => (
              <div
                class={`tv-card ${focusId() === `search-res-${idx()}` ? 'focused' : ''}`}
                style={{
                  padding: "16px 24px",
                  display: "flex",
                  "justify-content": "space-between",
                  "align-items": "center",
                  cursor: "pointer"
                }}
                onClick={() => props.onSelectResult(res.candidate as any)}
              >
                <div>
                  <div style={{ "font-size": "22px", "font-weight": "700" }}>
                    {res.candidate.name_clean || res.candidate.name}
                  </div>
                  <div style={{ "font-size": "14px", color: "var(--buntu-text-muted)" }}>
                    {res.candidate.kind.toUpperCase()} • {res.candidate.year || ''} • {res.candidate.group_title || ''}
                  </div>
                </div>
                <div style={{ color: "var(--buntu-gold)", "font-weight": "800" }}>
                  Score: {res.score.toFixed(1)}
                </div>
              </div>
            )}
          </For>
          {results().length === 0 && query().trim().length > 0 && (
            <div style={{ "text-align": "center", color: "var(--buntu-text-muted)", padding: "48px" }}>
              Aucun résultat trouvé pour "{query()}"
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
