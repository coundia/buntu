import { describe, it, expect } from 'vitest';
import { neighbourInList, zapContext } from '../src/core/navigation/ZapContext';

const list = [{ id: 10 }, { id: 20 }, { id: 30 }];

describe('Ch+ / Ch- neighbour in a list', () => {
  it('goes to the next and previous item', () => {
    expect(neighbourInList(list, 10, 1)).toEqual({ id: 20 });
    expect(neighbourInList(list, 30, -1)).toEqual({ id: 20 });
  });

  it('wraps around at both ends', () => {
    expect(neighbourInList(list, 30, 1)).toEqual({ id: 10 });
    expect(neighbourInList(list, 10, -1)).toEqual({ id: 30 });
  });

  it('enters the list from its start (or end) when the current item is not in it', () => {
    expect(neighbourInList(list, 99, 1)).toEqual({ id: 10 });
    expect(neighbourInList(list, 99, -1)).toEqual({ id: 30 });
  });

  it('has nowhere to go with an empty list or only the current item', () => {
    expect(neighbourInList([], 1, 1)).toBeUndefined();
    expect(neighbourInList([{ id: 5 }], 5, 1)).toBeUndefined();
    expect(neighbourInList([{ id: 5 }], 5, -1)).toBeUndefined();
  });

  it('starts with the whole catalog as the zapping list', () => {
    expect(zapContext.category).toBe('');
  });
});
