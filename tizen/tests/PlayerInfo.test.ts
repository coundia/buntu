import { describe, it, expect, vi, afterEach } from 'vitest';
import { createRoot } from 'solid-js';
import { createPlayerInfo } from '../src/features/player/playerInfo';
import type { EpgProgramRecord, ItemRecord } from '../src/core/storage/Database';
import { summarizeStream } from '../src/core/player/streamInfo';

const program = (id: number, start: number, end: number, title: string): EpgProgramRecord => ({
  id, source_id: 1, channel_tvg_id: 'rts1.sn', title, start_ts: start, end_ts: end,
});

const channel = { id: 7, kind: 'live', tvg_id: 'rts1.sn', is_favorite: 0 } as unknown as ItemRecord;
const film = { id: 9, kind: 'movie', is_favorite: 1 } as unknown as ItemRecord;

function setup(item: ItemRecord, programs: EpgProgramRecord[] = []) {
  const db = { getEpgUpcoming: vi.fn(async () => programs) };
  const engine = { toggleFavorite: vi.fn(async () => true) };
  let summary: ReturnType<typeof summarizeStream> = null;
  const player = { getStreamSummary: vi.fn(() => summary) };
  let dispose = () => {};
  const info = createRoot((d) => {
    dispose = d;
    return createPlayerInfo(() => item, { player, db, engine });
  });
  return { info, db, engine, player, setSummary: (s: typeof summary) => (summary = s), dispose };
}

afterEach(() => vi.useRealTimers());

describe('player info', () => {
  it('loads the program guide of a channel', async () => {
    const now = Math.floor(Date.now() / 1000);
    const { info, db, dispose } = setup(channel, [program(1, now - 600, now + 600, 'Journal'), program(2, now + 600, now + 4200, 'Série')]);
    await vi.waitFor(() => expect(info.epg().length).toBe(2));
    expect(db.getEpgUpcoming).toHaveBeenCalledWith('rts1.sn', expect.any(Number), 4);
    expect(info.epg()[0].title).toBe('Journal');
    dispose();
  });

  it('has no guide for a film and does not query it', async () => {
    const { info, db, dispose } = setup(film);
    await new Promise((r) => setTimeout(r, 20));
    expect(info.epg()).toEqual([]);
    expect(db.getEpgUpcoming).not.toHaveBeenCalled();
    dispose();
  });

  it('starts from the favorite flag of the item and toggles it', async () => {
    const { info, engine, dispose } = setup(channel);
    expect(info.isFavorite()).toBe(false);
    expect(await info.toggleFavorite()).toBe(true);
    expect(engine.toggleFavorite).toHaveBeenCalledWith(7);
    expect(info.isFavorite()).toBe(true);
    expect(channel.is_favorite).toBe(1); // the record is updated for the lists
    dispose();
    expect(setup(film).info.isFavorite()).toBe(true);
  });

  it('picks up the stream facts once the TV knows them, and shows the clock', async () => {
    vi.useFakeTimers();
    const { info, setSummary, dispose } = setup(film);
    expect(info.stream()).toBeNull();
    setSummary(summarizeStream([{ type: 'VIDEO', extra_info: '{"fourCC":"video/x-h264","Width":"1920","Height":"1080"}' }]));
    vi.advanceTimersByTime(1600);
    expect(info.stream()?.quality).toBe('FHD');
    expect(info.clock()).toMatch(/^\d{2}:\d{2}$/);
    dispose();
  });
});
