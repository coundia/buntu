/**
 * CND IPTV Tizen - Infinite Scroll Controller (Single Responsibility Principle)
 *
 * Responsibilities:
 * 1. Manages reactive accumulation of paginated data.
 * 2. Triggers asynchronous fetching when approaching the threshold.
 * 3. Enforces concurrency protection (prevents redundant/overlapping fetches).
 * 4. Limits in-memory item count to protect low-RAM Smart TV platforms (< 150MB limit).
 */

import { createSignal, Accessor } from 'solid-js';

export interface InfiniteScrollOptions<T> {
  pageSize: number;
  threshold?: number;
  maxItems?: number;
  fetchBatch: (offset: number, limit: number) => Promise<{ items: T[]; total: number }>;
  onBatchLoaded?: (items: T[], total: number) => void;
}

export interface InfiniteScroller<T> {
  items: Accessor<T[]>;
  total: Accessor<number>;
  isLoading: Accessor<boolean>;
  hasMore: Accessor<boolean>;
  checkTrigger: (index: number) => Promise<boolean>;
  loadMore: () => Promise<boolean>;
  reset: () => Promise<void>;
  setItems: (items: T[], total: number) => void;
}

export function createInfiniteScroller<T>(options: InfiniteScrollOptions<T>): InfiniteScroller<T> {
  const [items, setItemsSignal] = createSignal<T[]>([]);
  const [total, setTotal] = createSignal<number>(0);
  const [isLoading, setIsLoading] = createSignal<boolean>(false);

  const threshold = options.threshold ?? 8;
  const maxItems = options.maxItems ?? 300;

  const hasMore = () => items().length < total();

  const loadMore = async (): Promise<boolean> => {
    if (isLoading() || !hasMore()) {
      return false;
    }

    setIsLoading(true);
    try {
      const currentOffset = items().length;
      const result = await options.fetchBatch(currentOffset, options.pageSize);

      setTotal(result.total);

      const combined = [...items(), ...result.items];
      const bounded = combined.length > maxItems ? combined.slice(0, maxItems) : combined;

      setItemsSignal(bounded);
      options.onBatchLoaded?.(bounded, result.total);
      return true;
    } catch (err) {
      console.error('[InfiniteScroller] Failed to fetch batch:', err);
      return false;
    } finally {
      setIsLoading(false);
    }
  };

  const checkTrigger = async (focusedIndex: number): Promise<boolean> => {
    const currentLength = items().length;
    if (currentLength === 0 || isLoading() || !hasMore()) {
      return false;
    }

    if (focusedIndex >= currentLength - threshold) {
      return await loadMore();
    }
    return false;
  };

  const reset = async (): Promise<void> => {
    setIsLoading(true);
    setItemsSignal([]);
    setTotal(0);

    try {
      const result = await options.fetchBatch(0, options.pageSize);
      setItemsSignal(result.items);
      setTotal(result.total);
      options.onBatchLoaded?.(result.items, result.total);
    } catch (err) {
      console.error('[InfiniteScroller] Failed to reset and load initial batch:', err);
    } finally {
      setIsLoading(false);
    }
  };

  const setItems = (newItems: T[], newTotal: number) => {
    setItemsSignal(newItems);
    setTotal(newTotal);
  };

  return {
    items,
    total,
    isLoading,
    hasMore,
    checkTrigger,
    loadMore,
    reset,
    setItems,
  };
}

