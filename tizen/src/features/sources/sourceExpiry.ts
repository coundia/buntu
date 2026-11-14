import type { SourceRecord } from '../../core/storage/Database';

export interface SourceExpiryInfo {
  exp: number;
  daysLeft: number;
  dateStr: string;
  status: 'expired' | 'soon' | 'ok';
  label: string;
}

/**
 * Formats a source's Xtream expiration date and warning state for UI badges.
 */
export function describeSourceExpiry(
  source: Pick<SourceRecord, 'exp_date'>,
  nowSec: number = Math.floor(Date.now() / 1000)
): SourceExpiryInfo | null {
  const exp = source.exp_date && source.exp_date > 0 ? source.exp_date : 0;
  if (!exp) return null;

  const daysLeft = Math.ceil((exp - nowSec) / 86400);
  const dateStr = new Date(exp * 1000).toLocaleDateString('fr-FR');

  if (daysLeft <= 0) {
    return {
      exp,
      daysLeft,
      dateStr,
      status: 'expired',
      label: `⚠️ Expiré le ${dateStr}`,
    };
  }
  if (daysLeft <= 7) {
    return {
      exp,
      daysLeft,
      dateStr,
      status: 'soon',
      label: `⏳ Expire dans ${daysLeft} j (${dateStr})`,
    };
  }
  return {
    exp,
    daysLeft,
    dateStr,
    status: 'ok',
    label: `Valide jusqu’au ${dateStr}`,
  };
}
