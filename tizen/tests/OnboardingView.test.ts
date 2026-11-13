import { afterEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { OnboardingView } from '../src/features/onboarding/OnboardingView';
import { PairingEvents, PairingService } from '../src/core/pairing/PairingService';
import { spatialNav } from '../src/ui/design/SpatialNav';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
let dispose = () => {};
afterEach(() => { dispose(); document.body.innerHTML = ''; vi.restoreAllMocks(); });

function mount() {
  let events!: PairingEvents;
  vi.spyOn(PairingService.prototype, 'start').mockImplementation(async function (this: any) {
    events = this.events;
    return { link: 'buntu://pair?v=1&s=test', session: 'test', expiresAt: 9999999999,
      qrSize: 1, qrModules: '1', host: '192.0.2.1', port: 8001, tvName: 'TV test' };
  });
  const stop = vi.spyOn(PairingService.prototype, 'stop').mockImplementation(() => {});
  const onComplete = vi.fn();
  dispose = render(() => OnboardingView({ onComplete }), document.body);
  return { onComplete, stop, getEvents: () => events };
}

describe('Welcome without an IPTV account', () => {
  it('shows the salon QR and completes only after accepting the phone household', async () => {
    const { onComplete, getEvents } = mount();
    await settle();
    expect(document.body.textContent).toContain('Ajouter cette TV à votre salon');
    expect(document.querySelector('canvas')).not.toBeNull();
    expect(document.body.textContent).not.toContain('Choisissez les comptes');
    expect(onComplete).not.toHaveBeenCalled();
    const accept = vi.fn(async () => {});
    getEvents().onHouseholdJoinRequest!({ from: 'Téléphone', householdId: 'test-house', householdName: 'Maison', accept, refuse: vi.fn() });
    expect(accept).not.toHaveBeenCalled();
    expect(spatialNav.getCurrentFocusId()).toBe('household-qr-refuse');
    (document.querySelector('#household-qr-accept') as HTMLButtonElement).click();
    await settle();
    expect(accept).toHaveBeenCalledTimes(1);
    expect(onComplete).toHaveBeenCalledTimes(1);
  });

  it('keeps manual source input available and stops the QR session when switching', async () => {
    const { onComplete, stop } = mount();
    await settle();
    (document.querySelector('#household-qr-manual') as HTMLButtonElement).click();
    await settle();
    expect(document.body.textContent).toContain('Ajouter un compte avec la télécommande');
    expect(stop).toHaveBeenCalled();
    expect(onComplete).not.toHaveBeenCalled();
  });

  it('allows exploring without joining a salon', async () => {
    const { onComplete } = mount();
    await settle();
    const skip = document.querySelector('#household-qr-back') as HTMLButtonElement;
    expect(skip.textContent).toContain('Passer / Explorer Buntu');
    skip.click();
    expect(onComplete).toHaveBeenCalledTimes(1);
  });
});
