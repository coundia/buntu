import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render } from 'solid-js/web';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';
import { setWasmSource } from '../src/worker/handlers';
import { LiveView } from '../src/features/live/LiveView';
import { screenState } from '../src/core/navigation/ScreenState';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { channelFamily, liveFeatures, liveTaste, pickRecommendedChannels } from '../src/core/engine/liveRecommendations';

const ch = (id: number, name: string, group: string, over: Record<string, unknown> = {}) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'live', name, name_clean: name, group_title: group, tvg_id: '',
  stream_url: `http://x.invalid/live/u/p/${id}.ts`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('Channel features and taste', () => {
  it('the HD and SD copies of a channel are one family', () => {
    expect(channelFamily('TF1 HD')).toBe('tf1');
    expect(channelFamily('TF1 FHD [FR]')).toBe('tf1');
    expect(channelFamily('  France   2 ')).toBe('france 2');
  });

  it('features are the channel family and its category', () => {
    expect(liveFeatures(ch(1, 'Canal+ Sport HD', 'FR | Sport'))).toEqual(['channel:canal+ sport', 'group:fr | sport']);
  });

  it('recent channels count less and less, favourites more, strongest scaled to 1', () => {
    const taste = liveTaste([ch(1, 'A', 'Sport'), ch(2, 'B', 'Info')], [ch(3, 'C', 'Sport')]);
    expect(taste.samples).toBe(3);
    expect(Math.max(...Object.values(taste.weights))).toBe(1);
    expect(taste.weights['group:sport']).toBeGreaterThan(taste.weights['group:info']);
    expect(liveTaste([], []).samples).toBe(0);
  });

  it('picks one per family, never a known, broken or unscored channel', () => {
    const pool = new Map([
      [1, ch(1, 'Eurosport HD', 'Sport')],
      [2, ch(2, 'Eurosport SD', 'Sport')],
      [3, ch(3, 'Canal Sport', 'Sport', { is_broken: 1 })],
      [4, ch(4, 'Known', 'Sport')],
      [5, ch(5, 'Autre', 'Sport')],
      [6, ch(6, 'Zéro', 'Sport')],
    ]);
    const scored = [1, 2, 3, 4, 5, 6].map((id) => ({ item: { id }, score: id === 6 ? 0 : 10 - id }));
    const out = pickRecommendedChannels(scored, pool, new Set([4]), new Set(['known']), 5);
    expect(out.map((c) => c.id)).toEqual([1, 5]);
  });
});

describe('CndEngine.getRecommendedChannels (shared WebAssembly scoring)', () => {
  const engine = CndEngine.getInstance() as any;
  beforeEach(() => setWasmSource(readFileSync(resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm'))));
  afterEach(() => vi.restoreAllMocks());

  it('proposes unseen channels of the categories the viewer watches, first', async () => {
    vi.spyOn(engine, 'visibleRecents').mockResolvedValue([ch(1, 'RMC Sport 1', 'Sport')]);
    vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
    vi.spyOn(engine, 'getCatalog').mockImplementation((async (_k: string, group?: string) =>
      group === 'Sport'
        ? [ch(1, 'RMC Sport 1', 'Sport'), ch(2, 'Eurosport', 'Sport'), ch(3, 'Canal Sport', 'Sport')]
        : [ch(4, 'Arte', 'Culture'), ch(1, 'RMC Sport 1', 'Sport')]) as any);
    const out = await engine.getRecommendedChannels(5);
    expect(out.map((c: any) => c.id).slice(0, 2).sort()).toEqual([2, 3]);
    expect(out.map((c: any) => c.id)).not.toContain(1);
  });

  it('proposes nothing without recent channel or favourite, and never throws', async () => {
    vi.spyOn(engine, 'visibleRecents').mockResolvedValue([]);
    vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
    expect(await engine.getRecommendedChannels()).toEqual([]);
    vi.spyOn(engine, 'visibleRecents').mockRejectedValue(new Error('db'));
    expect(await engine.getRecommendedChannels()).toEqual([]);
  });
});

describe('Live TV: « Recommandé pour vous » shelf', () => {
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 300)); };
  let dispose = () => {};
  beforeEach(() => {
    screenState.clear();
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
    const engine = CndEngine.getInstance() as any;
    vi.spyOn(engine, 'getCategories').mockResolvedValue(['Sport']);
    vi.spyOn(engine, 'getCategoryCounts').mockResolvedValue({ total: 3, favCount: 0, counts: { Sport: 3 } });
    vi.spyOn(engine, 'getRecentItems').mockResolvedValue([ch(1, 'RMC Sport 1', 'Sport')]);
    vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
    vi.spyOn(engine, 'countCatalog').mockResolvedValue(3);
    vi.spyOn(engine, 'getCatalog').mockResolvedValue([ch(1, 'RMC Sport 1', 'Sport'), ch(2, 'Eurosport', 'Sport'), ch(3, 'Canal Sport', 'Sport')]);
    vi.spyOn(engine, 'getRecommendedChannels').mockResolvedValue([ch(2, 'Eurosport', 'Sport'), ch(3, 'Canal Sport', 'Sport')]);
    vi.spyOn(engine, 'play').mockResolvedValue(undefined);
    vi.spyOn(engine, 'stopPlayback').mockImplementation(() => {});
    vi.spyOn(engine, 'recordRecent').mockImplementation(() => {});
    const db = Database.getInstance() as any;
    vi.spyOn(db, 'getEpgNowNext').mockResolvedValue({});
    vi.spyOn(db, 'getEpgUpcoming').mockResolvedValue([]);
    vi.spyOn(db, 'onBrokenChange').mockReturnValue(() => {});
  });
  afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); screenState.clear(); vi.restoreAllMocks(); });

  it('shows the recommended channels as a shelf the remote can reach', async () => {
    dispose = render(() => LiveView({ onPlayChannel: vi.fn(), onAddSource: vi.fn() }), document.body);
    await settle();
    expect(document.body.textContent).toContain('Recommandé pour vous');
    expect(document.getElementById('rec-ch-2')).not.toBeNull();
    expect(document.getElementById('rec-ch-3')).not.toBeNull();
    spatialNav.setFocusById('rec-ch-2');
    expect(spatialNav.getCurrentFocusId()).toBe('rec-ch-2');
  });

  it('no shelf when there is nothing to recommend', async () => {
    (CndEngine.getInstance() as any).getRecommendedChannels.mockResolvedValue([]);
    dispose = render(() => LiveView({ onPlayChannel: vi.fn(), onAddSource: vi.fn() }), document.body);
    await settle();
    expect(document.body.textContent).not.toContain('Recommandé pour vous');
  });
});
