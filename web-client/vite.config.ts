import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: '../dist-tmp',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'chunk-[name].js',
        assetFileNames: (info) => {
          const name = info.name ?? 'asset';
          if (name.endsWith('.css')) return 'app.css';
          return name;
        },
      },
    },
  },
});
