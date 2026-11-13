import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { CndEngine } from '../src/core/engine/CndEngine';
import { setWasmSource } from '../src/worker/handlers';
import { isFinished, movieFeatures, pickSimilar, tasteOf } from '../src/core/engine/similarMovies';

const film = (id: number, over: Record<string, unknown> = {}) => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: `Film ${id}`, name_clean: `Film ${id}`,
  group_title: 'Action', year: 2010, stream_url: `http://x.invalid/movie/u/p/${id}.mkv`, is_favorite: 0,
  playback_position_ms: 0, duration_ms: 0, ...over,
}) as any;

describe('Features of a film (same names as the other platforms)', () => {
  it('group, decade, and the facts the provider gave', () => {
    expect(movieFeatures(film(1, { group_title: '  Action   Film ', year: 2014 }), { genre: 'Drame, Action', director: 'C', cast: 'A, B, X, Y' })).toEqual([
      'genre:drame', 'genre:action', 'director:c', 'actor:a', 'actor:b', 'actor:x', 'decade:2010', 'group:action film',
    ]);
    expect(movieFeatures(film(2, { group_title: undefined, year: undefined, name: 'Sans année' }))).toEqual([]);
  });

  it('every feature of the film counts the same in the taste', () => {
    expect(tasteOf(['group:a', 'decade:2010'])).toEqual({ weights: { 'group:a': 1, 'decade:2010': 1 }, samples: 1 });
    expect(tasteOf([]).samples).toBe(0);
  });

  it('a film left at 95 % or more is finished', () => {
    expect(isFinished(film(1, { duration_ms: 100, playback_position_ms: 96 }))).toBe(true);
    expect(isFinished(film(1, { duration_ms: 100, playback_position_ms: 50 }))).toBe(false);
    expect(isFinished(film(1))).toBe(false);
  });

  it('picks the best scored first, never the film itself nor a finished one', () => {
    const byId = new Map([1, 2, 3, 4].map((id) => [id, film(id, id === 3 ? { duration_ms: 100, playback_position_ms: 99 } : {})]));
    const scored = [4, 3, 2, 1].map((id, i) => ({ item: { id }, score: 10 - i }));
    expect(pickSimilar(scored, byId, 1, 5).map((i) => i.id)).toEqual([4, 2]);
    expect(pickSimilar(scored, byId, 1, 1).map((i) => i.id)).toEqual([4]);
  });
});

describe('CndEngine.getSimilarMovies (shared WebAssembly scoring)', () => {
  const engine = CndEngine.getInstance() as any;
  beforeEach(() => {
    setWasmSource(readFileSync(resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm')));
    vi.spyOn(engine, 'getMovieInfo').mockResolvedValue(null);
  });
  afterEach(() => vi.restoreAllMocks());

  it('puts the same category and decade first and leaves out the film being watched', async () => {
    const current = film(1, { group_title: 'Action', year: 2010 });
    const sameCategory = film(2, { group_title: 'Action', year: 2011 });
    const sameDecadeOnly = film(3, { group_title: 'Drame', year: 2012 });
    const unrelated = film(4, { group_title: 'Comédie', year: 1985 });
    vi.spyOn(engine, 'getCatalog').mockImplementation((async (_k: string, group?: string) =>
      group === 'Action' ? [current, sameCategory] : [current, unrelated, sameDecadeOnly, sameCategory]) as any);
    const similar = await engine.getSimilarMovies(current, 5);
    expect(similar.map((f: any) => f.id)).toEqual([2, 3, 4]);
  });

  it('gives nothing for a series, a channel, or when the catalogue has no other film', async () => {
    expect(await engine.getSimilarMovies(film(1, { kind: 'live' }))).toEqual([]);
    vi.spyOn(engine, 'getCatalog').mockResolvedValue([film(1)]);
    expect(await engine.getSimilarMovies(film(1))).toEqual([]);
  });

  it('an error in the scoring never breaks the player: empty list', async () => {
    vi.spyOn(engine, 'getCatalog').mockRejectedValue(new Error('db'));
    expect(await engine.getSimilarMovies(film(1))).toEqual([]);
  });
});
