/**
 * The same IPTV account, whatever device added it (PRD-41 § 3): the TV never stores it twice.
 *
 * The identity is computed in Rust (`cnd_domain::identity::account_identity_key`, through the worker):
 * Xtream server + username, written in any case or with a trailing slash; an M3U `get.php?username=…`
 * playlist counts as the Xtream account it reads. The `uuid` of a source is random per device, so it only
 * helps when it matches.
 */

import { WorkerBridge } from '../../worker/worker-bridge';
import type { SourceRecord } from '../storage/Database';

export type AccountLike = Pick<SourceRecord, 'source_type'> &
  Partial<Pick<SourceRecord, 'uuid' | 'server' | 'url' | 'username'>>;

/** Identity of an account; `null` when the WebAssembly domain cannot answer. */
export async function accountIdentity(account: AccountLike): Promise<string | null> {
  try {
    const key = await WorkerBridge.getInstance().post<string>('ACCOUNT_IDENTITY_KEY', {
      sourceType: account.source_type || '',
      server: account.server || '',
      url: account.url || '',
      username: account.username || '',
    });
    return typeof key === 'string' && key ? key : null;
  } catch {
    return null;
  }
}

/** The account of `existing` that IS `candidate` (same uuid, or same identity), if any. */
export async function findSameAccount<T extends AccountLike>(candidate: AccountLike, existing: T[]): Promise<T | undefined> {
  if (candidate.uuid) {
    const byUuid = existing.find((e) => e.uuid === candidate.uuid);
    if (byUuid) return byUuid;
  }
  const wanted = await accountIdentity(candidate);
  if (wanted) {
    for (const e of existing) {
      if ((await accountIdentity(e)) === wanted) return e;
    }
    return undefined;
  }
  // WebAssembly unavailable: the exact comparison the TV used before (never a merge it is unsure of).
  return existing.find(
    (e) =>
      e.source_type === candidate.source_type &&
      (e.server || e.url) === (candidate.server || candidate.url) &&
      (e.username || '') === (candidate.username || '')
  );
}
