import { describe, it, expect, vi, beforeEach } from 'vitest';
import { CndEngine } from '../src/core/engine/CndEngine';
import { HttpClient } from '../src/core/net/HttpClient';
import { ItemRecord } from '../src/core/storage/Database';

describe('Series Details & Episodes Controller', () => {
  let engine: CndEngine;

  beforeEach(() => {
    engine = CndEngine.getInstance();
  });

  it('correctly maps Xtream series API response into seasons and episodes', async () => {
    const mockApiResponse = {
      info: {
        name: 'Loki',
        cover: 'http://cdn.iptv.tv/loki_cover.jpg',
        plot: 'Le dieu de la malice après Avengers Endgame.',
        genre: 'Sci-Fi / Marvel',
        rating: '8.4',
        releaseDate: '2021-06-09',
      },
      seasons: [
        { season_number: 1, name: 'Saison 1', overview: 'Voyage dans le TVA' },
        { season_number: 2, name: 'Saison 2', overview: 'La toile temporelle' },
      ],
      episodes: {
        '1': [
          {
            id: '101',
            episode_num: 1,
            title: 'Un destin grandiose',
            container_extension: 'mkv',
            info: {
              plot: 'Loki arrive au TVA.',
              duration: '51 min',
              duration_secs: 3060,
              movie_image: 'http://cdn.iptv.tv/loki_s1e1.jpg',
            },
          },
          {
            id: '102',
            episode_num: 2,
            title: 'Le Variant',
            container_extension: 'mkv',
            info: {
              plot: 'À la poursuite de Sylvie.',
              duration: '54 min',
            },
          },
        ],
        '2': [
          {
            id: '201',
            episode_num: 1,
            title: 'Ouroboros',
            container_extension: 'mkv',
            info: {
              plot: 'Le glissement temporel.',
              duration: '48 min',
            },
          },
        ],
      },
    };

    vi.spyOn(HttpClient.getInstance(), 'get').mockResolvedValueOnce({
      status: 200,
      headers: {},
      data: mockApiResponse,
    } as any);

    const seriesItem: ItemRecord = {
      id: 99,
      source_id: 1,
      stable_hash: 'series_loki_99',
      kind: 'series',
      name: 'EN - Loki (2021)',
      name_clean: 'Loki',
      stream_url: 'xtream-series://http%3A%2F%2Fiptv.com%3A8080|user1|pass1|777',
      is_favorite: 0,
      playback_position_ms: 0,
      duration_ms: 0,
    };

    const details = await engine.getSeriesDetails(seriesItem);

    expect(details.info.title).toBe('Loki');
    expect(details.info.rating).toBe(8.4);
    expect(details.seasons).toHaveLength(2);

    // Season 1 verification
    const s1 = details.seasons[0];
    expect(s1.season_num).toBe(1);
    expect(s1.name).toBe('Saison 1');
    expect(s1.episodes).toHaveLength(2);

    expect(s1.episodes[0].id).toBe('101');
    expect(s1.episodes[0].episode_num).toBe(1);
    expect(s1.episodes[0].title).toBe('Un destin grandiose');
    expect(s1.episodes[0].stream_url).toBe('http://iptv.com:8080/series/user1/pass1/101.mkv');
    expect(s1.episodes[0].duration).toBe('51 min');
    expect(s1.episodes[0].cover).toBe('http://cdn.iptv.tv/loki_s1e1.jpg');

    // Season 2 verification
    const s2 = details.seasons[1];
    expect(s2.season_num).toBe(2);
    expect(s2.episodes).toHaveLength(1);
    expect(s2.episodes[0].title).toBe('Ouroboros');
    expect(s2.episodes[0].stream_url).toBe('http://iptv.com:8080/series/user1/pass1/201.mkv');
  });

  it('provides a structured 1-season fallback for non-Xtream series', async () => {
    const rawSeries: ItemRecord = {
      id: 50,
      source_id: 1,
      stable_hash: 'm3u_series_50',
      kind: 'series',
      name: 'Breaking Bad',
      name_clean: 'Breaking Bad',
      stream_url: 'http://cdn.example.com/bb.mp4',
      is_favorite: 0,
      playback_position_ms: 0,
      duration_ms: 0,
      season_num: 1,
      episode_num: 1,
    };

    const details = await engine.getSeriesDetails(rawSeries);
    expect(details.info.title).toBe('Breaking Bad');
    expect(details.seasons).toHaveLength(1);
    expect(details.seasons[0].episodes).toHaveLength(1);
    expect(details.seasons[0].episodes[0].stream_url).toBe('http://cdn.example.com/bb.mp4');
  });
});
