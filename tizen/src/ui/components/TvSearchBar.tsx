import { Component } from 'solid-js';

export interface TvSearchBarProps {
  id: string;
  placeholder?: string;
  value: string;
  onInput: (val: string) => void;
  /** Kept for callers; there is no clear button any more (an icon the remote had to stop on). */
  onClear?: () => void;
  focusId?: string;
}

export const TvSearchBar: Component<TvSearchBarProps> = (props) => {
  return (
    <div class="tv-header-search" role="search">
      <input
        id={props.id}
        type="text"
        tabindex="-1"
        class={`tv-search-input ${props.focusId === props.id ? 'focused' : ''}`}
        placeholder={props.placeholder || '🔍 Rechercher...'}
        value={props.value}
        onInput={(e) => props.onInput(e.currentTarget.value)}
        aria-label={props.placeholder || 'Rechercher'}
      />
    </div>
  );
};

