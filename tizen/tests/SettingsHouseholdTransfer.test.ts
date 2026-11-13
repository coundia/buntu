import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { SettingsView } from '../src/features/settings/SettingsView';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { spatialNav } from '../src/ui/design/SpatialNav';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
let dispose = () => {};
let connected = true;
beforeEach(() => {
  connected = true;
  vi.spyOn(AiKeyStore.getInstance(), 'getMaskedKey').mockResolvedValue(null);
  vi.spyOn(WorkerBridge.getInstance(), 'getVersion').mockResolvedValue('test');
  vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdInfo').mockReturnValue({ household_id: 'test-house', household_name: 'Maison', created_at: 1 });
  vi.spyOn(HouseholdStore.getInstance(), 'getPairedDevices').mockReturnValue([]);
  vi.spyOn(LocalSyncService.getInstance(), 'onStatusChange').mockImplementation((listener) => {
    listener({ connected, pairedDeviceCount: 0 });
    return () => {};
  });
  vi.spyOn(LocalSyncService.getInstance(), 'requestFullSync').mockResolvedValue();
  vi.spyOn(LocalSyncService.getInstance(), 'sendHouseholdDataDelta').mockResolvedValue();
  vi.spyOn(LocalSyncService.getInstance(), 'triggerSync').mockResolvedValue();
});
afterEach(() => { dispose(); document.body.innerHTML = ''; vi.restoreAllMocks(); });
async function mount() {
  dispose = render(() => SettingsView({ section: 'household' }), document.body);
  await settle();
}

describe('Tizen receive and send household data', () => {
  it('keeps technical details and leaving the household behind More options', async () => {
    await mount();
    expect(document.getElementById('btn-hh-leave')).toBeNull();
    expect(document.body.textContent).not.toContain('Identifiant sécurisé');
    (document.getElementById('btn-hh-details') as HTMLButtonElement).click();
    expect(document.getElementById('btn-hh-leave')).not.toBeNull();
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009 }));
    expect(document.getElementById('btn-hh-leave')).toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('btn-hh-details');
  });

  it('opens one settings section at a time and BACK restores its menu choice', async () => {
    const onProfiles = vi.fn();
    dispose = render(() => SettingsView({ onProfiles }), document.body);
    await settle();
    expect(document.querySelectorAll('.buntu-settings-choice')).toHaveLength(4);
    expect(document.getElementById('btn-ai-provider')).toBeNull();
    expect(document.getElementById('btn-single-conn')).toBeNull();
    expect(document.getElementById('btn-hh-send')).toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('settings-connection');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13 }));
    expect(document.getElementById('btn-single-conn')).not.toBeNull();
    expect(document.getElementById('btn-ai-provider')).toBeNull();
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009 }));
    expect(spatialNav.getCurrentFocusId()).toBe('settings-connection');
    (document.getElementById('settings-ai') as HTMLButtonElement).click();
    expect(document.getElementById('btn-ai-provider')).not.toBeNull();
    expect(document.getElementById('btn-single-conn')).toBeNull();
    (document.getElementById('settings-back') as HTMLButtonElement).click();
    expect(spatialNav.getCurrentFocusId()).toBe('settings-ai');
    (document.getElementById('settings-system') as HTMLButtonElement).click();
    expect(document.getElementById('btn-purge-cache')).not.toBeNull();
    expect(document.getElementById('btn-ai-provider')).toBeNull();
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009 }));
    expect(spatialNav.getCurrentFocusId()).toBe('settings-system');
    (document.getElementById('settings-profiles') as HTMLButtonElement).click();
    expect(onProfiles).toHaveBeenCalledTimes(1);
  });

  it('receives without exporting local data and removes the sync button', async () => {
    await mount();
    expect(document.querySelector('#btn-hh-sync')).toBeNull();
    expect(document.body.textContent).not.toContain('Synchroniser maintenant');
    (document.querySelector('#btn-hh-receive') as HTMLButtonElement).click();
    await settle();
    expect(LocalSyncService.getInstance().requestFullSync).toHaveBeenCalledTimes(1);
    expect(LocalSyncService.getInstance().sendHouseholdDataDelta).not.toHaveBeenCalled();
    expect(LocalSyncService.getInstance().triggerSync).not.toHaveBeenCalled();
    expect(document.body.textContent).toContain('Données demandées');
  });

  it('sends local data without requesting data back', async () => {
    await mount();
    (document.querySelector('#btn-hh-send') as HTMLButtonElement).click();
    await settle();
    expect(LocalSyncService.getInstance().sendHouseholdDataDelta).toHaveBeenCalledTimes(1);
    expect(LocalSyncService.getInstance().requestFullSync).not.toHaveBeenCalled();
    expect(document.body.textContent).toContain('Comptes et favoris envoyés');
  });

  it('does not report a transfer while disconnected', async () => {
    connected = false;
    await mount();
    (document.querySelector('#btn-hh-send') as HTMLButtonElement).click();
    await settle();
    expect(LocalSyncService.getInstance().sendHouseholdDataDelta).not.toHaveBeenCalled();
    expect(document.body.textContent).toContain('La TV n’est pas connectée');
  });

  it('shows a safe error and allows retry after a failed send', async () => {
    const send = vi.mocked(LocalSyncService.getInstance().sendHouseholdDataDelta);
    send.mockRejectedValueOnce(new Error('private details'));
    await mount();
    const button = document.querySelector('#btn-hh-send') as HTMLButtonElement;
    button.click();
    await settle();
    expect(document.body.textContent).toContain('L’envoi a échoué');
    expect(document.body.textContent).not.toContain('private details');
    expect(button.disabled).toBe(false);
    button.click();
    await settle();
    expect(send).toHaveBeenCalledTimes(2);
  });
});
