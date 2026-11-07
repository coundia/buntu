import { Component, Show } from 'solid-js';

export interface TvSearchBarProps {
  id: string;
  placeholder?: string;
  value: string;
  onInput: (val: string) => void;
  onClear: () => void;
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
      <Show when={props.value.trim().length > 0}>
        <button
          id={`${props.id}-clear`}
          type="button"
          tabindex="-1"
          class={`tv-search-clear-btn ${props.focusId === `${props.id}-clear` ? 'focused' : ''}`}
          onClick={() => props.onClear()}
          aria-label="Effacer la recherche"
        >
          ✕
        </button>
      </Show>
    </div>
  );
};
