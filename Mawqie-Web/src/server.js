// @ts-check
/** Mawqie-Web HTTP entrypoint. */
import http from 'node:http';
import { ConfigError, loadConfig } from './config.js';
import { createApp } from './app.js';
import { SigningKeyError } from './licensing/signing.js';
import { Store } from './store/store.js';

function main() {
  /** @type {import('./config.js').MawqieConfig} */
  let config;
  try {
    config = loadConfig(process.env);
  } catch (error) {
    if (error instanceof ConfigError) {
      // eslint-disable-next-line no-console
      console.error(error.message);
      process.exit(1);
    }
    throw error;
  }

  const store = new Store({ dataFile: config.dataFile });
  store.load();
  /** @type {ReturnType<typeof createApp>} */
  let app;
  try {
    app = createApp({ config, store });
  } catch (error) {
    if (error instanceof ConfigError || error instanceof SigningKeyError) {
      // Fail closed: never start with an unsafe config or a signing key the host
      // app cannot verify.
      // eslint-disable-next-line no-console
      console.error(`[mawqie] ${error.message}`);
      process.exit(1);
    }
    throw error;
  }

  if (config.ephemeralSecrets.length > 0) {
    // eslint-disable-next-line no-console
    console.warn(`[mawqie] using ephemeral ${config.ephemeralSecrets.join(', ')} — sessions/tokens will not survive a restart (development only).`);
  }
  if (!config.adminConfigured) {
    // eslint-disable-next-line no-console
    console.warn('[mawqie] admin is not configured (ADMIN_EMAIL / ADMIN_PASSWORD_HASH); admin login is disabled.');
  }
  if (config.licenseMode === 'local' && app.services.licensing.isEphemeralKey()) {
    // eslint-disable-next-line no-console
    console.warn('[mawqie] using an ephemeral license signing key — issued licenses become unverifiable after a restart.');
  }

  const server = http.createServer((req, res) => {
    void app.handle(req, res).catch((error) => {
      // eslint-disable-next-line no-console
      console.error(`[mawqie] unhandled request error: ${/** @type {Error} */ (error).name}`);
      if (!res.headersSent) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'internal server error', code: 'internal_error' }));
      }
    });
  });

  server.listen(config.port, () => {
    const address = server.address();
    const boundPort = typeof address === 'object' && address ? address.port : config.port;
    let displayUrl = config.baseUrl;
    try {
      const parsed = new URL(config.baseUrl);
      parsed.port = String(boundPort);
      displayUrl = parsed.toString().replace(/\/$/, '');
    } catch {
      displayUrl = `${config.baseUrl}:${boundPort}`;
    }
    // eslint-disable-next-line no-console
    console.log(`[mawqie] listening on ${displayUrl} (${config.nodeEnv})`);
    if (!config.isProduction) {
      // eslint-disable-next-line no-console
      console.log(`[mawqie] mock payments: ${config.allowMockPayments ? 'enabled' : 'disabled'}`);
    }
  });

  const shutdown = () => {
    try {
      store.flush();
    } catch {
      // ignore
    }
    server.close(() => process.exit(0));
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
