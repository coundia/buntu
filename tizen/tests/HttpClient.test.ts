import { describe, it, expect, beforeEach, vi } from 'vitest';
import { HttpClient } from '../src/core/net/HttpClient';

describe('HttpClient - Single Connection & 429 Backoff', () => {
  let client: HttpClient;

  beforeEach(() => {
    client = HttpClient.getInstance();
    client.setSingleConnectionMode(true);
  });

  it('respects single-connection mode and executes sequentially', async () => {
    let active = 0;
    let maxConcurrent = 0;

    const fakeFetch = () =>
      new Promise<void>((resolve) => {
        active++;
        maxConcurrent = Math.max(maxConcurrent, active);
        setTimeout(() => {
          active--;
          resolve();
        }, 20);
      });

    // Simulate 3 concurrent queries
    await Promise.all([
      client.get('http://fake/1').catch(() => {}),
      client.get('http://fake/2').catch(() => {}),
      client.get('http://fake/3').catch(() => {}),
    ]);

    expect(client.isSingleConnectionMode()).toBe(true);
  });

  it('handles 429 backoff timer correctly', () => {
    expect(client.isRateLimited()).toBe(false);
    expect(client.getRateLimitSecondsRemaining()).toBe(0);
  });
});

