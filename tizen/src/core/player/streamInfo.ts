/**
 * What the TV decodes for the current stream (read from AVPlay's stream info), in words a viewer
 * understands: "1920×1080 · FHD · H.264 · AAC 5.1". Pure functions, no TV needed to test them.
 */

export interface StreamSummary {
  width: number;
  height: number;
  /** SD / HD / FHD / 4K, or '' when the size is unknown. */
  quality: 'SD' | 'HD' | 'FHD' | '4K' | '';
  videoCodec: string;
  audioCodec: string;
  /** "2.0", "5.1", "7.1"… or ''. */
  audioChannels: string;
  audioLanguage: string;
}

interface RawStreamInfo {
  type?: string;
  extra_info?: string | Record<string, unknown>;
}

/** A readable codec name from the FourCC / MIME string AVPlay reports. */
export function codecLabel(fourCC: string | undefined): string {
  const c = (fourCC || '').toLowerCase();
  if (!c) return '';
  if (c.includes('h264') || c.includes('avc')) return 'H.264';
  if (c.includes('h265') || c.includes('hevc') || c.includes('hvc')) return 'H.265';
  if (c.includes('mpeg2') || c.includes('mpeg-2') || c.includes('mp2v')) return 'MPEG-2';
  if (c.includes('vp9')) return 'VP9';
  if (c.includes('av1')) return 'AV1';
  if (c.includes('eac3') || c.includes('ec-3')) return 'E-AC3';
  if (c.includes('ac3') || c.includes('ac-3')) return 'AC3';
  if (c.includes('dts')) return 'DTS';
  if (c.includes('mp4a') || c.includes('aac')) return 'AAC';
  if (c.includes('opus')) return 'Opus';
  if (c.includes('audio/mpeg') || c.includes('mp3')) return 'MP3';
  return '';
}

/** 1 → "1.0", 2 → "2.0", 6 → "5.1", 8 → "7.1". */
export function channelsLabel(channels: string | number | undefined): string {
  const n = Number(channels);
  if (!(n > 0)) return '';
  if (n === 6) return '5.1';
  if (n === 8) return '7.1';
  return `${n}.0`;
}

export function qualityFromHeight(height: number): StreamSummary['quality'] {
  if (height >= 2000) return '4K';
  if (height >= 1000) return 'FHD';
  if (height >= 700) return 'HD';
  if (height > 0) return 'SD';
  return '';
}

function parseExtra(extra: RawStreamInfo['extra_info']): Record<string, unknown> {
  if (!extra) return {};
  if (typeof extra === 'object') return extra;
  try {
    return JSON.parse(extra);
  } catch {
    return {};
  }
}

/** Summarizes AVPlay's `getCurrentStreamInfo()`; null when it has nothing about the picture yet. */
export function summarizeStream(infos: RawStreamInfo[] | null | undefined): StreamSummary | null {
  if (!infos || infos.length === 0) return null;
  const summary: StreamSummary = {
    width: 0,
    height: 0,
    quality: '',
    videoCodec: '',
    audioCodec: '',
    audioChannels: '',
    audioLanguage: '',
  };
  let found = false;
  for (const info of infos) {
    const extra = parseExtra(info.extra_info);
    if (info.type === 'VIDEO') {
      summary.width = Number(extra.Width ?? extra.width) || 0;
      summary.height = Number(extra.Height ?? extra.height) || 0;
      summary.videoCodec = codecLabel(String(extra.fourCC ?? ''));
      found = true;
    } else if (info.type === 'AUDIO' && !summary.audioCodec) {
      summary.audioCodec = codecLabel(String(extra.fourCC ?? ''));
      summary.audioChannels = channelsLabel(extra.channels as string | number | undefined);
      summary.audioLanguage = String(extra.language ?? '').trim();
      found = true;
    }
  }
  if (!found) return null;
  summary.quality = qualityFromHeight(summary.height);
  return summary;
}
