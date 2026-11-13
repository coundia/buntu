import { Component, createSignal, For, Show, onMount, onCleanup } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { cleanMediaTitle } from '../../core/utils/titleCleaner';
import { getAiSettings } from '../../core/ai/AiSettings';
import { SearchMode, searchMode, setSearchMode } from '../../core/search/searchMode';
import { PairingOffer, PairingService } from '../../core/pairing/PairingService';

export interface SearchViewProps {
  onSelectResult: (item: ItemRecord) => void;
}

export const SearchView: Component<SearchViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [query, setQuery] = createSignal('');
  const [selectedKind, setSelectedKind] = createSignal<'all' | 'live' | 'movie' | 'series'>('all');
  const [results, setResults] = createSignal<any[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  // AI assistant status & progressive loading
  const [isAiLoading, setIsAiLoading] = createSignal(false);
  const [aiNotice, setAiNotice] = createSignal('');
  const [pairingActive, setPairingActive] = createSignal(false);
  const [qrOffer, setQrOffer] = createSignal<PairingOffer | null>(null);

  // Search mode (shared with Live, Films and Séries): "Local" looks in the catalogue only; "IA" also asks the assistant.
  const mode = searchMode;
  const setMode = async (next: SearchMode) => setAiNotice((await setSearchMode(next)).message);
  const MODES: { key: SearchMode; label: string }[] = [
    { key: 'local', label: 'Local' },
    { key: 'ai', label: '✨ IA' },
  ];

  let pairingService: PairingService | null = null;
  let typingTimer: any = null;

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
    ['ESPACE', 'EFFACER', 'RECHERCHER', '📱 TÉLÉPHONE'],
  ];

  const rebuildGrid = (resList: any[]) => {
    if (pairingActive()) {
      spatialNav.setGrid([[{ id: 'btn-search-close-qr', onSelect: stopPairing }]]);
      spatialNav.setFocusById('btn-search-close-qr');
      return;
    }

    const prevFocus = spatialNav.getCurrentFocusId();

    // Row 0: Filter Tabs
    const tabRow: FocusableItem[] = FILTER_TABS.map((tab) => ({
      id: `search-tab-${tab.key}`,
      onSelect: () => {
        setSelectedKind(tab.key);
        void performLocalSearch();
      },
    }));

    // The mode choice sits in the same row as the filters.
    for (const m of MODES) {
      tabRow.push({ id: `search-mode-${m.key}`, onSelect: () => setMode(m.key) });
    }

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
    if (prevFocus.startsWith('key-') || prevFocus.startsWith('search-tab-') || prevFocus.startsWith('search-mode-')) {
      spatialNav.setFocusById(prevFocus);
    }
  };

  const handleKeyClick = async (char: string) => {
    if (char === '📱 TÉLÉPHONE') {
      await startPhonePairing();
      return;
    }
    let next = query();
    if (char === 'ESPACE') {
      next += ' ';
    } else if (char === 'EFFACER') {
      next = next.slice(0, -1);
    } else if (char === 'RECHERCHER') {
      await performLocalSearch();
      if (mode() === 'ai') await performAiSearch();
      return;
    } else {
      next += char;
    }
    setQuery(next);

    // Debounced instant local suggestions (< 150ms SLA)
    clearTimeout(typingTimer);
    typingTimer = setTimeout(() => {
      void performLocalSearch();
    }, 120);
  };

  const performLocalSearch = async () => {
    const q = query().trim();
    if (!q) {
      setResults([]);
      rebuildGrid([]);
      return;
    }
    const kindFilter = selectedKind() === 'all' ? undefined : (selectedKind() as 'live' | 'movie' | 'series');
    const res = await engine.search(q, kindFilter);
    setResults(res);
    rebuildGrid(res);
  };

  const performAiSearch = async () => {
    const q = query().trim();
    if (!q) {
      setAiNotice('Saisissez une phrase avant de demander à l’assistant');
      return;
    }

    // Local results stay on screen while AI processes
    setIsAiLoading(true);
    setAiNotice('L’assistant réfléchit…');

    try {
      const aiRes = await engine.understandSearchWithAi(q);
      setIsAiLoading(false);

      if (aiRes.ok && aiRes.understanding) {
        const u = aiRes.understanding;
        setAiNotice(u.reply || 'Résultats affinés par l’assistant');

        // If title guesses exist, search catalog for them
        if (Array.isArray(u.title_guesses) && u.title_guesses.length > 0) {
          const kindFilter = selectedKind() === 'all' ? undefined : (selectedKind() as 'live' | 'movie' | 'series');
          const matched: any[] = [];
          const seen = new Set<number>();

          for (const guess of u.title_guesses.slice(0, 15)) {
            const hits = await engine.searchCatalog(guess.title, kindFilter, 3);
            for (const h of hits) {
              if (!seen.has(h.id)) {
                seen.add(h.id);
                matched.push({
                  candidate: h,
                  aiReason: u.similar_to ? `Similaire à ${u.similar_to}` : 'Suggéré par l’assistant',
                });
              }
            }
          }

          // Merge with local results
          if (matched.length > 0) {
            const merged = [...matched, ...results().filter((r) => !seen.has(r.candidate.id))];
            setResults(merged);
            rebuildGrid(merged);
          }
        }
      } else {
        setAiNotice(`Assistant indisponible (${aiRes.error || 'repli local'}) : résultats locaux`);
      }
    } catch (err: any) {
      setIsAiLoading(false);
      setAiNotice('Assistant indisponible : résultats locaux conservés');
    }
  };

  const startPhonePairing = async () => {
    try {
      setPairingActive(true);
      pairingService = new PairingService({
        onRequest: () => {},
        onTextReceived: (text) => {
          stopPairing();
          setQuery(text);
          void performLocalSearch();
        },
        onClosed: () => {
          stopPairing();
        },
        onError: (err) => {
          setAiNotice(`Erreur appairage : ${err}`);
        },
      });

      const offer = await pairingService.start();
      setQrOffer(offer);
      rebuildGrid(results());
    } catch (e: any) {
      setPairingActive(false);
      setAiNotice(e?.message || 'Impossible de démarrer l’appairage');
      rebuildGrid(results());
    }
  };

  const stopPairing = () => {
    pairingService?.stop();
    pairingService = null;
    setPairingActive(false);
    setQrOffer(null);
    rebuildGrid(results());
  };

  onMount(() => {
    rebuildGrid([]);
  });

  onCleanup(() => {
    clearTimeout(typingTimer);
    pairingService?.stop();
  });

  const aiSettings = getAiSettings();
  const hasAi = aiSettings.provider !== 'local_only';

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        padding: '24px 40px',
        'box-sizing': 'border-box',
        overflow: 'hidden',
        display: 'flex',
        'flex-direction': 'column',
      }}
    >
      {/* Header */}
      <div class="tv-live-header">
        <h1 class="tv-live-title">
          <span>Recherche Universelle & IA</span>
        </h1>

        {/* Filter Pills */}
        <div style={{ display: 'flex', 'margin-left': '24px' }} role="tablist" aria-label="Filtres de recherche">
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
                  void performLocalSearch();
                }}
              >
                {tab.label}
              </button>
            )}
          </For>
        </div>

        {/* Search mode: local catalogue only, or with the assistant */}
        <div style={{ display: 'flex', 'margin-left': '24px' }} role="radiogroup" aria-label="Mode de recherche">
          <For each={MODES}>
            {(m) => (
              <button
                id={`search-mode-${m.key}`}
                role="radio"
                tabindex="-1"
                aria-checked={mode() === m.key}
                aria-label={m.key === 'ai' ? 'Recherche avec l’assistant IA' : 'Recherche locale dans le catalogue'}
                class={`tv-category-pill ${mode() === m.key ? 'active' : ''} ${focusId() === `search-mode-${m.key}` ? 'focused' : ''}`}
                onClick={() => setMode(m.key)}
              >
                {m.label}
              </button>
            )}
          </For>
        </div>

        <div class="tv-live-badge">
          <span>{results().length} résultats</span>
        </div>
      </div>

      {/* AI Notification Banner */}
      <Show when={aiNotice()}>
        <div
          style={{
            background: isAiLoading() ? 'rgba(212, 160, 23, 0.2)' : 'rgba(30, 41, 59, 0.8)',
            border: '1px solid var(--buntu-gold)',
            padding: '10px 20px',
            'border-radius': '8px',
            'font-size': '16px',
            color: '#FFFFFF',
            'margin-bottom': '16px',
            display: 'flex',
            'align-items': 'center',
            gap: '10px',
          }}
        >
          <Show when={isAiLoading()}>
            <span>⏳</span>
          </Show>
          <span>{aiNotice()}</span>
        </div>
      </Show>

      {/* QR Code Phone Mode Modal */}
      <Show when={pairingActive() && qrOffer()}>
        <div
          style={{
            background: 'var(--buntu-slate)',
            padding: '24px',
            'border-radius': '16px',
            border: '2px solid var(--buntu-gold)',
            display: 'flex',
            'flex-direction': 'column',
            'align-items': 'center',
            gap: '16px',
            'margin-bottom': '20px',
          }}
        >
          <h3 style={{ 'font-size': '20px', margin: 0, color: 'var(--buntu-gold)' }}>
            Scannez pour écrire depuis votre smartphone
          </h3>
          <p style={{ color: 'var(--buntu-text-muted)', margin: 0, 'font-size': '16px' }}>
            Tapez votre recherche sur le téléphone : elle sera transmise automatiquement à la TV.
          </p>
          <div style={{ background: '#FFFFFF', padding: '12px', 'border-radius': '12px' }}>
            <canvas
              ref={(el) => {
                if (!el || !qrOffer()) return;
                const offer = qrOffer()!;
                const ctx = el.getContext('2d');
                if (!ctx) return;
                const size = offer.qrSize;
                const scale = 4;
                el.width = size * scale;
                el.height = size * scale;
                ctx.fillStyle = '#FFFFFF';
                ctx.fillRect(0, 0, el.width, el.height);
                ctx.fillStyle = '#000000';
                for (let r = 0; r < size; r++) {
                  for (let c = 0; c < size; c++) {
                    if (offer.qrModules[r * size + c] === '1') {
                      ctx.fillRect(c * scale, r * scale, scale, scale);
                    }
                  }
                }
              }}
            />
          </div>
          <button
            id="btn-search-close-qr"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-search-close-qr' ? 'focused' : ''}`}
            onClick={stopPairing}
          >
            Fermer l’appairage téléphone
          </button>
        </div>
      </Show>

      <div style={{ display: 'flex', flex: 1, 'overflow-y': 'hidden' }}>
        {/* On-Screen Keyboard */}
        <div style={{ width: '640px', 'margin-right': '32px', 'flex-shrink': 0 }} role="group" aria-label="Clavier virtuel">
          {/* Query input display */}
          <div
            style={{
              background: 'var(--buntu-slate)',
              padding: '14px 24px',
              'border-radius': '12px',
              'font-size': '24px',
              'font-weight': '700',
              border: '2px solid var(--buntu-border)',
              'margin-bottom': '20px',
              color: query() ? '#FFFFFF' : 'var(--buntu-text-muted)',
            }}
          >
            {query() || (mode() === 'ai' ? 'Décrivez ce que vous cherchez…' : 'Saisissez un titre ou une chaîne…')}
          </div>

          <For each={KEYBOARD_ROWS}>
            {(row) => (
              <div style={{ display: 'flex', 'margin-bottom': '8px', gap: '8px' }}>
                <For each={row}>
                  {(k) => {
                    const isSpecial = k.length > 1;
                    const isAi = k === 'RECHERCHER' && mode() === 'ai';
                    return (
                      <button
                        id={`key-${k}`}
                        tabindex="-1"
                        aria-label={`Touche ${k}`}
                        class={`tv-btn ${focusId() === `key-${k}` ? 'focused' : ''}`}
                        style={{
                          padding: isSpecial ? '12px 16px' : '12px 20px',
                          'font-size': isSpecial ? '15px' : '18px',
                          'min-width': isSpecial ? 'auto' : '52px',
                          color: isAi ? 'var(--buntu-gold)' : undefined,
                          'font-weight': isAi ? '700' : undefined,
                        }}
                        onClick={() => void handleKeyClick(k)}
                      >
                        {k === 'RECHERCHER' && mode() === 'ai' ? 'RECHERCHER ✨' : k}
                      </button>
                    );
                  }}
                </For>
              </div>
            )}
          </For>
        </div>

        {/* Search Results List */}
        <div role="list" aria-label="Résultats de recherche" class="tv-live-channels">
          <For each={results()}>
            {(res, idx) => {
              const cand = res.candidate;
              const candName = cand.name_clean && cand.name_clean !== cand.name ? cand.name_clean : cleanMediaTitle(cand.name).clean;
              const aiReason = res.aiReason;

              return (
                <div
                  id={`search-res-${idx()}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Résultat: ${candName}, catégorie ${cand.group_title || 'générale'}, type ${cand.kind}`}
                  class={`tv-channel-row ${focusId() === `search-res-${idx()}` ? 'focused' : ''}`}
                  onClick={() => props.onSelectResult(cand as any)}
                >
                  {/* Kind Badge */}
                  <div class="tv-channel-num" style={{ 'font-size': '14px', 'min-width': '80px' }}>
                    {cand.kind === 'live' ? 'DIRECT' : cand.kind === 'series' ? 'SÉRIE' : 'FILM'}
                  </div>

                  {/* Candidate Info */}
                  <div class="tv-channel-info">
                    <div class="tv-channel-name">{candName}</div>
                    <div class="tv-channel-meta">
                      {cand.group_title || 'Général'} • {cand.year || '2024'}
                      <Show when={aiReason}>
                        <span style={{ color: 'var(--buntu-gold)', 'margin-left': '12px' }}>✨ {aiReason}</span>
                      </Show>
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
              );
            }}
          </For>

          <Show when={results().length === 0 && query().trim().length > 0 && !isAiLoading()}>
            <div style={{ 'text-align': 'center', color: 'var(--buntu-text-muted)', padding: '48px 0', 'font-size': '20px' }}>
              Aucun résultat trouvé pour "{query()}" dans {selectedKind() === 'all' ? 'le catalogue' : selectedKind()}.
              <Show when={hasAi && mode() === 'local'}>
                <div style={{ 'margin-top': '12px', color: 'var(--buntu-gold)', 'font-size': '16px' }}>
                  Passez en mode « ✨ IA » pour chercher par description ou comparaison.
                </div>
              </Show>
            </div>
          </Show>
        </div>
      </div>
    </div>
  );
};
