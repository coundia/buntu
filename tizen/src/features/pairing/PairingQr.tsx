import { Component, createEffect } from 'solid-js';

export interface PairingQrProps {
  size: number;
  /** Row-major '0'/'1' modules (from the Rust QR encoder). */
  modules: string;
  /** Side of the square, in CSS pixels. */
  pixels?: number;
  /** The link the code holds, kept as a data attribute so a test rig can read what a camera would. */
  link?: string;
}

/** Empty white border, in modules, that every QR scanner (Google code scanner included) needs around the code. */
export const QR_QUIET_ZONE = 4;

/**
 * Pixel layout of a QR code: `quiet` modules of white on every side and an integer `scale` per module,
 * so the edges stay sharp. `side` is the canvas size, `target` the size it is shown at.
 */
export function layoutQr(size: number, pixels = 320) {
  const total = size + QR_QUIET_ZONE * 2;
  const scale = Math.max(1, Math.floor(pixels / total));
  return { quiet: QR_QUIET_ZONE, total, scale, side: total * scale, target: pixels };
}

/**
 * Draws a QR code on a canvas: black modules on white with the 4-module quiet zone the scanners
 * need, and an integer scale so the edges stay sharp on a 4K screen.
 */
export const PairingQr: Component<PairingQrProps> = (props) => {
  let canvas!: HTMLCanvasElement;

  createEffect(() => {
    const n = props.size;
    const modules = props.modules;
    const { quiet, scale, side, target } = layoutQr(n, props.pixels);
    canvas.width = side;
    canvas.height = side;
    canvas.style.width = `${target}px`;
    canvas.style.height = `${target}px`;
    canvas.style.imageRendering = 'pixelated';
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.fillStyle = '#FFFFFF';
    ctx.fillRect(0, 0, side, side);
    ctx.fillStyle = '#000000';
    for (let y = 0; y < n; y++) {
      for (let x = 0; x < n; x++) {
        if (modules.charCodeAt(y * n + x) === 49) {
          ctx.fillRect((x + quiet) * scale, (y + quiet) * scale, scale, scale);
        }
      }
    }
  });

  return <canvas ref={canvas} data-pairing-link={props.link} role="img" aria-label="QR code à scanner avec le téléphone" style={{ "border-radius": "8px" }} />;
};
