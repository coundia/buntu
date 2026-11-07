/**
 * Helper to extract icons, flags, and display counts for IPTV categories.
 */

export interface CategoryMeta {
  icon: string;
  isFlag: boolean;
  label: string;
}

export function getCategoryMeta(categoryName: string): CategoryMeta {
  const raw = categoryName.trim();
  const upper = raw.toUpperCase();

  // 1. Favorites
  if (upper.includes('FAVORIS') || upper.includes('FAVORITE') || upper.includes('★')) {
    return { icon: '★', isFlag: false, label: raw };
  }

  // 2. Countries & Regions
  if (upper.includes('FRANCE') || upper.startsWith('FR')) return { icon: '🇫🇷', isFlag: true, label: raw };
  if (upper.includes('UNITED STATES') || upper.includes('USA') || upper.startsWith('US')) return { icon: '🇺🇸', isFlag: true, label: raw };
  if (upper.includes('UNITED KINGDOM') || upper.includes('UK') || upper.startsWith('EN')) return { icon: '🇬🇧', isFlag: true, label: raw };
  if (upper.includes('GERMANY') || upper.includes('DEUTSCH') || upper.startsWith('DE')) return { icon: '🇩🇪', isFlag: true, label: raw };
  if (upper.includes('ITALY') || upper.includes('ITALIA') || upper.startsWith('IT')) return { icon: '🇮🇹', isFlag: true, label: raw };
  if (upper.includes('SPAIN') || upper.includes('ESPANA') || upper.startsWith('ES')) return { icon: '🇪🇸', isFlag: true, label: raw };
  if (upper.includes('PORTUGAL') || upper.startsWith('PT')) return { icon: '🇵🇹', isFlag: true, label: raw };
  if (upper.includes('BRAZIL') || upper.startsWith('BR')) return { icon: '🇧🇷', isFlag: true, label: raw };
  if (upper.includes('AFRICA') || upper.startsWith('AF')) return { icon: '🌍', isFlag: false, label: raw };
  if (upper.includes('CAMEROON')) return { icon: '🇨🇲', isFlag: true, label: raw };
  if (upper.includes('SENEGAL')) return { icon: '🇸🇳', isFlag: true, label: raw };
  if (upper.includes('COTE D') || upper.includes('COTEDIVOIRE')) return { icon: '🇨🇮', isFlag: true, label: raw };
  if (upper.includes('NIGERIA')) return { icon: '🇳🇬', isFlag: true, label: raw };
  if (upper.includes('SOUTH AFRICA')) return { icon: '🇿🇦', isFlag: true, label: raw };
  if (upper.includes('UKRAINE') || upper.startsWith('UA')) return { icon: '🇺🇦', isFlag: true, label: raw };
  if (upper.includes('TURKEY') || upper.startsWith('TR')) return { icon: '🇹🇷', isFlag: true, label: raw };
  if (upper.includes('ARABIC') || upper.startsWith('AR')) return { icon: '🇸🇦', isFlag: true, label: raw };
  if (upper.includes('CANADA') || upper.startsWith('CA')) return { icon: '🇨🇦', isFlag: true, label: raw };

  // 3. Genres & Themes
  if (upper.includes('SPORT')) return { icon: '⚽', isFlag: false, label: raw };
  if (upper.includes('CINEMA') || upper.includes('FILM') || upper.includes('MOVIE')) return { icon: '🎬', isFlag: false, label: raw };
  if (upper.includes('SERIE')) return { icon: '🍿', isFlag: false, label: raw };
  if (upper.includes('NEWS') || upper.includes('INFO') || upper.includes('ACTU')) return { icon: '📰', isFlag: false, label: raw };
  if (upper.includes('DOC') || upper.includes('DISCOVERY')) return { icon: '🦁', isFlag: false, label: raw };
  if (upper.includes('KID') || upper.includes('ENFANT') || upper.includes('ANIMATION')) return { icon: '🧸', isFlag: false, label: raw };
  if (upper.includes('MUSIC') || upper.includes('MUSIQUE')) return { icon: '🎵', isFlag: false, label: raw };

  return { icon: '📺', isFlag: false, label: raw };
}

/**
 * Generate a consistent pseudo-random view count string based on item id
 * e.g. "+8.2M", "1.7M", "850K"
 */
export function formatViewCount(id: number): string {
  const base = ((id * 9301 + 49297) % 233280) / 233280;
  if (base > 0.6) {
    const m = (1.2 + base * 7.5).toFixed(1);
    return `+${m}M vues`;
  }
  if (base > 0.2) {
    const k = Math.floor(200 + base * 700);
    return `${k}K vues`;
  }
  return '+1.5M vues';
}
