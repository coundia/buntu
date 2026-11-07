import { describe, it, expect, vi } from 'vitest';
import { createInfiniteScroller } from '../src/core/pagination/InfiniteScrollController';

describe('InfiniteScrollController (SRP Architecture)', () => {
  it('initializes with empty items and zero total', () => {
    const scroller = createInfiniteScroller<string>({
      pageSize: 10,
      fetchBatch: async () => ({ items: [], total: 0 }),
    });

    expect(scroller.items()).toEqual([]);
    expect(scroller.total()).toBe(0);
    expect(scroller.isLoading()).toBe(false);
    expect(scroller.hasMore()).toBe(false);
  });

  it('reset() loads page 1 and sets total count', async () => {
    const batchSpy = vi.fn().mockResolvedValue({
      items: ['item1', 'item2', 'item3'],
      total: 30,
    });

    const scroller = createInfiniteScroller<string>({
      pageSize: 3,
      fetchBatch: batchSpy,
    });

    await scroller.reset();

    expect(batchSpy).toHaveBeenCalledWith(0, 3);
    expect(scroller.items()).toEqual(['item1', 'item2', 'item3']);
    expect(scroller.total()).toBe(30);
    expect(scroller.hasMore()).toBe(true);
    expect(scroller.isLoading()).toBe(false);
  });

  it('checkTrigger() triggers loadMore() only when approaching the threshold', async () => {
    let callCount = 0;
    const scroller = createInfiniteScroller<string>({
      pageSize: 5,
      threshold: 2,
      fetchBatch: async (offset) => {
        callCount++;
        return {
          items: Array.from({ length: 5 }, (_, i) => `item-${offset + i}`),
          total: 20,
        };
      },
    });

    await scroller.reset();
    expect(scroller.items().length).toBe(5);
    expect(callCount).toBe(1);

    // Item 0 is far from the end (5 - 2 = 3), should NOT trigger
    const triggeredFar = await scroller.checkTrigger(0);
    expect(triggeredFar).toBe(false);
    expect(callCount).toBe(1);

    // Item 3 is at the threshold (index 3 >= 5 - 2), should trigger next batch
    const triggeredNear = await scroller.checkTrigger(3);
    expect(triggeredNear).toBe(true);
    expect(callCount).toBe(2);
    expect(scroller.items().length).toBe(10);
  });

  it('prevents concurrent duplicate fetches while loading', async () => {
    let resolvePromise: (val: any) => void;
    const pendingPromise = new Promise((resolve) => {
      resolvePromise = resolve;
    });

    const fetchSpy = vi.fn().mockImplementation(() => pendingPromise);

    const scroller = createInfiniteScroller<string>({
      pageSize: 5,
      fetchBatch: fetchSpy,
    });

    scroller.setItems(['a', 'b', 'c', 'd', 'e'], 20);

    // Start first loadMore (in flight)
    const p1 = scroller.loadMore();
    expect(scroller.isLoading()).toBe(true);

    // Second loadMore called while p1 is in flight
    const p2 = scroller.loadMore();
    expect(await p2).toBe(false);

    // Resolve first batch
    resolvePromise!({ items: ['f', 'g'], total: 20 });
    expect(await p1).toBe(true);
    expect(scroller.items().length).toBe(7);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it('enforces maxItems bound to protect Smart TV RAM', async () => {
    const scroller = createInfiniteScroller<number>({
      pageSize: 5,
      maxItems: 8, // Cap at 8 items
      fetchBatch: async (offset) => ({
        items: [offset, offset + 1, offset + 2, offset + 3, offset + 4],
        total: 100,
      }),
    });

    await scroller.reset(); // loads 5 items (0..4)
    expect(scroller.items().length).toBe(5);

    await scroller.loadMore(); // loads 5 more, but capped at 8!
    expect(scroller.items().length).toBe(8);
  });
});

