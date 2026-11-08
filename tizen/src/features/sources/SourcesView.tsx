import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { Database, SourceRecord } from '../../core/storage/Database';
import { CndEngine } from '../../core/engine/CndEngine';
import { spatialNav } from '../../ui/design/SpatialNav';
import { announce } from '../../ui/design/a11y';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { hostOf } from '../../core/pairing/ShareImport';
import { PairingView } from '../pairing/PairingView';
import { ManualSourceForm } from '../onboarding/ManualSourceForm';

export interface SourcesViewProps {
  onBack: () => void;
  onAddNew?: () => void;
}

export type SourcesSubview = 'list' | 'pairing' | 'manual';

export const SourcesView: Component<SourcesViewProps> = (props) => {
  const [sources, setSources] = createSignal<SourceRecord[]>([]);
  const [subview, setSubview] = createSignal<SourcesSubview>('list');
  const [sourceToDelete, setSourceToDelete] = createSignal<SourceRecord | null>(null);
  const [focusId] = spatialNav.getFocusSignal();

  let keyUnsub: (() => void) | null = null;

  const loadSources = async () => {
    const list = await Database.getInstance().getSources();
    setSources(list);
    updateListGrid(list);
  };

  const updateListGrid = (list: SourceRecord[]) => {
    if (sourceToDelete()) {
      spatialNav.setGrid([
        [
          { id: 'btn-confirm-delete', onSelect: () => void confirmDelete() },
          { id: 'btn-cancel-delete', onSelect: closeDeleteModal },
        ],
      ]);
      return;
    }

    const grid = [
      [
        {
          id: 'btn-add-phone',
          onSelect: () => setSubview('pairing'),
        },
        {
          id: 'btn-add-manual',
          onSelect: () => setSubview('manual'),
        },
      ],
      ...list.map((s) => [
        {
          id: `source-item-${s.id}`,
          onSelect: () => console.log('Select source', s.name),
        },
        {
          id: `source-del-${s.id}`,
          onSelect: () => promptDelete(s),
        },
      ]),
    ];
    spatialNav.setGrid(grid);
  };

  const promptDelete = (s: SourceRecord) => {
    setSourceToDelete(s);
    updateListGrid(sources());
    setTimeout(() => {
      spatialNav.setFocusById('btn-cancel-delete');
    }, 50);
    announce(`Voulez-vous vraiment supprimer la source ${s.name} ?`);
  };

  const closeDeleteModal = () => {
    setSourceToDelete(null);
    updateListGrid(sources());
  };

  const confirmDelete = async () => {
    const target = sourceToDelete();
    if (!target) return;
    try {
      await CndEngine.getInstance().deleteSource(target.id);
      announce(`Source ${target.name} supprimée.`);
      setSourceToDelete(null);
      await loadSources();
    } catch (err: any) {
      announce(`Erreur lors de la suppression : ${err?.message ?? 'inconnue'}`);
      setSourceToDelete(null);
      updateListGrid(sources());
    }
  };

  const handleRemoteKey = (key: RemoteKey): boolean => {
    if (key === 'BACK') {
      if (sourceToDelete()) {
        closeDeleteModal();
        return true;
      }
      if (subview() !== 'list') {
        setSubview('list');
        updateListGrid(sources());
        return true;
      }
      props.onBack();
      return true;
    }
    return false;
  };

  onMount(async () => {
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleRemoteKey);
    await loadSources();
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
  });

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        'box-sizing': 'border-box',
        overflow: 'hidden',
        position: 'relative',
      }}
    >
      <Show when={subview() === 'pairing'}>
        <PairingView
          title="Ajouter depuis votre smartphone"
          subtitle="Scannez ce QR code avec l'application Buntu (iPhone ou Android) pour transférer vos abonnements."
          onSuccess={async (count) => {
            await loadSources();
            setSubview('list');
            announce(`${count} compte${count > 1 ? 's' : ''} ajouté${count > 1 ? 's' : ''} avec succès !`);
          }}
          onBack={() => {
            setSubview('list');
            updateListGrid(sources());
          }}
          onSwitchToManual={() => setSubview('manual')}
        />
      </Show>

      <Show when={subview() === 'manual'}>
        <div class="tv-container" style={{ 'justify-content': 'center', 'align-items': 'center' }}>
          <ManualSourceForm
            onAdded={async () => {
              await loadSources();
              setSubview('list');
              announce('Abonnement ajouté avec succès.');
            }}
            onCancel={() => {
              setSubview('list');
              updateListGrid(sources());
            }}
          />
        </div>
      </Show>

      <Show when={subview() === 'list'}>
        <div
          style={{
            width: '100%',
            height: '100%',
            padding: '24px 48px',
            'box-sizing': 'border-box',
            overflow: 'hidden',
            display: 'flex',
            'flex-direction': 'column',
          }}
        >
          {/* Header */}
          <div class="tv-header" style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-bottom': '28px' }}>
            <div>
              <h2 style={{ 'font-size': '36px', color: 'var(--buntu-gold)', margin: '0 0 6px 0' }}>
                Gestion des abonnements & sources
              </h2>
              <p style={{ 'font-size': '18px', color: 'var(--buntu-text-muted)', margin: 0 }}>
                {sources().length} source{sources().length > 1 ? 's' : ''} enregistrée{sources().length > 1 ? 's' : ''}
              </p>
            </div>
            <div style={{ display: 'flex', gap: '16px' }}>
              <button
                id="btn-add-phone"
                tabindex="-1"
                aria-label="Ajouter depuis votre smartphone via QR code"
                class={`tv-btn ${focusId() === 'btn-add-phone' ? 'focused' : ''}`}
                onClick={() => setSubview('pairing')}
              >
                📱 Ajouter depuis le téléphone
              </button>
              <button
                id="btn-add-manual"
                tabindex="-1"
                aria-label="Ajouter manuellement une source IPTV avec la télécommande"
                class={`tv-btn ${focusId() === 'btn-add-manual' ? 'focused' : ''}`}
                onClick={() => setSubview('manual')}
              >
                ✍️ Saisie manuelle
              </button>
            </div>
          </div>

          {/* Sources List */}
          <div
            role="list"
            aria-label="Liste des sources d'abonnements"
            style={{ display: 'flex', 'flex-direction': 'column', gap: '16px', 'overflow-y': 'auto', flex: 1, padding: '4px' }}
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
                    padding: '24px 32px',
                    display: 'flex',
                    'justify-content': 'space-between',
                    'align-items': 'center',
                    background: 'var(--buntu-slate)',
                    border: '1px solid var(--buntu-border)',
                    'border-radius': '12px',
                  }}
                >
                  <div>
                    <h3 style={{ 'font-size': '26px', margin: '0 0 8px 0', color: '#FFFFFF' }}>{source.name}</h3>
                    <p style={{ color: 'var(--buntu-text-muted)', margin: 0, 'font-size': '18px' }}>
                      Type : <strong style={{ color: 'var(--buntu-gold)' }}>{source.source_type.toUpperCase()}</strong> · Serveur :{' '}
                      {hostOf(source.server || source.url || '') || 'local'} · {source.item_count} chaînes / flux
                    </p>
                  </div>
                  <div style={{ display: 'flex', 'align-items': 'center', gap: '20px' }}>
                    <div style={{ color: 'var(--buntu-cyan)', 'font-weight': '700', 'font-size': '18px' }}>
                      Actif (1 connexion)
                    </div>
                    <button
                      id={`source-del-${source.id}`}
                      tabindex="-1"
                      aria-label={`Supprimer la source ${source.name}`}
                      class={`tv-btn tv-btn-danger ${focusId() === `source-del-${source.id}` ? 'focused' : ''}`}
                      style={{ padding: '10px 18px', 'font-size': '16px' }}
                      onClick={(e) => {
                        e.stopPropagation();
                        promptDelete(source);
                      }}
                    >
                      🗑️ Supprimer
                    </button>
                  </div>
                </div>
              )}
            </For>
            {sources().length === 0 && (
              <div
                style={{
                  'text-align': 'center',
                  padding: '80px 24px',
                  color: 'var(--buntu-text-muted)',
                  background: 'var(--buntu-slate)',
                  'border-radius': '12px',
                  border: '1px dashed var(--buntu-border)',
                }}
              >
                <div style={{ 'font-size': '48px', 'margin-bottom': '16px' }}>📡</div>
                <h3 style={{ 'font-size': '26px', color: '#FFFFFF', 'margin-bottom': '8px' }}>
                  Aucun abonnement enregistré
                </h3>
                <p style={{ 'font-size': '20px', 'max-width': '600px', margin: '0 auto 24px auto' }}>
                  Ajoutez vos comptes IPTV en scannant le QR code depuis votre smartphone ou saisissez vos identifiants manuellement.
                </p>
                <button
                  id="btn-add-phone-empty"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-add-phone' ? 'focused' : ''}`}
                  onClick={() => setSubview('pairing')}
                >
                  📱 Scanner le QR code avec son téléphone
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Delete Confirmation Modal */}
        <Show when={sourceToDelete()}>
          <div class="tv-modal-overlay" role="dialog" aria-modal="true" aria-labelledby="del-modal-title">
            <div class="tv-modal-card">
              <div style={{ 'font-size': '52px', color: 'var(--buntu-danger)' }}>🗑️</div>
              <h2
                id="del-modal-title"
                style={{ 'font-size': '32px', 'font-weight': '800', color: 'var(--buntu-gold)', margin: 0 }}
              >
                Supprimer la source IPTV ?
              </h2>
              <p style={{ 'font-size': '22px', color: 'var(--buntu-text-muted)', margin: 0, 'max-width': '520px', 'line-height': '1.4' }}>
                Voulez-vous vraiment supprimer « <strong style={{ color: '#FFFFFF' }}>{sourceToDelete()?.name}</strong> » ?
                Toutes les chaînes, films, séries et favoris associés seront retirés de cette TV.
              </p>
              <div style={{ display: 'flex', gap: '20px', 'margin-top': '16px' }}>
                <button
                  id="btn-confirm-delete"
                  tabindex="-1"
                  aria-label="Confirmer la suppression de la source"
                  class={`tv-btn tv-btn-danger ${focusId() === 'btn-confirm-delete' ? 'focused' : ''}`}
                  onClick={() => void confirmDelete()}
                >
                  🗑️ Oui, supprimer
                </button>
                <button
                  id="btn-cancel-delete"
                  tabindex="-1"
                  aria-label="Annuler la suppression"
                  class={`tv-btn ${focusId() === 'btn-cancel-delete' ? 'focused' : ''}`}
                  onClick={closeDeleteModal}
                >
                  Annuler
                </button>
              </div>
            </div>
          </div>
        </Show>
      </Show>
    </div>
  );
};
