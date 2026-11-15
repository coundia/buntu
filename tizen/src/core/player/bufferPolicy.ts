/**
 * How much video the TV keeps ready (AVPlay `PLAYER_BUFFER_FOR_PLAY` before starting, `PLAYER_BUFFER_FOR_RESUME` after
 * a loading pause), in seconds of video.
 *  - Live: small by default, with a local preference for a larger buffer.
 *  - Film or episode: larger, so a dip in the server's or the Wi-Fi's speed does not pause the picture.
 *  - 4K film: larger still, because a 4K stream is 25 to 80 Mb/s and 4 to 6 s of it is gone in a moment.
 * VOD defaults stay below 20 s to limit TV memory usage.
 */
export interface BufferPolicy {
  play: number;
  resume: number;
}

export interface BufferHint {
  /** The film is known to be 4K (from its title or its category). */
  uhd?: boolean;
}

export const LIVE_BUFFER: BufferPolicy = { play: 2, resume: 3 };
export const VOD_BUFFER: BufferPolicy = { play: 8, resume: 10 };
export const UHD_BUFFER: BufferPolicy = { play: 12, resume: 18 };

export const LIVE_BUFFER_CHOICES = [0, 25, 30] as const;
export type LiveBufferSeconds = typeof LIVE_BUFFER_CHOICES[number];

const LIVE_BUFFER_STORAGE_KEY = 'buntu.liveBufferSeconds';

export function getLiveBufferSeconds(): LiveBufferSeconds {
  try {
    const value = localStorage.getItem(LIVE_BUFFER_STORAGE_KEY);
    return LIVE_BUFFER_CHOICES.find((seconds) => String(seconds) === value) ?? 0;
  } catch {
    return 0;
  }
}

export function setLiveBufferSeconds(seconds: LiveBufferSeconds): LiveBufferSeconds {
  try {
    localStorage.setItem(LIVE_BUFFER_STORAGE_KEY, String(seconds));
  } catch {
    // Storage can be unavailable on a TV in restricted mode.
  }
  return getLiveBufferSeconds();
}

export function liveBufferTimeoutSeconds(seconds: LiveBufferSeconds): number {
  // Allow more wall-clock time than the requested duration of media.
  return seconds ? seconds + 10 : 0;
}

export function liveBufferWatchdogMs(timeoutSeconds: number, defaultMs: number): number {
  return timeoutSeconds ? (timeoutSeconds + 2) * 1000 : defaultMs;
}

export function bufferPolicy(isLive: boolean, hint: BufferHint = {}, liveSeconds: LiveBufferSeconds = 0): BufferPolicy {
  if (isLive) return liveSeconds ? { play: liveSeconds, resume: liveSeconds } : LIVE_BUFFER;
  return hint.uhd ? UHD_BUFFER : VOD_BUFFER;
}
