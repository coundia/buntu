import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { SettingsView } from '../src/features/settings/SettingsView';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const settle = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 20)); };
let dispose = () => {};
let setKey: any;

beforeEach(async () => {
  vi.spyOn(AiKeyStore.getInstance(), 'getMaskedKey').mockResolvedValue(null);
  setKey = vi.spyOn(AiKeyStore.getInstance(), 'setApiKey').mockResolvedValue();
  vi.spyOn(WorkerBridge.getInstance(), 'getVersion').mockResolvedValue('test');
  vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdInfo').mockReturnValue({ household_id: 'h', household_name: 'Maison', created_at: 1 });
  vi.spyOn(HouseholdStore.getInstance(), 'getPairedDevices').mockReturnValue([]);
  vi.spyOn(LocalSyncService.getInstance(), 'onStatusChange').mockImplementation(() => () => {});
  RemoteKeyHandler.getInstance().init();
  dispose = render(() => SettingsView({}), document.body);
  await settle();
  (document.getElementById('settings-ai') as HTMLButtonElement).click();
  await settle();
});
afterEach(() => { dispose(); document.body.innerHTML = ''; vi.restoreAllMocks(); });

const cycleToGemini = async () => {
  (document.getElementById('btn-ai-provider') as HTMLButtonElement).click(); // local_only -> gemini
  await settle();
};
const press = (id: string) => (document.getElementById(id) as HTMLButtonElement).click();
const letter = (c: string) => [...document.querySelectorAll('.buntu-kb-key')].find((b) => b.textContent === c) as HTMLButtonElement;

describe('Assistant screen on the TV', () => {
  it('no longer offers to send the key from a phone by QR code: the household syncs it', async () => {
    await cycleToGemini();
    expect(document.getElementById('btn-ai-receive-key')).toBeNull();
    expect(document.body.textContent).not.toContain('Envoyer depuis le téléphone');
    expect(document.body.textContent).toContain('se synchronise automatiquement avec votre foyer');
  });

  it('types the key with the on-screen keyboard and saves it once validated', async () => {
    await cycleToGemini();
    spatialNav.setFocusById('ai-key-input');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13 })); // OK
    await settle();
    expect(document.querySelector('.buntu-kb')).not.toBeNull();
    for (const c of 'aiza') letter(c).click();
    press('kb-ok');
    await settle();
    expect(document.querySelector('.buntu-kb')).toBeNull();
    expect(setKey).toHaveBeenCalledTimes(1);
    expect(String(setKey.mock.calls[0][0]).toLowerCase()).toBe('aiza');
  });

  it('BACK on the keyboard keeps the panel open and saves nothing', async () => {
    await cycleToGemini();
    spatialNav.setFocusById('ai-key-input');
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 13 }));
    await settle();
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009 }));
    await settle();
    expect(document.querySelector('.buntu-kb')).toBeNull();
    expect(document.getElementById('btn-ai-provider')).not.toBeNull();
    expect(setKey).not.toHaveBeenCalled();
  });
});
