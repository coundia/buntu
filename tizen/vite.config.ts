import { defineConfig } from 'vite';
import solidPlugin from 'vite-plugin-solid';
import legacy from '@vitejs/plugin-legacy';
import path from 'path';
import { createRequire } from 'module';

const clampFallback = createRequire(import.meta.url)('./build-plugins/clampFallback.cjs');

export default defineConfig({
  // Relative paths: the TV opens the app from its package folder (file://), not from a web server root.
  base: './',
  plugins: [
    solidPlugin(),
    legacy({
      targets: ['chrome >= 56', 'firefox >= 52'],
      additionalLegacyPolyfills: ['regenerator-runtime/runtime'],
      renderLegacyChunks: true,
      polyfills: [
        'es.symbol',
        'es.promise',
        'es.array.iterator',
        'es.object.assign',
        'es.array.find',
        'es.array.find-index',
        'es.array.includes',
        'es.string.includes',
        'es.string.starts-with',
        'es.string.ends-with',
        'es.string.pad-start',
        'es.string.pad-end',
      ],
    }),
  ],
  css: {
    // Chromium 56-76 (Tizen 5/6) ignores clamp(): emit a plain fallback before each one.
    postcss: { plugins: [clampFallback()] },
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  worker: {
    // Classic (iife) worker: a TV on Tizen 5 or 6 cannot start a module worker.
    format: 'iife',
  },
  server: {
    port: 3000,
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
  },
  build: {
    target: 'chrome56',
    outDir: 'dist',
    assetsInlineLimit: 0,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].[hash].js',
        chunkFileNames: 'assets/[name].[hash].js',
        assetFileNames: 'assets/[name].[hash].[ext]',
      },
    },
  },
  test: {
    environment: 'jsdom',
  },
});
