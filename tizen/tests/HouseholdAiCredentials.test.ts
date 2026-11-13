import { afterEach, describe, expect, it, vi } from 'vitest';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { exportHouseholdAiCredentials, importHouseholdAiCredentials } from '../src/core/sync/HouseholdAiCredentials';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { getAiSettings } from '../src/core/ai/AiSettings';
afterEach(() => vi.restoreAllMocks());
describe('Household AI credentials', () => {
  it('serializes simultaneous arrivals so the second sender sees the key already stored', async () => {
    const vault = AiKeyStore.getInstance();
    let present = false;
    const configs = [{ provider: 'gemini' as const, api_key: 'test-only-value' }];
    vi.spyOn(vault, 'hasApiKey').mockImplementation(async () => present);
    const save = vi.spyOn(vault, 'setApiKey').mockImplementation(async () => { present = true; });
    const plan = vi.spyOn(WorkerBridge.getInstance(), 'post').mockResolvedValueOnce(configs).mockResolvedValueOnce([]);
    expect(await Promise.all([importHouseholdAiCredentials(configs), importHouseholdAiCredentials(configs)])).toEqual([1, 0]);
    expect(save).toHaveBeenCalledTimes(1);
    expect(plan).toHaveBeenLastCalledWith('SYNC_MISSING_AI_CREDENTIALS', { configs, existingProviders: ['gemini'] });
  });

  it('exports saved provider keys and fills only missing vault entries without enabling AI', async () => {
    const vault = AiKeyStore.getInstance();
    vi.spyOn(vault, 'getApiKey').mockImplementation(async (provider) => provider === 'gemini' ? 'test-only-value' : null);
    const plan = vi.spyOn(WorkerBridge.getInstance(), 'post').mockResolvedValue([{ provider: 'gemini', api_key: 'test-only-value' }]);
    const configs = await exportHouseholdAiCredentials();
    expect(configs.map((config) => config.provider)).toEqual(['gemini']);
    const before = getAiSettings();
    const hasKey = vi.spyOn(vault, 'hasApiKey').mockResolvedValue(false);
    const save = vi.spyOn(vault, 'setApiKey').mockResolvedValue();
    expect(await importHouseholdAiCredentials(configs)).toBe(1);
    expect(save).toHaveBeenCalledWith('test-only-value', 'gemini');
    expect(getAiSettings()).toEqual(before);
    hasKey.mockResolvedValue(true);
    save.mockClear();
    plan.mockResolvedValue([]);
    expect(await importHouseholdAiCredentials(configs)).toBe(0);
    expect(save).not.toHaveBeenCalled();
    expect(plan).toHaveBeenLastCalledWith('SYNC_MISSING_AI_CREDENTIALS', { configs, existingProviders: ['gemini'] });
  });
});
