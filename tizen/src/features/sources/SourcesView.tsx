import { Component, createSignal, onMount, For } from 'solid-js';
import { Database, SourceRecord } from '../../core/storage/Database';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface SourcesViewProps {
  onBack: () => void;
  onAddNew: () => void;
}

export const SourcesView: Component<SourcesViewProps> = (props) => {
  const [sources, setSources] = createSignal<SourceRecord[]>([]);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(async () => {
    const list = await Database.getInstance().getSources();
    setSources(list);

    const grid = [
      [
        {
          id: 'btn-add-source',
          onSelect: () => props.onAddNew(),
        },
      ],
      ...list.map((s, idx) => [
        {
          id: `source-item-${s.id}`,
          onSelect: () => console.log('Select source', s.name),
        },
      ]),
    ];
    spatialNav.setGrid(grid);
  });

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        padding: "24px 40px",
        "box-sizing": "border-box",
        overflow: "hidden",
        display: "flex",
        "flex-direction": "column"
      }}
    >
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Gestion des abonnements & sources</h2>
        <button
          id="btn-add-source"
          tabindex="-1"
          aria-label="Ajouter une nouvelle source IPTV"
          class={`tv-btn ${focusId() === 'btn-add-source' ? 'focused' : ''}`}
          onClick={() => props.onAddNew()}
        >
          + Ajouter une source
        </button>
      </div>

      <div
        role="list"
        aria-label="Liste des sources d'abonnements"
        style={{ display: "flex", "flex-direction": "column", gap: "16px", "overflow-y": "auto" }}
      >
        <For each={sources()}>
          {(source) => (
            <div
              id={`source-item-${source.id}`}
              role="button"
              tabindex="-1"
              aria-label={`Source ${source.name}, type ${source.source_type}, ${source.item_count} éléments.`}
              class={`tv-card ${focusId() === `source-item-${source.id}` ? 'focused' : ''}`}
              style={{
                padding: "24px",
                display: "flex",
                "justify-content": "space-between",
                "align-items": "center",
              }}
            >
              <div>
                <h3 style={{ "font-size": "24px", "margin-bottom": "8px" }}>{source.name}</h3>
                <p style={{ color: "var(--buntu-text-muted)" }}>
                  Type: {source.source_type.toUpperCase()} • Éléments: {source.item_count}
                </p>
              </div>
              <div style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>
                Actif (1 connexion)
              </div>
            </div>
          )}
        </For>
        {sources().length === 0 && (
          <div style={{ "text-align": "center", padding: "64px", color: "var(--buntu-text-muted)" }}>
            Aucune source IPTV enregistrée. Utilisez le bouton ci-dessus pour en ajouter une.
          </div>
        )}
      </div>
    </div>
  );
};

