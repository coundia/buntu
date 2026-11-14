import { SourceEditForm } from './SourceEditForm';
import { describeSourceExpiry } from './sourceExpiry';
import { Component, createSignal, onMount, onCleanup, For, Show } from 'solid-js';
import { Database, SourceRecord } from '../../core/storage/Database';
import { CndEngine } from '../../core/engine/CndEngine';
import { spatialNav } from '../../ui/design/SpatialNav';
import { announce } from '../../ui/design/a11y';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { PairingView } from '../pairing/PairingView';
import { ManualSourceForm } from '../onboarding/ManualSourceForm';
import { LocalSyncService } from '../../core/sync/LocalSyncService';
import { HouseholdStore } from '../../core/sync/HouseholdStore';
import { HouseholdJoinView } from '../pairing/HouseholdJoinView';
import { t } from '../../core/i18n';

export interface SourcesViewProps {
  onBack: () => void;
  onAddNew?: () => void;
}

export type SourcesSubview = 'list' | 'pairing' | 'manual' | 'household' | 'edit';

export const SourcesView: Component<SourcesViewProps> = (props) => {
  const [sources, setSources] = createSignal<SourceRecord[]>([]);
  const [subview, setSubview] = createSignal<SourcesSubview>(HouseholdStore.getInstance().getHouseholdInfo() ? 'list' : 'household');
  const [sourceToEdit, setSourceToEdit] = createSignal<SourceRecord | null>(null);
  const [sourceToDelete, setSourceToDelete] = createSignal<SourceRecord | null>(null);
  const [isDeleting, setIsDeleting] = createSignal(false);
  const [deleteError, setDeleteError] = createSignal('');
  const store = HouseholdStore.getInstance();
  const [salon, setSalon] = createSignal(store.getHouseholdInfo());
  const [focusId] = spatialNav.getFocusSignal();

  let keyUnsub: (() => void) | null = null;

  const loadSources = async () => {
    const list = await Database.getInstance().getSources();
    setSalon(store.getHouseholdInfo());
    setSources(list);
    if (subview() === 'list') updateListGrid(list);
  };

  const updateListGrid = (list: SourceRecord[]) => {
    const grid = [
      [
        {
          id: 'btn-import-phone',
          onSelect: () => setSubview('pairing'),
        },
        {
          id: 'btn-add-manual',
          onSelect: () => setSubview('manual'),
        },
      ],
      [
        {
          id: 'btn-add-phone',
          onSelect: () => setSubview('household'),
        },
      ],
      ...list.map((s) => [
        {
          id: `source-item-${s.id}`,
          onSelect: () => editSource(s),
        },
        { id: `source-edit-${s.id}`, onSelect: () => editSource(s) },
        {
          id: `source-del-${s.id}`,
          onSelect: () => promptDelete(s),
        },
      ]),
    ];
    // Presence updates must not move the remote focus; during a modal this updates its saved list.
    spatialNav.setGrid(grid, 0, 0, true);
  };

  const editSource = (source: SourceRecord) => {
    setSourceToEdit(source);
    setSubview('edit');
  };
  const closeEditor = () => {
    setSourceToEdit(null);
    setSubview('list');
    void loadSources();
  };

  const promptDelete = (s: SourceRecord) => {
    if (isDeleting()) return;
    setDeleteError('');
    setSourceToDelete(s);
    spatialNav.openModal([[
      { id: 'btn-confirm-delete', onSelect: () => void confirmDelete() },
      { id: 'btn-cancel-delete', onSelect: closeDeleteModal },
    ]], 0, 1);
    announce(`Voulez-vous vraiment supprimer la source ${s.name} ?`);
  };

  const closeDeleteModal = () => {
    if (isDeleting()) return;
    setSourceToDelete(null);
    setDeleteError('');
    spatialNav.closeModal();
    updateListGrid(sources());
  };

  const confirmDelete = async () => {
    const target = sourceToDelete();
    if (!target || isDeleting()) return;
    setIsDeleting(true);
    setDeleteError('');
    try {
      await CndEngine.getInstance().deleteSource(target.id);
      announce(`Source ${target.name} supprimée.`);
      await loadSources();
      setIsDeleting(false);
      closeDeleteModal();
    } catch {
      const message = 'La suppression a échoué. Réessayez.';
      setDeleteError(message);
      announce(message);
    } finally {
      setIsDeleting(false);
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

  let syncUnsub: (() => void) | null = null;

  onMount(async () => {
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleRemoteKey);
    syncUnsub = LocalSyncService.getInstance().onStatusChange(() => {
      void loadSources();
    });
    await loadSources();
  });

  onCleanup(() => {
    if (sourceToDelete()) spatialNav.closeModal();
    if (keyUnsub) keyUnsub();
    if (syncUnsub) syncUnsub();
  });

  return (
    <div class="buntu-sources-page"
      style={{
        width: '100%',
        height: '100%',
        'box-sizing': 'border-box',
        overflow: 'hidden',
        position: 'relative',
      }}
    >
      <Show when={subview() === 'edit' && sourceToEdit()}>
        <SourceEditForm source={sourceToEdit()!} onSaved={() => { closeEditor(); announce('Modifications enregistrées sur cette TV uniquement.'); }} onCancel={closeEditor} />
      </Show>
      <Show when={subview() === 'household'}>
        <HouseholdJoinView onBack={() => { setSubview('list'); updateListGrid(sources()); }} onJoined={() => {
          setSalon(store.getHouseholdInfo());
          setSubview('list');
          void loadSources();
          announce('Cette TV a rejoint le foyer.');
        }} />
      </Show>
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
            padding: '40px 64px',
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
                {t('sources.title')}
              </h2>
              <p style={{ 'font-size': '18px', color: 'var(--buntu-text-muted)', margin: 0 }}>
                {sources().length > 1
                  ? t('sources.countPlural', { count: sources().length })
                  : t('sources.countSingle', { count: sources().length })}
              </p>
              <p class="buntu-return-hint">{t('sources.returnHome')}</p>
            </div>
            <div class="buntu-simple-actions">
              <button
                id="btn-import-phone"
                tabindex="-1"
                aria-label={t('sources.importPhoneAria')}
                class={`tv-btn ${focusId() === 'btn-import-phone' ? 'focused' : ''}`}
                onClick={() => setSubview('pairing')}
              >
                {t('sources.importPhone')}
              </button>
              <button
                id="btn-add-manual"
                tabindex="-1"
                aria-label={t('sources.addManualAria')}
                class={`tv-btn ${focusId() === 'btn-add-manual' ? 'focused' : ''}`}
                onClick={() => setSubview('manual')}
              >
                {t('sources.addManual')}
              </button>
            </div>
          </div>

          <section class="buntu-source-household" aria-label="Foyer Buntu">
            <span>{salon() ? t('sources.householdLabel', { name: salon()!.household_name }) : t('sources.noHousehold')}</span>
            <button id="btn-add-phone" tabindex="-1" class={`tv-btn ${focusId() === 'btn-add-phone' ? 'focused' : ''}`} onClick={() => setSubview('household')}>
              {t('sources.pairTvQr')}
            </button>
          </section>

          {/* Sources List */}
          <div
            role="list"
            aria-label={t('sources.listAria')}
            class="buntu-source-list"
          >
            <For each={sources()}>
              {(source) => (
                <div
                  id={`source-item-${source.id}`}
                  role="button"
                  tabindex="-1"
                  aria-label={`Source ${source.name}, type ${source.source_type}, ${source.item_count} éléments. OK pour modifier.`}
                  class={`tv-card ${focusId() === `source-item-${source.id}` ? 'focused' : ''}`}
                  onClick={() => editSource(source)}
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
                      <strong style={{ color: 'var(--buntu-gold)' }}>{source.source_type.toUpperCase()}</strong> ·{' '}
                      {source.item_count > 0 ? (
                        <span>{t('sources.streamsCount', { count: source.item_count })}</span>
                      ) : (
                        <span style={{ color: 'var(--buntu-cyan)' }}>{t('sources.preparing')}</span>
                      )}
                      {source.source_type === 'xtream' && !source.password && (
                        <span style={{ color: '#FF6B6B', 'margin-left': '8px' }}>{t('sources.missingPassword')}</span>
                      )}
                    </p>
                    <Show when={(source.exp_date && source.exp_date > 0) || (source.max_connections && source.max_connections > 0)}>
                      {(() => {
                        const expiry = describeSourceExpiry(source);
                        const expColor = expiry
                          ? expiry.status === 'expired'
                            ? '#FF6B6B'
                            : expiry.status === 'soon'
                              ? 'var(--buntu-gold)'
                              : 'var(--buntu-text-muted)'
                          : 'var(--buntu-text-muted)';
                        return (
                          <p style={{ margin: '6px 0 0 0', 'font-size': '15px', color: 'var(--buntu-text-muted)' }}>
                            <Show when={expiry}>
                              <span style={{ color: expColor, 'font-weight': expiry!.status !== 'ok' ? '700' : '400' }}>
                                {expiry!.label}
                              </span>
                            </Show>
                            <Show when={source.max_connections && source.max_connections > 0}>
                              <span>
                                {expiry ? ' · ' : ''}
                                {source.max_connections} connexion{source.max_connections! > 1 ? 's' : ''} max
                              </span>
                            </Show>
                          </p>
                        );
                      })()}
                    </Show>
                  </div>
                  <div style={{ display: 'flex', 'align-items': 'center', gap: '20px' }}>
                    <button
                      id={`source-edit-${source.id}`}
                      tabindex="-1"
                      class={`tv-btn ${focusId() === `source-edit-${source.id}` ? 'focused' : ''}`}
                      onClick={(e) => { e.stopPropagation(); editSource(source); }}
                      style={{ 'margin-right': '16px' }}
                    >{t('common.edit')}</button>
                    <button
                      id={`source-del-${source.id}`}
                      tabindex="-1"
                      aria-label={`${t('common.delete')} ${source.name}`}
                      class={`tv-btn tv-btn-danger ${focusId() === `source-del-${source.id}` ? 'focused' : ''}`}
                      style={{ padding: '10px 18px', 'font-size': '16px' }}
                      onClick={(e) => {
                        e.stopPropagation();
                        promptDelete(source);
                      }}
                    >
                      🗑️ {t('common.delete')}
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
                  {t('sources.emptyTitle')}
                </h3>
                <p style={{ 'font-size': '20px', 'max-width': '600px', margin: '0 auto 24px auto' }}>
                  {t('sources.emptyHint')}
                </p>

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
                {t('sources.deleteModalTitle')}
              </h2>
              <p style={{ 'font-size': '22px', color: 'var(--buntu-text-muted)', margin: 0, 'max-width': '520px', 'line-height': '1.4' }}>
                {t('sources.deleteModalConfirm', { name: sourceToDelete()?.name || '' })}
              </p>
              <Show when={deleteError()}>
                <p role="alert" style={{ color: 'var(--buntu-danger)' }}>{deleteError()}</p>
              </Show>
              <div style={{ display: 'flex', gap: '20px', 'margin-top': '16px' }}>
                <button
                  id="btn-confirm-delete"
                  tabindex="-1"
                  aria-label={t('sources.confirmDelete')}
                  disabled={isDeleting()}
                  class={`tv-btn tv-btn-danger ${focusId() === 'btn-confirm-delete' ? 'focused' : ''}`}
                  onClick={() => void confirmDelete()}
                >
                  {isDeleting() ? t('sources.deleting') : t('sources.confirmDelete')}
                </button>
                <button
                  id="btn-cancel-delete"
                  tabindex="-1"
                  aria-label={t('common.cancel')}
                  disabled={isDeleting()}
                  class={`tv-btn ${focusId() === 'btn-cancel-delete' ? 'focused' : ''}`}
                  onClick={closeDeleteModal}
                >
                  {t('common.cancel')}
                </button>
              </div>
            </div>
          </div>
        </Show>
      </Show>
    </div>
  );
};
