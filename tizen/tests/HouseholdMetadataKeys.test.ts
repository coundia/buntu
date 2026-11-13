import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { exportHouseholdMetadataKeys, importHouseholdMetadataKeys } from '../src/core/sync/HouseholdAiCredentials';

describe('OMDb key shared inside the household', () => {
  let get: any;
  let set: any;
  let has: any;
  let post: any;
  beforeEach(() => {
    get = vi.spyOn(AiKeyStore.getInstance(), 'getApiKey').mockResolvedValue(null);
    set = vi.spyOn(AiKeyStore.getInstance(), 'setApiKey').mockResolvedValue();
    has = vi.spyOn(AiKeyStore.getInstance(), 'hasApiKey').mockResolvedValue(false);
    post = vi.spyOn(WorkerBridge.getInstance(), 'post').mockImplementation(async (_t: any, p: any) => p.keys.filter((k: any) => !p.existingServices.includes(k.service)));
  });
  afterEach(() => vi.restoreAllMocks());

  it('exports the saved key, and nothing when there is none', async () => {
    expect(await exportHouseholdMetadataKeys()).toEqual([]);
    get.mockResolvedValue('test-only-value');
    expect(await exportHouseholdMetadataKeys()).toEqual([{ service: 'omdb', api_key: 'test-only-value' }]);
    expect(get).toHaveBeenCalledWith('omdb');
  });

  it('stores a received key in the vault slot of OMDb, after the shared rule accepted it', async () => {
    expect(await importHouseholdMetadataKeys([{ service: 'omdb', api_key: 'test-only-value' }])).toBe(1);
    expect(post).toHaveBeenCalledWith('SYNC_MISSING_METADATA_KEYS', { keys: [{ service: 'omdb', api_key: 'test-only-value' }], existingServices: [] });
    expect(set).toHaveBeenCalledWith('test-only-value', 'omdb');
  });

  it('never replaces a key already on this TV', async () => {
    has.mockResolvedValue(true);
    expect(await importHouseholdMetadataKeys([{ service: 'omdb', api_key: 'other-value' }])).toBe(0);
    expect(set).not.toHaveBeenCalled();
  });
});
