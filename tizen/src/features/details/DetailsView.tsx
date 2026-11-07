import { Component, createSignal, onMount, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface DetailsViewProps {
  item: ItemRecord;
  onPlay: (item: ItemRecord) => void;
  onBack: () => void;
}

export const DetailsView: Component<DetailsViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [isFav, setIsFav] = createSignal(props.item.is_favorite === 1);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(() => {
    spatialNav.setGrid([
      [
        {
          id: 'btn-play-now',
          onSelect: () => props.onPlay(props.item),
        },
        {
          id: 'btn-toggle-fav',
          onSelect: async () => {
            const next = await engine.toggleFavorite(props.item.id);
            setIsFav(next);
          },
        },
        {
          id: 'btn-back',
          onSelect: () => props.onBack(),
        },
      ],
    ]);
  });

  const title = () => props.item.name_clean || props.item.name;

  return (
    <div class="tv-container" style={{ "justify-content": "center" }}>
      <div class="tv-details-card">
        {/* Left: Poster Box with Image & Fallback */}
        <div class="tv-details-poster-box">
          <Show
            when={props.item.logo_url}
            fallback={
              <div class="tv-poster-fallback" style={{ height: "100%", "justify-content": "center" }}>
                <span style={{ "font-size": "64px", opacity: "0.6" }}>
                  {props.item.kind === 'series' ? '📺' : '🎬'}
                </span>
                <span class="tv-poster-fallback-title">{title()}</span>
              </div>
            }
          >
            <img
              src={props.item.logo_url}
              alt=""
              onError={(e) => {
                const target = e.currentTarget as HTMLElement;
                target.style.display = 'none';
                const parent = target.parentElement;
                if (parent && !parent.querySelector('.tv-poster-fallback')) {
                  const fb = document.createElement('div');
                  fb.className = 'tv-poster-fallback';
                  fb.style.height = '100%';
                  fb.style.justifyContent = 'center';
                  fb.innerHTML = `<span style="font-size: 64px; opacity: 0.6">${props.item.kind === 'series' ? '📺' : '🎬'}</span><span class="tv-poster-fallback-title">${title()}</span>`;
                  parent.appendChild(fb);
                }
              }}
            />
          </Show>
        </div>

        {/* Right: Info, Synopsis & Action Buttons */}
        <div class="tv-details-content">
          <h1 class="tv-details-title">
            {title()}
          </h1>

          <div class="tv-details-meta-bar">
            <Show when={props.item.imdb_rating}>
              <span class="tv-details-badge" style={{ color: "var(--buntu-gold)" }}>
                ★ {props.item.imdb_rating!.toFixed(1)} / 10
              </span>
            </Show>

            <span class="tv-details-badge" style={{ color: "var(--buntu-text-muted)" }}>
              {props.item.year || '2024'}
            </span>

            <span class="tv-details-badge" style={{ color: "var(--buntu-cyan)" }}>
              {props.item.group_title || (props.item.kind === 'series' ? 'Série TV' : 'Film & VOD')}
            </span>

            <span class="tv-details-pill">
              {props.item.container_ext?.toUpperCase() || 'MKV'}
            </span>
          </div>

          <p class="tv-details-synopsis">
            {props.item.plot || "Aucun résumé disponible pour ce média. Appuyez sur 'Lancer la lecture' pour démarrer la lecture instantanée avec décodage matériel Samsung AVPlay."}
          </p>

          {/* Action Buttons with explicit margins */}
          <div class="tv-details-actions" role="toolbar" aria-label="Actions du média">
            <button
              id="btn-play-now"
              tabindex="-1"
              aria-label={`Lancer la lecture de ${title()}`}
              class={`tv-btn ${focusId() === 'btn-play-now' ? 'focused' : ''}`}
              onClick={() => props.onPlay(props.item)}
            >
              ▶ Lancer la lecture
            </button>

            <button
              id="btn-toggle-fav"
              tabindex="-1"
              aria-label={isFav() ? 'Retirer ce titre des favoris' : 'Ajouter ce titre aux favoris'}
              class={`tv-btn ${focusId() === 'btn-toggle-fav' ? 'focused' : ''}`}
              onClick={async () => {
                const next = await engine.toggleFavorite(props.item.id);
                setIsFav(next);
              }}
            >
              {isFav() ? '★ Retirer des favoris' : '☆ Favoris'}
            </button>

            <button
              id="btn-back"
              tabindex="-1"
              aria-label="Retourner au catalogue"
              class={`tv-btn ${focusId() === 'btn-back' ? 'focused' : ''}`}
              onClick={() => props.onBack()}
            >
              ← Retour
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
