import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { UiSounds } from '../src/core/audio/UiSounds';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { SettingsView } from '../src/features/settings/SettingsView';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { WorkerBridge } from '../src/worker/worker-bridge';

const sounds = UiSounds.getInstance();
let playSound: ReturnType<typeof vi.fn>;

beforeEach(() => {
  playSound = vi.fn();
  (globalThis as any).tizen = { tvaudiocontrol: { playSound } };
  sounds.setEnabled(true);
  sounds.setSuppressed(false);
});
afterEach(() => { vi.useRealTimers(); delete (globalThis as any).tizen; sounds.setEnabled(true); sounds.setSuppressed(false); vi.restoreAllMocks(); });

describe('System navigation sounds', () => {
  it('plays the Samsung system beep that matches the action', () => {
    sounds.play('select', 1000);
    sounds.play('back', 2000);
    sounds.play('move', 3000);
    expect(playSound.mock.calls.map((c) => c[0])).toEqual(['SELECT', 'BACK', 'MOVE']);
  });

  it('does not stack sounds when an arrow is held', () => {
    sounds.play('move', 5000);
    sounds.play('move', 5030);
    sounds.play('move', 5060);
    sounds.play('move', 5100);
    expect(playSound).toHaveBeenCalledTimes(2);
  });

  it('is silent when switched off, over the full-screen video, or when the TV has no such API', () => {
    sounds.setEnabled(false);
    sounds.play('select', 10_000);
    sounds.setEnabled(true);
    sounds.setSuppressed(true);
    sounds.play('select', 11_000);
    sounds.setSuppressed(false);
    expect(playSound).not.toHaveBeenCalled();
    delete (globalThis as any).tizen;
    expect(sounds.isAvailable()).toBe(false);
    expect(() => sounds.play('select', 12_000)).not.toThrow();
  });

  it('never lets a failing API reach the screen', () => {
    playSound.mockImplementation(() => { throw new Error('refused'); });
    expect(() => sounds.play('select', 20_000)).not.toThrow();
  });

  it('maps remote keys: OK selects, Back goes back, arrows move, other keys are silent', () => {
    sounds.onHandledKey('ENTER');
    sounds.onHandledKey('NUM_5');
    expect(playSound.mock.calls.map((c) => c[0])).toEqual(['SELECT']);
  });
});

describe('The remote key handler plays the sound of a key the app handled', () => {
  const press = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));
  beforeEach(() => {
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
  });
  afterEach(() => { RemoteKeyHandler.getInstance().destroy(); spatialNav.setGrid([]); });

  it('OK on a focusable item plays SELECT; a key nobody handles plays nothing', () => {
    const onSelect = vi.fn();
    spatialNav.setGrid([[{ id: 'a', onSelect }]]);
    vi.useFakeTimers();
    vi.setSystemTime(100_000);
    press(13);
    expect(onSelect).toHaveBeenCalled();
    expect(playSound.mock.calls.map((c) => c[0])).toEqual(['SELECT']);
    vi.setSystemTime(101_000);
    press(415); // Play: no handler
    expect(playSound).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });
});

describe('Settings: the sounds switch', () => {
  const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); await new Promise((r) => setTimeout(r, 20)); };
  let dispose = () => {};
  beforeEach(async () => {
    vi.spyOn(AiKeyStore.getInstance(), 'getMaskedKey').mockResolvedValue(null);
    vi.spyOn(WorkerBridge.getInstance(), 'getVersion').mockResolvedValue('test');
    vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdInfo').mockReturnValue({ household_id: 'h', household_name: 'Maison', created_at: 1 });
    vi.spyOn(HouseholdStore.getInstance(), 'getPairedDevices').mockReturnValue([]);
    vi.spyOn(LocalSyncService.getInstance(), 'onStatusChange').mockImplementation(() => () => {});
    RemoteKeyHandler.getInstance().init();
    dispose = render(() => SettingsView({}), document.body);
    await settle();
    (document.getElementById('settings-system') as HTMLButtonElement).click();
    await settle();
  });
  afterEach(() => { dispose(); document.body.innerHTML = ''; });

  it('turns the sounds off and on, and says when the TV has no system sounds', async () => {
    const button = () => document.getElementById('btn-ui-sounds') as HTMLButtonElement;
    expect(button().textContent).toContain('Activés');
    button().click();
    await settle();
    expect(sounds.isEnabled()).toBe(false);
    expect(button().textContent).toContain('Désactivés');
    button().click();
    await settle();
    expect(sounds.isEnabled()).toBe(true);
  });
});
