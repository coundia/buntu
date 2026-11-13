import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render } from 'solid-js/web';
import { SourcesView } from '../src/features/sources/SourcesView';
import { Database, SourceRecord } from '../src/core/storage/Database';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { CndEngine } from '../src/core/engine/CndEngine';
import { PairingService } from '../src/core/pairing/PairingService';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';

describe('SourcesView Integration (PRD 39)', () => {
  let container: HTMLDivElement;
  let dispose: () => void = () => {};

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
    vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdInfo').mockReturnValue({ household_id: 'test-house', household_name: 'Maison', created_at: 1 });
  });

  afterEach(() => {
    dispose();
    container.remove();
    RemoteKeyHandler.getInstance().destroy();
    vi.restoreAllMocks();
  });

  it('renders sources list and allows switching to phone QR pairing view', async () => {
    const mockSources: SourceRecord[] = [
      {
        id: 1,
        uuid: 'src-1',
        name: 'Mon Abonnement Xtream',
        source_type: 'xtream',
        server: 'http://xtream.example:8080',
        username: 'alice',
        item_count: 1400,
      } as SourceRecord,
    ];

    vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue(mockSources);

    const onBack = vi.fn();
    dispose = render(() => SourcesView({ onBack }), container);

    await new Promise((r) => setTimeout(r, 60));

    expect(container.textContent).toContain('Sources');
    expect(container.textContent).toContain('Mon Abonnement Xtream');
    expect(container.textContent).toContain('1400 chaînes / flux');
    expect(container.textContent).not.toContain('xtream.example:8080');

    // Click on "Ajouter depuis le téléphone"
    const addPhoneBtn = container.querySelector('#btn-import-phone') as HTMLButtonElement;
    expect(addPhoneBtn).not.toBeNull();
    addPhoneBtn.click();

    await new Promise((r) => setTimeout(r, 60));

    // Now in Pairing subview
    expect(container.textContent).toContain('Ajouter depuis votre smartphone');
    expect(container.textContent).toContain('1. Scannez avec votre téléphone');

    // Press BACK with remote control to return to sources list
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009, key: 'XF86Back' }));
    await new Promise((r) => setTimeout(r, 60));

    // Returned to list subview
    expect(container.textContent).toContain('Sources');
    expect(container.textContent).toContain('Mon Abonnement Xtream');
    expect(onBack).not.toHaveBeenCalled();
  });

  it('allows switching to manual remote control input and back', async () => {
    vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue([]);

    const onBack = vi.fn();
    dispose = render(() => SourcesView({ onBack }), container);

    await new Promise((r) => setTimeout(r, 60));

    // Click on "Saisie manuelle"
    const addManualBtn = container.querySelector('#btn-add-manual') as HTMLButtonElement;
    expect(addManualBtn).not.toBeNull();
    addManualBtn.click();

    await new Promise((r) => setTimeout(r, 60));

    // Now in Manual form subview
    expect(container.textContent).toContain('Ajouter un compte avec la télécommande');

    // Press BACK to return
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009, key: 'XF86Back' }));
    await new Promise((r) => setTimeout(r, 60));

    // Returned to list subview
    expect(container.textContent).toContain('Sources');
  });

  it('shows delete modal and removes source upon confirmation', async () => {
    const mockSources: SourceRecord[] = [
      {
        id: 42,
        uuid: 'src-42',
        name: 'Source Test',
        source_type: 'm3u',
        url: 'http://m3u.example/list.m3u',
        item_count: 50,
      } as SourceRecord,
    ];

    const getSourcesSpy = vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue(mockSources);
    const deleteSpy = vi.spyOn(Database.getInstance(), 'deleteSource').mockResolvedValue();

    const onBack = vi.fn();
    dispose = render(() => SourcesView({ onBack }), container);

    await new Promise((r) => setTimeout(r, 60));

    const delBtn = container.querySelector('#source-del-42') as HTMLButtonElement;
    expect(delBtn).not.toBeNull();
    delBtn.click();

    await new Promise((r) => setTimeout(r, 60));

    // Modal dialog open
    expect(container.textContent).toContain('Supprimer la source IPTV ?');
    expect(container.textContent).toContain('Source Test');

    // Cancel modal first
    const cancelBtn = container.querySelector('#btn-cancel-delete') as HTMLButtonElement;
    expect(cancelBtn).not.toBeNull();
    cancelBtn.click();

    await new Promise((r) => setTimeout(r, 60));
    expect(container.textContent).not.toContain('Supprimer la source IPTV ?');
    expect(deleteSpy).not.toHaveBeenCalled();

    // Reopen modal and confirm
    delBtn.click();
    await new Promise((r) => setTimeout(r, 60));

    getSourcesSpy.mockResolvedValue([]);
    const confirmBtn = container.querySelector('#btn-confirm-delete') as HTMLButtonElement;
    expect(confirmBtn).not.toBeNull();
    confirmBtn.click();

    await new Promise((r) => setTimeout(r, 60));
    expect(deleteSpy).toHaveBeenCalledWith(42);
  });

  it('deletes with remote keys and keeps confirmation focused during household updates', async () => {
    const source: SourceRecord = { id: 73, uuid: 'source-73', name: 'Source télécommande', source_type: 'm3u', item_count: 50 };
    const getSources = vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue([source]);
    const deletion = vi.spyOn(Database.getInstance(), 'deleteSource').mockImplementation(async () => {
      getSources.mockResolvedValue([]);
    });
    let refresh: () => void = () => {};
    vi.spyOn(LocalSyncService.getInstance(), 'onStatusChange').mockImplementation((listener) => {
      refresh = () => listener({ connected: true, pairedDeviceCount: 2 });
      return () => {};
    });
    const press = (key: string) => window.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
    const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
    dispose = render(() => SourcesView({ onBack: vi.fn() }), container);
    await settle();
    spatialNav.setHeader([{ id: 'sidebar' }], 0, 'vertical');
    spatialNav.setFocusById('source-del-73');
    press('Enter');
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(spatialNav.isModalOpen()).toBe(true);
    expect(spatialNav.getCurrentFocusId()).toBe('btn-cancel-delete');
    press('ArrowLeft');
    refresh();
    await settle();
    expect(spatialNav.getCurrentFocusId()).toBe('btn-confirm-delete');
    press('ArrowLeft');
    expect(spatialNav.getCurrentFocusId()).toBe('btn-confirm-delete');
    press('Enter');
    await settle();
    expect(deletion).toHaveBeenCalledExactlyOnceWith(73);
    expect(container.querySelector('#source-item-73')).toBeNull();
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(spatialNav.isModalOpen()).toBe(false);
    expect(spatialNav.getCurrentFocusId()).toBe('btn-import-phone');
  });

  it('shows deletion errors and allows retry without duplicate submissions', async () => {
    const source: SourceRecord = { id: 74, uuid: 'source-74', name: 'Source à retirer', source_type: 'm3u', item_count: 50 };
    const getSources = vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue([source]);
    let rejectDeletion: (error: Error) => void = () => {};
    const deletion = vi.spyOn(Database.getInstance(), 'deleteSource').mockImplementationOnce(() =>
      new Promise<void>((_resolve, reject) => { rejectDeletion = reject; })
    ).mockImplementation(async () => { getSources.mockResolvedValue([]); });
    const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
    dispose = render(() => SourcesView({ onBack: vi.fn() }), container);
    await settle();
    (container.querySelector('#source-del-74') as HTMLButtonElement).click();
    const confirm = container.querySelector('#btn-confirm-delete') as HTMLButtonElement;
    confirm.click();
    confirm.click();
    await settle();
    expect(deletion).toHaveBeenCalledTimes(1);
    expect(confirm.disabled).toBe(true);
    rejectDeletion(new Error('private storage details'));
    await settle();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('La suppression a échoué');
    expect(container.textContent).not.toContain('private storage details');
    expect(confirm.disabled).toBe(false);
    confirm.click();
    await settle();
    expect(deletion).toHaveBeenCalledTimes(2);
    expect(container.querySelector('#source-item-74')).toBeNull();
  });


  it('shows a TV pairing QR directly without creating a household', async () => {
    vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue([]);
    vi.mocked(HouseholdStore.getInstance().getHouseholdInfo).mockReturnValue(null);
    const create = vi.spyOn(HouseholdStore.getInstance(), 'createHousehold');
    vi.spyOn(PairingService.prototype, 'start').mockResolvedValue({
      link: 'buntu://pair?v=1&s=test', session: 'test', expiresAt: 9999999999,
      qrSize: 1, qrModules: '1', host: '192.0.2.1', port: 8001, tvName: 'TV test',
    });
    vi.spyOn(PairingService.prototype, 'stop').mockImplementation(() => {});
    dispose = render(() => SourcesView({ onBack: vi.fn() }), container);
    for (let i = 0; i < 20; i++) await Promise.resolve();
    expect(container.textContent).toContain('Ajouter cette TV à votre foyer');
    expect(container.querySelector('canvas')).not.toBeNull();
    expect(container.querySelector('#btn-salon-create')).toBeNull();
    expect(container.textContent).not.toContain('Créer un salon');
    expect(create).not.toHaveBeenCalled();
  });

  it('edits connection settings of a received source on this TV', async () => {
    const source: SourceRecord = { id: 81, uuid: 'received-source', name: 'Compte du foyer', source_type: 'xtream', server: 'https://shared.invalid', username: 'shared-user', password: 'shared-password', item_count: 12 };
    vi.spyOn(Database.getInstance(), 'getSources').mockResolvedValue([source]);
    const save = vi.spyOn(CndEngine.getInstance(), 'updateLocalSource').mockResolvedValue();
    dispose = render(() => SourcesView({ onBack: vi.fn() }), container);
    for (let i = 0; i < 20; i++) await Promise.resolve();
    (container.querySelector('#source-edit-81') as HTMLButtonElement).click();
    expect(container.textContent).toContain('Ces coordonnées restent locales');
    expect((container.querySelector('#edit-password') as HTMLInputElement).type).toBe('password');
    for (const [id, value] of [['edit-host', 'https://local.invalid'], ['edit-user', 'local-user'], ['edit-password', 'local-password']]) {
      const input = container.querySelector(`#${id}`) as HTMLInputElement;
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
    (container.querySelector('#edit-save') as HTMLButtonElement).click();
    for (let i = 0; i < 20; i++) await Promise.resolve();
    expect(save).toHaveBeenCalledWith(81, { source_type: 'xtream', server: 'https://local.invalid', username: 'local-user', password: 'local-password', url: '' });
    expect(container.querySelector('#edit-password')).toBeNull();
    expect(source.password).toBe('shared-password');
  });

});
