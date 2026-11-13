/**
 * How much video the TV keeps ready (AVPlay `PLAYER_BUFFER_FOR_PLAY` before starting, `PLAYER_BUFFER_FOR_RESUME` after
 * a loading pause), in seconds of video.
 *  - Live: small, to switch channels fast (the stream cannot be fetched ahead anyway).
 *  - Film or episode: larger, so a dip in the server's or the Wi-Fi's speed does not pause the picture.
 *  - 4K film: larger still, because a 4K stream is 25 to 80 Mb/s and 4 to 6 s of it is gone in a moment.
 * Not more than 20 s: the TV has little memory.
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

export function bufferPolicy(isLive: boolean, hint: BufferHint = {}): BufferPolicy {
  if (isLive) return LIVE_BUFFER;
  return hint.uhd ? UHD_BUFFER : VOD_BUFFER;
}
