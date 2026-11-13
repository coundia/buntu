import { AiKeyStore } from '../ai/AiKeyStore';
import { AiProviderType } from '../ai/AiSettings';
import { WorkerBridge } from '../../worker/worker-bridge';

interface HouseholdAiCredential {
  provider: AiProviderType;
  api_key: string;
}

/** Only carried inside the household envelope; never persisted in the catalogue or logs. */
export async function exportHouseholdAiCredentials(): Promise<HouseholdAiCredential[]> {
  const configs: HouseholdAiCredential[] = [];
  for (const provider of ['gemini', 'openai_compatible', 'anthropic'] as AiProviderType[]) {
    const key = await AiKeyStore.getInstance().getApiKey(provider);
    if (key) configs.push({ provider, api_key: key });
  }
  return configs;
}

let importQueue: Promise<void> = Promise.resolve();

/** Serialize arrivals from several household devices so they see the latest vault state. */
export function importHouseholdAiCredentials(configs: HouseholdAiCredential[] = []): Promise<number> {
  const operation = importQueue.then(() => applyHouseholdAiCredentials(configs));
  importQueue = operation.then(() => undefined, () => undefined);
  return operation;
}

/** Input is validated by cnd-domain when the encrypted envelope is opened. */
async function applyHouseholdAiCredentials(configs: HouseholdAiCredential[]): Promise<number> {
  let added = 0;
  const vault = AiKeyStore.getInstance();
  const existingProviders: AiProviderType[] = [];
  for (const config of configs) {
    if (await vault.hasApiKey(config.provider)) existingProviders.push(config.provider);
  }
  const accepted = await WorkerBridge.getInstance().post<HouseholdAiCredential[]>('SYNC_MISSING_AI_CREDENTIALS', { configs, existingProviders });
  for (const config of accepted) {
    await vault.setApiKey(config.api_key, config.provider);
    added++;
  }
  // Provider, quota and consent remain local; receiving a key never enables remote calls.
  return added;
}

interface HouseholdMetadataKey {
  service: 'omdb';
  api_key: string;
}

/** The OMDb key travels in `metadata_keys` of the household envelope, like the AI keys. */
export async function exportHouseholdMetadataKeys(): Promise<HouseholdMetadataKey[]> {
  const key = await AiKeyStore.getInstance().getApiKey('omdb');
  return key ? [{ service: 'omdb', api_key: key }] : [];
}

let metadataQueue: Promise<void> = Promise.resolve();

/** Additive: a key already saved on this TV is kept. Which keys are missing is decided by cnd-domain. */
export function importHouseholdMetadataKeys(keys: HouseholdMetadataKey[] = []): Promise<number> {
  const operation = metadataQueue.then(() => applyHouseholdMetadataKeys(keys));
  metadataQueue = operation.then(() => undefined, () => undefined);
  return operation;
}

async function applyHouseholdMetadataKeys(keys: HouseholdMetadataKey[]): Promise<number> {
  const vault = AiKeyStore.getInstance();
  const existingServices: string[] = [];
  for (const key of keys) {
    if (key.service === 'omdb' && (await vault.hasApiKey('omdb'))) existingServices.push('omdb');
  }
  const accepted = await WorkerBridge.getInstance().post<HouseholdMetadataKey[]>('SYNC_MISSING_METADATA_KEYS', { keys, existingServices });
  let added = 0;
  for (const key of accepted) {
    if (key.service !== 'omdb') continue;
    await vault.setApiKey(key.api_key, 'omdb');
    added++;
  }
  return added;
}
