import { Component, createSignal, onMount } from 'solid-js';
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

  return (
    <div class="tv-container" style={{ "justify-content": "center" }}>
      <div style={{
        display: "flex",
        gap: "48px",
        background: "var(--buntu-slate)",
        padding: "48px",
        "border-radius": "16px",
        border: "1px solid var(--buntu-border)",
      }}>
        {/* Poster */}
        <div style={{
          width: "300px",
          height: "450px",
          "background-image": props.item.logo_url ? `url(${props.item.logo_url})` : 'none',
          "background-size": "cover",
          "background-position": "center",
          "border-radius": "12px",
          "box-shadow": "0 10px 30px rgba(0,0,0,0.8)",
          "background-color": "var(--buntu-slate-light)",
        }} />

        {/* Info & Metadata */}
        <div style={{ flex: 1, display: "flex", "flex-direction": "column", "justify-content": "center" }}>
          <h1 style={{ "font-size": "44px", "font-weight": "800", "margin-bottom": "12px" }}>
            {props.item.name_clean || props.item.name}
          </h1>

          <div style={{ display: "flex", gap: "24px", "margin-bottom": "24px", "font-size": "20px" }}>
            <span style={{ color: "var(--buntu-gold)", "font-weight": "700" }}>
              {props.item.imdb_rating ? `★ ${props.item.imdb_rating.toFixed(1)} / 10` : 'Non noté'}
            </span>
            <span style={{ color: "var(--buntu-text-muted)" }}>{props.item.year || '2024'}</span>
            <span style={{ color: "var(--buntu-cyan)" }}>{props.item.group_title || 'Général'}</span>
            <span style={{
              background: "rgba(255,255,255,0.1)",
              padding: "2px 8px",
              "border-radius": "4px",
              "font-size": "16px"
            }}>
              {props.item.container_ext?.toUpperCase() || 'MKV'}
            </span>
          </div>

          <p style={{
            "font-size": "20px",
            "line-height": "1.6",
            color: "var(--buntu-text-muted)",
            "margin-bottom": "40px",
            "max-height": "160px",
            "overflow-y": "hidden"
          }}>
            {props.item.plot || "Aucun résumé disponible pour ce média. Appuyez sur Lecture pour lancer la diffusion en décodage matériel AVPlay."}
          </p>

          {/* Action buttons */}
          <div style={{ display: "flex", gap: "24px" }}>
            <button
              class={`tv-btn ${focusId() === 'btn-play-now' ? 'focused' : ''}`}
              onClick={() => props.onPlay(props.item)}
            >
              ▶ Lancer la lecture
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-toggle-fav' ? 'focused' : ''}`}
              onClick={async () => {
                const next = await engine.toggleFavorite(props.item.id);
                setIsFav(next);
              }}
            >
              {isFav() ? '★ Retirer des favoris' : '☆ Ajouter aux favoris'}
            </button>
            <button
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
