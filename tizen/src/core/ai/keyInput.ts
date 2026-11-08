/**
 * Helpers for typing or pasting an API key on the TV, where mistakes are easy: the on-screen
 * keyboard and the clipboard add spaces, line breaks and quotes around what is entered.
 */

import type { AiProviderType } from './AiSettings';

/** What was typed or pasted, cleaned: no spaces or line breaks inside, no quotes around. */
export function normalizeApiKey(raw: string): string {
  let key = (raw || '').replace(/[\s​-‍﻿]+/g, '');
  key = key.replace(/^["'`“”‘’]+|["'`“”‘’]+$/g, '');
  // A pasted "Authorization: Bearer sk-…" or "x-goog-api-key: …" line: keep the key only.
  key = key.replace(/^(authorization:?bearer|bearer|x-goog-api-key:?|x-api-key:?)/i, '');
  return key;
}

export interface KeyShape {
  /** The key is plausible for this provider. A warning never blocks saving. */
  plausible: boolean;
  message: string;
}

/** A gentle check against the usual look of each provider's keys (they can change over time). */
export function describeKeyShape(provider: AiProviderType, key: string): KeyShape {
  if (!key) return { plausible: false, message: 'Aucune clé saisie.' };
  if (key.length < 16) {
    return { plausible: false, message: 'Cette clé semble trop courte : vérifiez qu’elle est complète.' };
  }
  if (provider === 'gemini' && !key.startsWith('AIza')) {
    return { plausible: false, message: 'Une clé Gemini commence en général par « AIza ».' };
  }
  if (provider === 'anthropic' && !key.startsWith('sk-ant-')) {
    return { plausible: false, message: 'Une clé Claude commence en général par « sk-ant- ».' };
  }
  if (provider === 'openai_compatible' && key.startsWith('AIza')) {
    return { plausible: false, message: 'Cette clé ressemble à une clé Gemini : choisissez le fournisseur Google Gemini.' };
  }
  return { plausible: true, message: 'La clé a le bon format.' };
}
