import type { CapacitorConfig } from '@capacitor/cli';

/** Единственное место, где задан идентификатор приложения.
 *  После изменения обнови applicationId в android/app/build.gradle
 *  и Bundle Identifier в ios/App/App.xcodeproj. */
const APP_ID = 'com.runwave.game';

const env = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env;
const serverUrl = env?.CAP_SERVER_URL?.trim();

const config: CapacitorConfig = {
  appId: APP_ID,
  appName: 'Runwave',
  webDir: 'dist',
  // CAP_SERVER_URL задан — приложение грузит удалённую сборку (удобно для отладки).
  // Не задан — работает встроенная сборка из dist.
  ...(serverUrl
    ? {
        server: {
          url: serverUrl,
          cleartext: serverUrl.startsWith('http://'),
        },
      }
    : {}),
};

export default config;
