import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render } from 'solid-js/web';
import { SourcesView } from '../src/features/sources/SourcesView';
import { Database, SourceRecord } from '../src/core/storage/Database';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

describe('SourcesView Integration (PRD 39)', () => {
  let container: HTMLDivElement;
  let dispose: () => void = () => {};

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
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

    expect(container.textContent).toContain('Gestion des abonnements & sources');
    expect(container.textContent).toContain('Mon Abonnement Xtream');
    expect(container.textContent).toContain('1400 chaînes / flux');
    expect(container.textContent).toContain('xtream.example:8080');

    // Click on "Ajouter depuis le téléphone"
    const addPhoneBtn = container.querySelector('#btn-add-phone') as HTMLButtonElement;
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
    expect(container.textContent).toContain('Gestion des abonnements & sources');
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
    expect(container.textContent).toContain('Gestion des abonnements & sources');
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
});
