import http2 from 'http2';
import jwt from 'jsonwebtoken';
import { prisma } from '../lib/prisma';

/**
 * Sends APNs push notifications with no new dependency: Apple's token-based provider auth
 * is just a JWT signed with an ES256 private key (`jsonwebtoken`, already used for this
 * app's own auth tokens, signs ES256 fine), and the actual delivery is a single HTTP/2
 * POST — Node's built-in `http2` module handles that without pulling in `apn`/`node-apn`
 * for what's otherwise a two-call surface.
 *
 * Configuration is entirely optional: with no APNS_* env vars set, `send` just no-ops (one
 * warning logged, not per-call) so the rest of the app works unmodified before those are
 * provisioned. See README for what's needed and where to generate it.
 */
class PushService {
  private client: http2.ClientHttp2Session | null = null;
  private cachedToken: { jwt: string; issuedAt: number } | null = null;
  private warnedNotConfigured = false;

  private get keyId(): string | undefined {
    return process.env.APNS_KEY_ID;
  }
  private get teamId(): string | undefined {
    return process.env.APNS_TEAM_ID;
  }
  private get bundleId(): string | undefined {
    return process.env.APNS_BUNDLE_ID;
  }
  private get privateKey(): string | undefined {
    // Stored as a repo/host secret with literal "\n" sequences (env vars can't hold real
    // newlines cleanly) — restored here since a PEM key needs its actual line breaks.
    return process.env.APNS_PRIVATE_KEY?.replace(/\\n/g, '\n');
  }
  private get isProduction(): boolean {
    return process.env.APNS_ENVIRONMENT !== 'sandbox';
  }

  private get isConfigured(): boolean {
    return Boolean(this.keyId && this.teamId && this.bundleId && this.privateKey);
  }

  /** Registers (or re-confirms) a device token for push delivery. Upserts by token, since
   *  the same physical device reinstalling the app is a fresh token, not a fresh device. */
  async registerToken(userId: string, token: string): Promise<void> {
    await prisma.deviceToken.upsert({
      where: { token },
      create: { userId, token },
      update: { userId, updatedAt: new Date() },
    });
  }

  async unregisterToken(token: string): Promise<void> {
    await prisma.deviceToken.deleteMany({ where: { token } });
  }

  /** Pushes the same alert to every device this user has registered. Best-effort: a device
   *  APNs reports as gone (410, or 400 BadDeviceToken) has its row cleaned up; any other
   *  failure is logged and otherwise swallowed — a push is a courtesy, never something a
   *  caller's own request should fail over. */
  async notify(userId: string, payload: { title: string; body: string; data?: Record<string, unknown> }): Promise<void> {
    if (!this.isConfigured) {
      if (!this.warnedNotConfigured) {
        console.warn('[PushService] APNS_* env vars not set — push notifications are disabled.');
        this.warnedNotConfigured = true;
      }
      return;
    }

    const tokens = await prisma.deviceToken.findMany({ where: { userId }, select: { token: true } });
    if (tokens.length === 0) return;

    await Promise.all(tokens.map((t) => this.sendOne(t.token, payload)));
  }

  private async sendOne(deviceToken: string, payload: { title: string; body: string; data?: Record<string, unknown> }): Promise<void> {
    const session = this.connect();
    const body = JSON.stringify({
      aps: { alert: { title: payload.title, body: payload.body }, sound: 'default' },
      ...payload.data,
    });

    return new Promise((resolve) => {
      const req = session.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${this.providerToken()}`,
        'apns-topic': this.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json',
      });

      let status = 0;
      req.on('response', (headers) => {
        status = Number(headers[':status'] ?? 0);
      });
      let responseBody = '';
      req.on('data', (chunk) => {
        responseBody += chunk;
      });
      req.on('end', () => {
        if (status >= 400) {
          console.warn(`[PushService] APNs rejected a push (${status}): ${responseBody}`);
          if (status === 410 || (status === 400 && responseBody.includes('BadDeviceToken'))) {
            void this.unregisterToken(deviceToken);
          }
        }
        resolve();
      });
      req.on('error', (err) => {
        console.warn('[PushService] APNs request failed:', err.message);
        resolve();
      });

      req.end(body);
    });
  }

  /** One shared HTTP/2 connection, reused across sends — APNs expects long-lived
   *  connections rather than one per notification, and explicitly discourages the latter. */
  private connect(): http2.ClientHttp2Session {
    if (this.client && !this.client.closed && !this.client.destroyed) return this.client;
    const host = this.isProduction ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
    const session = http2.connect(host);
    session.on('error', (err) => console.warn('[PushService] APNs connection error:', err.message));
    session.on('close', () => {
      if (this.client === session) this.client = null;
    });
    this.client = session;
    return session;
  }

  /** Apple allows reusing a provider token for up to an hour; refreshing every ~50 minutes
   *  avoids both a same-second-expiry race and signing a fresh JWT on every single push. */
  private providerToken(): string {
    const now = Date.now();
    if (this.cachedToken && now - this.cachedToken.issuedAt < 50 * 60 * 1000) {
      return this.cachedToken.jwt;
    }
    const token = jwt.sign({ iss: this.teamId, iat: Math.floor(now / 1000) }, this.privateKey!, {
      algorithm: 'ES256',
      header: { alg: 'ES256', kid: this.keyId! },
    });
    this.cachedToken = { jwt: token, issuedAt: now };
    return token;
  }
}

export const pushService = new PushService();
