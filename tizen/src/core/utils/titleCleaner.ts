/**
 * CND IPTV Tizen - Universal Media Title Normalizer
 *
 * Strips technical IPTV noise, language tags, country prefixes, resolutions,
 * codecs, and container tags to extract clean, genuine titles for Movies,
 * Series, and Live TV channels.
 */

export interface CleanTitleResult {
  clean: string;
  year?: number;
}

/**
 * Regex matching leading provider and country prefixes:
 * Examples: "EAR - ", "EN - ", "AF: ", "FR | ", "UK: ", "[FR] ", "|FR| ", "(4K) "
 */
const LEADING_PREFIX_RE = /^(?:\s*(?:\|[^|]{1,14}\||\[[^\]]{1,14}\]|\((?:[A-Za-z0-9]{2,8})\)|[A-Za-z]{2,5}\s*[-:|•])\s*)+/i;

/**
 * Regex matching bracketed tags such as [1080p], (US), (FR), [MULTI], etc.
 */
const BRACKET_TAG_RE = /[\(\[\{]\s*(?:FR|EN|US|UK|AR|ES|DE|IT|PT|VF|VFF|VFQ|VFI|VF2|VOSTFR|VOST|MULTI|MULTILANG|TRUEFRENCH|FRENCH|SUBFRENCH|FHD|UHD|4K|8K|HD|SD|HEVC|H\.?265|H\.?264|X265|X264|1080P|720P|2160P|HDR|WEB-?DL|BLURAY|CM|MA|TZ|[A-Z]{2})\s*[\)\]\}]/gi;

/**
 * Regex matching technical noise words
 */
const NOISE_WORDS_RE = /\b(?:FHD|UHD|4K|8K|HEVC|H\.?265|H\.?264|X265|X264|1080P|720P|2160P|480P|HDR10\+?|HDR|VOSTFR|TRUEFRENCH|SUBFRENCH|FRENCH|MULTILANG|MULTI|VFF|VFQ|VFI|VF2|VF|WEBDL|WEB-DL|WEBRIP|BLURAY|BDRIP|HDTV|RAW|VIP)\b/gi;

/**
 * Cleans a raw IPTV name into a human-readable title and extracts the release year.
 */
export function cleanMediaTitle(raw: string): CleanTitleResult {
  if (!raw || typeof raw !== 'string') {
    return { clean: '' };
  }

  let working = raw.trim();
  let extractedYear: number | undefined;

  // 1. Extract bracketed year (19xx or 20xx)
  const yrBracketMatch = working.match(/[\(\[\{]\s*(19\d{2}|20\d{2})\s*[\)\]\}]/);
  if (yrBracketMatch) {
    extractedYear = parseInt(yrBracketMatch[1], 10);
    working = working.replace(/[\(\[\{]\s*(?:19\d{2}|20\d{2})\s*[\)\]\}]/g, ' ');
  }

  // 2. Remove leading provider tags: e.g. "EAR - ", "EN - ", "AF: ", "FR | ", "UK: ", "[FR] "
  working = working.replace(LEADING_PREFIX_RE, '');

  // 3. Remove bracket tags like [1080p], (US), (FR), [MULTI], etc.
  working = working.replace(BRACKET_TAG_RE, ' ');

  // 4. Convert dots or underscores to spaces if title contains no spaces
  if (!working.includes(' ') && (working.includes('.') || working.includes('_'))) {
    working = working.replace(/[._]/g, ' ');
  }

  // 5. Remove standalone technical noise words (1080p, 4k, bluray, etc.)
  working = working.replace(NOISE_WORDS_RE, ' ');

  // 6. Extract trailing year if not found yet
  if (!extractedYear) {
    const yrTrailingMatch = working.match(/(?:[\s._-]+)(19\d{2}|20\d{2})\s*$/);
    if (yrTrailingMatch) {
      extractedYear = parseInt(yrTrailingMatch[1], 10);
      working = working.replace(/(?:[\s._-]+)(19\d{2}|20\d{2})\s*$/, '');
    }
  }

  // 7. Strip trailing/leading punctuation, hyphens, colons, bars, and collapse whitespace
  working = working
    .replace(/^[-:|•_\s]+|[-:|•_\s]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  return {
    clean: working || raw.trim(),
    year: extractedYear,
  };
}
