import { defineConfig } from 'vite';
import pkg from './package.json';

export default defineConfig({
  build: {
    // esbuild на Windows не удаляет временный файл для крупного чанка,
    // поэтому минифицируем terser и не транспилируем современный синтаксис.
    target: 'esnext',
    minify: 'terser',
  },
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_DATE__: JSON.stringify(new Date().toISOString()),
  },
});
