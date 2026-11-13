import { describe, it, expect, vi, afterEach } from 'vitest';
import { render } from 'solid-js/web';
import { HouseholdJoinView } from '../src/features/pairing/HouseholdJoinView';
import { PairingEvents } from '../src/core/pairing/PairingService';
import { spatialNav } from '../src/ui/design/SpatialNav';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
let dispose = () => {};
afterEach(() => { dispose(); document.body.innerHTML = ''; vi.restoreAllMocks(); });

function mount(onJoined = vi.fn()) {
  let events!: PairingEvents;
  const service = { start: vi.fn(async () => ({
    link: 'buntu://pair?v=1&s=test', session: 'test', expiresAt: 9999999999,
    qrSize: 1, qrModules: '1', host: '192.0.2.1', port: 8001, tvName: 'TV test',
  })), stop: vi.fn() };
  dispose = render(() => HouseholdJoinView({ onBack: vi.fn(), onJoined,
    createService: (e) => { events = e; return service; },
  }), document.body);
  return { service, getEvents: () => events, onJoined };
}

describe('Add the TV to the phone household', () => {
  it('waits for confirmation before accepting the household and prevents double acceptance', async () => {
    const { getEvents, onJoined } = mount();
    await settle();
    let resolve!: () => void;
    const accept = vi.fn(() => new Promise<void>((r) => { resolve = r; }));
    getEvents().onHouseholdJoinRequest!({ from: 'Téléphone', householdId: 'test-house', householdName: 'Maison', accept, refuse: vi.fn() });
    expect(spatialNav.getCurrentFocusId()).toBe('household-qr-refuse');
    expect(accept).not.toHaveBeenCalled();
    const button = document.querySelector('#household-qr-accept') as HTMLButtonElement;
    button.click(); button.click();
    expect(accept).toHaveBeenCalledTimes(1);
    expect(onJoined).not.toHaveBeenCalled();
    resolve(); await settle();
    expect(onJoined).toHaveBeenCalledTimes(1);
    expect(spatialNav.isModalOpen()).toBe(false);
  });

  it('refuses without joining and renews an expired confirmation', async () => {
    const { getEvents, service, onJoined } = mount();
    await settle();
    const refuse = vi.fn(async () => {});
    const request = { from: 'Téléphone', householdId: 'test-house', householdName: 'Maison', accept: vi.fn(), refuse };
    getEvents().onHouseholdJoinRequest!(request);
    (document.querySelector('#household-qr-refuse') as HTMLButtonElement).click();
    await settle();
    expect(refuse).toHaveBeenCalledTimes(1);
    expect(onJoined).not.toHaveBeenCalled();
    getEvents().onHouseholdJoinRequest!(request);
    getEvents().onClosed('expired');
    await settle();
    expect(document.querySelector('#household-qr-accept')).toBeNull();
    expect(spatialNav.isModalOpen()).toBe(false);
    expect(service.start).toHaveBeenCalledTimes(3);
  });

  it('does not report success when the pairing service reports an error', async () => {
    const { getEvents, onJoined } = mount();
    await settle();
    getEvents().onHouseholdJoinRequest!({ from: 'Téléphone', householdId: 'test-house', householdName: 'Maison',
      accept: vi.fn(async () => { getEvents().onError('private details'); }), refuse: vi.fn(),
    });
    (document.querySelector('#household-qr-accept') as HTMLButtonElement).click();
    await settle();
    expect(onJoined).not.toHaveBeenCalled();
    expect(document.body.textContent).not.toContain('private details');
    expect(document.querySelector('[role="alert"]')?.textContent).toContain('La connexion au téléphone a échoué');
  });
});
