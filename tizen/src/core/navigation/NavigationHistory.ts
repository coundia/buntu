/**
 * Back-stack of the screens the viewer went through, so the remote's BACK key returns to the
 * screen that was displayed before (a movie's details -> the list it came from, the player ->
 * the screen that started it) instead of always jumping to Live TV.
 */

export interface NavEntry<T extends { id: number }> {
  route: string;
  /** Item shown on that screen (details, player), restored when coming back to it. */
  item: T | null;
}

export class NavigationHistory<T extends { id: number }> {
  private stack: NavEntry<T>[] = [];

  constructor(private readonly maxDepth = 20) {}

  get size(): number {
    return this.stack.length;
  }

  private static same<T extends { id: number }>(a: NavEntry<T>, b: NavEntry<T>): boolean {
    return a.route === b.route && (a.item?.id ?? null) === (b.item?.id ?? null);
  }

  /**
   * Record a move from `from` to `to`. Going back to the screen right below on the stack
   * (e.g. through the menu) pops it instead of stacking, which prevents Live <-> Movies loops.
   */
  enter(from: NavEntry<T>, to: NavEntry<T>): void {
    if (NavigationHistory.same(from, to)) return;
    const top = this.stack[this.stack.length - 1];
    if (top && NavigationHistory.same(top, to)) {
      this.stack.pop();
      return;
    }
    // Onboarding is a one-off flow: never a place to come back to.
    if (from.route === 'onboarding') return;
    this.stack.push(from);
    if (this.stack.length > this.maxDepth) this.stack.shift();
  }

  /** The screen to return to, or undefined when there is nothing before the current one. */
  back(): NavEntry<T> | undefined {
    return this.stack.pop();
  }

  /** Forget everything (profile switch, end of onboarding). */
  reset(): void {
    this.stack = [];
  }
}
