/**
 * CND IPTV Tizen - Daily AI Usage & Quota Tracker (PRD 40 § 6.3 & § 7)
 */

const USAGE_KEY = 'cnd_ai_usage';

interface UsageRecord {
  date: string; // YYYY-MM-DD
  counts: Record<string, number>;
}

function getTodayString(): string {
  const now = new Date();
  return now.toISOString().slice(0, 10);
}

function loadUsage(): UsageRecord {
  const today = getTodayString();
  try {
    const raw = localStorage.getItem(USAGE_KEY);
    if (!raw) return { date: today, counts: {} };
    const parsed = JSON.parse(raw);
    if (parsed.date !== today) {
      // New day: reset counters
      const fresh: UsageRecord = { date: today, counts: {} };
      localStorage.setItem(USAGE_KEY, JSON.stringify(fresh));
      return fresh;
    }
    return parsed;
  } catch {
    return { date: today, counts: {} };
  }
}

function saveUsage(record: UsageRecord): void {
  try {
    localStorage.setItem(USAGE_KEY, JSON.stringify(record));
  } catch {
    // Ignore storage errors
  }
}

export function getCallsToday(providerKey: string): number {
  const usage = loadUsage();
  return usage.counts[providerKey] ?? 0;
}

export function recordCall(providerKey: string): number {
  const usage = loadUsage();
  const current = usage.counts[providerKey] ?? 0;
  const updated = current + 1;
  usage.counts[providerKey] = updated;
  saveUsage(usage);
  return updated;
}

export function isDailyCapReached(providerKey: string, cap: number, isLocal: boolean): boolean {
  if (isLocal) {
    // No cap for local LAN servers (Ollama, LM Studio)
    return false;
  }
  const count = getCallsToday(providerKey);
  return count >= cap;
}

export function resetUsage(): void {
  const today = getTodayString();
  saveUsage({ date: today, counts: {} });
}

