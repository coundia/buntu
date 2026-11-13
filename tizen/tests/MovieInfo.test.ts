import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CndEngine } from '../src/core/engine/CndEngine';
import { HttpClient } from '../src/core/net/HttpClient';
import { ItemRecord } from '../src/core/storage/Database';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';

const movie = (url: string, id = 1): ItemRecord => ({
  id, source_id: 1, stable_hash: `h${id}`, kind: 'movie', name: 'Film', name_clean: 'Film',
  stream_url: url, is_favorite: 0, playback_position_ms: 0, duration_ms: 0,
});

describe('Film facts from the provider', () => {
  let get: any;
  let omdbKey: any;
  const engine = CndEngine.getInstance();
  beforeEach(() => {
    vi.spyOn(engine as any, 'localItem').mockImplementation(async (i: unknown) => i);
    get = vi.spyOn(HttpClient.getInstance(), 'get');
    omdbKey = vi.spyOn(AiKeyStore.getInstance(), 'getApiKey').mockResolvedValue(null);
  });
  afterEach(() => { vi.restoreAllMocks(); (engine as any).movieInfoCache.clear(); });

  it('reads the facts of an Xtream film and asks the provider once', async () => {
    get.mockResolvedValue({ data: { info: {
      plot: ' Un récit. ', genre: 'Drame', cast: 'A, B', director: 'C', releasedate: '2021-05-04',
      rating: '7.4', duration_secs: 5400, country: 'FR', age: 'N/A',
    } } } as any);
    const item = movie('http://srv.invalid:8080/movie/user/pass/321.mkv');
    const info = await engine.getMovieInfo(item);
    expect(info).toEqual({
      plot: 'Un récit.', genre: 'Drame', cast: 'A, B', director: 'C', releaseDate: '2021-05-04',
      rating: 7.4, durationMs: 5400000, country: 'FR', age: undefined,
    });
    expect(String(get.mock.calls[0][0])).toContain('action=get_vod_info&vod_id=321');
    await engine.getMovieInfo(item);
    expect(get).toHaveBeenCalledTimes(1);
  });

  it('has nothing for a playlist film, a live channel, or a provider with no facts', async () => {
    expect(await engine.getMovieInfo(movie('http://cdn.invalid/video.mp4', 2))).toBeNull();
    expect(await engine.getMovieInfo({ ...movie('http://srv.invalid/movie/u/p/5.mp4', 3), kind: 'live' })).toBeNull();
    expect(get).not.toHaveBeenCalled();
    get.mockResolvedValue({ data: { info: { plot: '', genre: 'N/A' } } } as any);
    expect(await engine.getMovieInfo(movie('http://srv.invalid/movie/u/p/6.mp4', 4))).toBeNull();
  });

  it('a network failure gives nothing and is tried again next time', async () => {
    get.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ data: { info: { genre: 'Action' } } } as any);
    const item = movie('http://srv.invalid/movie/u/p/7.mp4', 5);
    expect(await engine.getMovieInfo(item)).toBeNull();
    expect((await engine.getMovieInfo(item))?.genre).toBe('Action');
  });

  it('completes the missing facts with OMDb when the household shared its key, the provider winning', async () => {
    omdbKey.mockResolvedValue('test-only-value');
    get.mockImplementation(async (url: string) => url.includes('omdbapi.com')
      ? { data: { Response: 'True', Plot: 'Résumé OMDb', Genre: 'Action, Drame', Actors: 'X, Y', Director: 'Z', imdbRating: '8.1', Released: '10 Jul 2010', Runtime: '148 min', Country: 'USA', Rated: 'PG-13' } }
      : { data: { info: { plot: 'Résumé du fournisseur', rating: '6.0' } } });
    const info = await engine.getMovieInfo(movie('http://srv.invalid/movie/u/p/8.mkv', 6));
    expect(info?.plot).toBe('Résumé du fournisseur');
    expect(info?.rating).toBe(6);
    expect(info?.genre).toBe('Action, Drame');
    expect(info?.cast).toBe('X, Y');
    expect(info?.durationMs).toBe(148 * 60000);
    expect(info?.age).toBe('PG-13');
    const omdbUrl = String(get.mock.calls.map((c: any[]) => c[0]).find((u: string) => u.includes('omdbapi.com')));
    expect(omdbUrl).toContain('t=Film');
    expect(omdbUrl).toContain('apikey=test-only-value');
  });

  it('gives OMDb facts to a playlist film (no provider info), and nothing is asked without a key', async () => {
    omdbKey.mockResolvedValue('test-only-value');
    get.mockResolvedValue({ data: { Response: 'True', Plot: 'Résumé OMDb' } } as any);
    expect((await engine.getMovieInfo(movie('http://cdn.invalid/film.mp4', 7)))?.plot).toBe('Résumé OMDb');
    get.mockClear();
    omdbKey.mockResolvedValue(null);
    expect(await engine.getMovieInfo(movie('http://cdn.invalid/autre.mp4', 8))).toBeNull();
    expect(get).not.toHaveBeenCalled();
  });

  it('an unknown film on OMDb leaves the provider facts alone', async () => {
    omdbKey.mockResolvedValue('test-only-value');
    get.mockImplementation(async (url: string) => url.includes('omdbapi.com')
      ? { data: { Response: 'False', Error: 'Movie not found!' } }
      : { data: { info: { genre: 'Drame' } } });
    expect((await engine.getMovieInfo(movie('http://srv.invalid/movie/u/p/9.mkv', 9)))).toEqual({ genre: 'Drame' });
  });
});
