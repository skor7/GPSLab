// @ts-check
/**
 * Configurable notification channels + email abstraction.
 *
 * Channels are selected with `NOTIFY_CHANNELS` (comma separated): `console`,
 * `file`, `email`. All channels implement the same tiny interface:
 *   send({to, subject, body, template, meta}) -> Promise<{channel, ok, error?}>
 *
 * Email is an adapter seam. `ConsoleEmailProvider` records messages (local/dev).
 * `HttpEmailProvider` POSTs to a configured `NOTIFY_EMAIL_ENDPOINT`; no SMTP
 * library is bundled (zero dependencies) and no credentials are stored here.
 * A channel failure is recorded, never thrown, so it can never block a purchase
 * or a trial claim.
 */
import fs from 'node:fs';
import path from 'node:path';
import { newId } from '../core/ids.js';

export class ConsoleChannel {
  name = 'console';
  /** @param {{sink?: (entry: any) => void}} [options] */
  constructor(options = {}) {
    this.sink = options.sink;
  }

  async send(notification) {
    if (this.sink) {
      this.sink(notification);
    } else {
      // eslint-disable-next-line no-console
      console.log(`[mawqie:notify] ${notification.subject} -> ${notification.to}`);
    }
    return { channel: this.name, ok: true };
  }
}

export class FileChannel {
  name = 'file';
  /** @param {{filePath: string}} options */
  constructor({ filePath }) {
    this.filePath = path.resolve(filePath);
  }

  async send(notification) {
    try {
      fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
      fs.appendFileSync(this.filePath, `${JSON.stringify(notification)}\n`, 'utf8');
      return { channel: this.name, ok: true };
    } catch (error) {
      return { channel: this.name, ok: false, error: /** @type {Error} */ (error).name };
    }
  }
}

/** Email providers implement `send(message)`. */
export class ConsoleEmailProvider {
  name = 'console-email';
  async send(message) {
    return { ok: true, provider: this.name, id: newId(), message };
  }
}

export class HttpEmailProvider {
  name = 'http-email';
  /** @param {{endpoint: string, from: string, token?: string}} options */
  constructor({ endpoint, from, token = '' }) {
    this.endpoint = endpoint;
    this.from = from;
    this.token = token;
  }

  async send(message) {
    try {
      const headers = { 'content-type': 'application/json' };
      if (this.token) headers.authorization = `Bearer ${this.token}`;
      const response = await fetch(this.endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify({ from: this.from, ...message }),
      });
      if (response.status >= 200 && response.status < 300) {
        return { ok: true, provider: this.name };
      }
      return { ok: false, provider: this.name, error: `HTTP ${response.status}` };
    } catch (error) {
      return { ok: false, provider: this.name, error: /** @type {Error} */ (error).name };
    }
  }
}

export class EmailChannel {
  name = 'email';
  /** @param {{provider: ConsoleEmailProvider | HttpEmailProvider, from: string}} options */
  constructor({ provider, from }) {
    this.provider = provider;
    this.from = from;
  }

  async send(notification) {
    const result = await this.provider.send({
      to: notification.to,
      subject: notification.subject,
      text: notification.body,
    });
    return { channel: this.name, ok: result.ok, error: result.error };
  }
}

/**
 * Build the configured channel list.
 * @param {{config: import('../config.js').MawqieConfig, sink?: (entry: any) => void}} deps
 */
export function createChannels({ config, sink }) {
  /** @type {Array<{name: string, send: (n: any) => Promise<{channel: string, ok: boolean, error?: string}>}>} */
  const channels = [];
  for (const name of config.notifyChannels) {
    if (name === 'console') {
      channels.push(new ConsoleChannel(sink ? { sink } : {}));
    } else if (name === 'file') {
      channels.push(new FileChannel({ filePath: config.notifyFilePath || path.join(process.cwd(), 'data', 'notifications.log') }));
    } else if (name === 'email') {
      const provider = config.notifyEmailEndpoint
        ? new HttpEmailProvider({ endpoint: config.notifyEmailEndpoint, from: config.notifyEmailFrom })
        : new ConsoleEmailProvider();
      channels.push(new EmailChannel({ provider, from: config.notifyEmailFrom }));
    }
  }
  return channels;
}

export class Notifier {
  /** @param {{store: import('../store/store.js').Store, now: () => number, channels: ReturnType<typeof createChannels>}} deps */
  constructor({ store, now, channels }) {
    this.store = store;
    this.now = now;
    this.channels = channels;
  }

  /**
   * @param {{to: string, subject: string, body: string, template?: string, meta?: Record<string, unknown>}} notification
   */
  async notify(notification) {
    const entry = {
      id: newId(),
      atMs: this.now(),
      to: notification.to,
      subject: notification.subject,
      body: notification.body,
      template: notification.template ?? 'generic',
      meta: notification.meta ?? {},
      results: /** @type {Array<{channel: string, ok: boolean, error?: string}>} */ ([]),
    };
    for (const channel of this.channels) {
      let result;
      try {
        result = await channel.send(entry);
      } catch (error) {
        result = { channel: channel.name, ok: false, error: /** @type {Error} */ (error).name };
      }
      entry.results.push(result);
    }
    this.store.notifications.push(entry);
    this.store.touch();
    return entry;
  }
}
