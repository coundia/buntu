import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { PlayerView } from '../src/features/player/PlayerView';
import { CndEngine } from '../src/core/engine/CndEngine';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AVPlayerService } from '../src/core/player/AVPlayerService';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 60)); };
const key = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));
const film = (id: number, over: Record<string, unknown> = {}) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: `Film ${id}`, name_clean: `Film ${id}`, group_title: 'Action', year: 2010,
  stream_url: `http://x.invalid/movie/u/p/${id}.mkv`, is_favorite: 0, playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;
let dispose = () => {};
let listener: any = null;

beforeEach(() => {
  RemoteKeyHandler.getInstance().init();
  (spatialNav as any).isInitialized = false;
  spatialNav.init();
  spatialNav.setHeader([]);
  const player = AVPlayerService.getInstance() as any;
  vi.spyOn(player, 'setListener').mockImplementation((l: any) => { listener = l; });
  for (const name of ['setDisplayArea', 'stop', 'play', 'seekTo', 'open']) vi.spyOn(player, name).mockImplementation(() => {});
  vi.spyOn(player, 'getDuration').mockReturnValue(100_000);
  vi.spyOn(player, 'getCurrentTime').mockReturnValue(0);
  vi.spyOn(player, 'getStreamSummary').mockReturnValue(null);
  const engine = CndEngine.getInstance() as any;
  vi.spyOn(engine, 'getSimilarMovies').mockResolvedValue([film(2, { imdb_rating: 7.4 }), film(3)]);
  vi.spyOn(LocalSyncService.getInstance(), 'broadcastProgress').mockResolvedValue(undefined as any);
  vi.spyOn(engine, 'saveProgress').mockResolvedValue(undefined);
  vi.spyOn(engine, 'takeResumed').mockReturnValue(false);
});
afterEach(() => { dispose(); document.body.innerHTML = ''; RemoteKeyHandler.getInstance().destroy(); vi.restoreAllMocks(); });

describe('Player: « À suivre » shelf of similar films', () => {
  it('shows similar films under the controls and plays the chosen one next', async () => {
    const onPlayNext = vi.fn();
    dispose = render(() => PlayerView({ item: film(1), onExit: vi.fn(), onPlayNext }), document.body);
    await settle();
    expect(document.body.textContent).toContain('À SUIVRE');
    const cards = [...document.querySelectorAll('.tv-osd-next-card')];
    expect(cards.map((c) => c.id)).toEqual(['player-next-2', 'player-next-3']);
    expect(cards[0].textContent).toContain('Film 2');
    expect(cards[0].textContent).toContain('★ 7.4');
    // DOWN from the controls reaches the shelf, OK plays that film.
    spatialNav.setFocusById('btn-osd-play-pause');
    key(40);
    expect(spatialNav.getCurrentFocusId()).toBe('player-next-2');
    key(39);
    expect(spatialNav.getCurrentFocusId()).toBe('player-next-3');
    key(13);
    expect(onPlayNext).toHaveBeenCalledWith(expect.objectContaining({ id: 3 }));
  });

  it('shows no shelf for a channel, and none when nothing is similar', async () => {
    dispose = render(() => PlayerView({ item: film(5, { kind: 'live' }), onExit: vi.fn() }), document.body);
    await settle();
    expect(document.querySelector('.tv-osd-next')).toBeNull();
    dispose();
    document.body.innerHTML = '';
    (CndEngine.getInstance() as any).getSimilarMovies.mockResolvedValue([]);
    dispose = render(() => PlayerView({ item: film(1), onExit: vi.fn() }), document.body);
    await settle();
    expect(document.querySelector('.tv-osd-next')).toBeNull();
  });

  it('when the film is ending, the shelf comes up by itself with the cursor on the first suggestion', async () => {
    dispose = render(() => PlayerView({ item: film(1), onExit: vi.fn(), onPlayNext: vi.fn() }), document.body);
    await settle();
    spatialNav.setFocusById('btn-osd-play-pause');
    listener.onCurrentPlayTime(50_000); // half way: nothing special
    expect(spatialNav.getCurrentFocusId()).toBe('btn-osd-play-pause');
    listener.onCurrentPlayTime(98_000); // 98 %
    await settle();
    expect(spatialNav.getCurrentFocusId()).toBe('player-next-2');
    expect(document.querySelector('.tv-osd-next')).not.toBeNull();
  });
});

