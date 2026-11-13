import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { LiveView } from '../src/features/live/LiveView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { Database } from '../src/core/storage/Database';
import { screenState } from '../src/core/navigation/ScreenState';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 300)); };
let dispose = () => {};
const channel = (id: number) => ({ id, source_id: 1, stable_hash: `h${id}`, kind: 'live', name: `Chaîne ${id}`, name_clean: `Chaîne ${id}`, group_title: 'TV', tvg_id: '', stream_url: `http://x.invalid/live/u/p/${id}.ts`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0 }) as any;
let play: any;

beforeEach(() => {
  screenState.clear();
  RemoteKeyHandler.getInstance().init();
  (spatialNav as any).isInitialized = false;
  spatialNav.init();
  spatialNav.setHeader([]);
  const engine = CndEngine.getInstance() as any;
  vi.spyOn(engine, 'getCategories').mockResolvedValue(['TV']);
  vi.spyOn(engine, 'getCategoryCounts').mockResolvedValue({ total: 2, favCount: 0, counts: { TV: 2 } });
  vi.spyOn(engine, 'getRecentItems').mockResolvedValue([channel(1)]);
  vi.spyOn(engine, 'getFavoritesByKind').mockResolvedValue([]);
  vi.spyOn(engine, 'countCatalog').mockResolvedValue(2);
  vi.spyOn(engine, 'getCatalog').mockResolvedValue([channel(1), channel(2)]);
  vi.spyOn(engine, 'stopPlayback').mockImplementation(() => {});
  vi.spyOn(engine, 'recordRecent').mockImplementation(() => {});
  play = vi.spyOn(engine, 'play').mockResolvedValue(undefined);
  const db = Database.getInstance() as any;
  for (const name of ['getEpgNowNext', 'getEpgUpcoming']) vi.spyOn(db, name).mockResolvedValue(name === 'getEpgUpcoming' ? [] : {});
  vi.spyOn(db, 'onBrokenChange').mockReturnValue(() => {});
});
afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); screenState.clear(); vi.restoreAllMocks(); });

describe('Live TV: the mini player after the full-screen player', () => {
  it('opening Live TV resumes the channel watched last, as before', async () => {
    dispose = render(() => LiveView({ onPlayChannel: vi.fn(), onAddSource: vi.fn() }), document.body);
    await settle();
    expect(play).toHaveBeenCalledTimes(1);
    expect(play.mock.calls[0][0].id).toBe(1);
  });

  it('coming back from the full-screen player does NOT start the channel again: it stays stopped', async () => {
    screenState.save('live', { category: '', viewMode: 'grid', focusId: '', scrollTop: 0, snapshot: undefined } as any);
    screenState.arm('live');
    dispose = render(() => LiveView({ onPlayChannel: vi.fn(), onAddSource: vi.fn() }), document.body);
    await settle();
    expect(play).not.toHaveBeenCalled();
  });
});
