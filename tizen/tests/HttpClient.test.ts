import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { HttpClient } from '../src/core/net/HttpClient';

describe('HttpClient - Single Connection & 429 Backoff', () => {
  let client: HttpClient;

  beforeEach(() => {
    client = HttpClient.getInstance();
    client.setSingleConnectionMode(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('respects single-connection mode and executes sequentially', async () => {
    let active = 0;
    let maxConcurrent = 0;

    const fakeFetch = vi.fn(
      (url: string | URL | Request) =>
        new Promise<Response>((resolve) => {
          active++;
          maxConcurrent = Math.max(maxConcurrent, active);
          setTimeout(() => {
            active--;
            resolve({
              status: 200,
              url: typeof url === 'string' ? url : 'http://fake/ok',
              headers: { forEach: () => {} },
              text: async () => '{"ok":true}',
            } as unknown as Response);
          }, 20);
        })
    );
    vi.stubGlobal('fetch', fakeFetch);

    // Simulate 3 concurrent queries
    await Promise.all([
      client.get('http://fake/1'),
      client.get('http://fake/2'),
      client.get('http://fake/3'),
    ]);

    expect(fakeFetch).toHaveBeenCalledTimes(3);
    expect(maxConcurrent).toBe(1);
    expect(client.isSingleConnectionMode()).toBe(true);
  });

  it('handles 429 backoff timer correctly', () => {
    expect(client.isRateLimited()).toBe(false);
    expect(client.getRateLimitSecondsRemaining()).toBe(0);
  });
});

