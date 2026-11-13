import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { ProfilesView } from '../src/features/profiles/ProfilesView';
import { spatialNav } from '../src/ui/design/SpatialNav';
const engine = vi.hoisted(() => ({
  getActiveProfile: () => ({ id: 2, name: 'Enfants', isKids: true, avatar: '' }),
  setProfile: vi.fn(), unlockAdult: vi.fn(() => false),
}));
vi.mock('../src/core/engine/CndEngine', () => ({ CndEngine: { getInstance: () => engine } }));
let dispose = () => {};
beforeEach(() => vi.clearAllMocks());
afterEach(() => { dispose(); document.body.innerHTML = ''; spatialNav.setGrid([]); });
const press = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));
describe('Simple Tizen profiles', () => {
  it('distinguishes the active profile from the one selected with the remote', () => {
    const onProfileChanged = vi.fn();
    dispose = render(() => ProfilesView({ onProfileChanged }), document.body);
    expect(document.querySelectorAll('.buntu-profile-card')).toHaveLength(2);
    expect(document.getElementById('field-pin')).toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('profile-2');
    press(37);
    expect(document.querySelectorAll('.buntu-profile-card.focused')).toHaveLength(1);
    expect(document.getElementById('profile-2')!.getAttribute('aria-pressed')).toBe('true');
    press(13);
    expect(engine.setProfile).toHaveBeenCalledWith(expect.objectContaining({ id: 1 }));
    expect(onProfileChanged).toHaveBeenCalledTimes(1);
  });
  it('opens parental controls on request and BACK closes them', () => {
    dispose = render(() => ProfilesView({ onProfileChanged: vi.fn() }), document.body);
    (document.getElementById('profile-parental') as HTMLButtonElement).click();
    expect(document.getElementById('field-pin')!.getAttribute('type')).toBe('password');
    expect(spatialNav.getCurrentFocusId()).toBe('field-pin');
    (document.getElementById('btn-unlock-pin') as HTMLButtonElement).click();
    expect(document.querySelector('[role="status"]')!.textContent).toBe('Code PIN incorrect.');
    press(10009);
    expect(document.getElementById('field-pin')).toBeNull();
    expect(spatialNav.getCurrentFocusId()).toBe('profile-parental');
  });
});
