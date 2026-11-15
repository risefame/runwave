import { defineConfig } from 'vite';
import pkg from './package.json';

export default defineConfig({
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_DATE__: JSON.stringify(new Date().toISOString()),
  },
  build: {
    // esbuild не может минифицировать чанки >1 МиБ на этой Windows-машине
    // (не удаляет временный файл, "Access is denied"), поэтому minify — terser.
    target: 'esnext',
    minify: 'terser',
  },
});
