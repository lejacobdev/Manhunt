import nodemailer, { Transporter } from 'nodemailer';
import { prisma } from '../lib/prisma';

/**
 * Emails the moderator every time a player files a report.
 *
 * Why this exists: reports used to land in the database and the admin panel and nowhere else,
 * so a report about a threat or harassment sat unseen until someone happened to open the panel.
 * App Store guideline 1.2 expects reports on user-generated content to be acted on promptly, so
 * the panel now gets a push in the form of an email.
 *
 * Deliberately best-effort: a report is already saved before this runs, and a mail-server
 * hiccup must never turn "your report was received" into an error for the person who filed it.
 * Everything here is fire-and-forget and swallows its own failures into the log.
 *
 * Sends as an authenticated user straight to our own mail server, so an alert to a
 * lejacob.dev address is delivered locally — it never touches the outbound relay.
 */

const CATEGORY_LABELS: Record<string, string> = {
  CHEATING: 'Cheating',
  INAPPROPRIATE_USERNAME: 'Inappropriate username',
  HARASSMENT: 'Harassment',
  THREATS: 'Threats',
  SEXUAL_CONTENT: 'Sexual content',
  IMPERSONATION: 'Impersonation',
  UNSAFE_PLAY: 'Unsafe play',
  OTHER: 'Something else',
};

/** About someone's safety rather than fair play — flagged in the subject so it isn't skimmed past. */
const URGENT_CATEGORIES = new Set(['THREATS', 'HARASSMENT', 'SEXUAL_CONTENT', 'UNSAFE_PLAY']);

// One person filing reports in a loop shouldn't be able to bury the inbox (and with it the one
// report that matters). Past this many in an hour the rest are counted, not sent, and the next
// email says how many were held back.
const MAX_ALERTS_PER_HOUR = 20;
const WINDOW_MS = 60 * 60 * 1000;
let windowStartedAt = 0;
let sentInWindow = 0;
let suppressedInWindow = 0;

let transport: Transporter | null = null;
let warnedDisabled = false;

function getTransport(): Transporter | null {
  const host = process.env.SMTP_HOST;
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;
  if (!host || !user || !pass || !process.env.REPORT_ALERT_TO) {
    if (!warnedDisabled) {
      console.warn('[MAIL] report alerts are off — SMTP_HOST/SMTP_USER/SMTP_PASS/REPORT_ALERT_TO not all set');
      warnedDisabled = true;
    }
    return null;
  }
  if (!transport) {
    const port = Number(process.env.SMTP_PORT ?? 587);
    transport = nodemailer.createTransport({
      host,
      port,
      secure: port === 465,
      requireTLS: port !== 465, // never send credentials over a connection that didn't upgrade
      auth: { user, pass },
      // A dead mail server has to fail fast rather than pile up sockets behind report requests.
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 20_000,
    });
  }
  return transport;
}

interface ReportRow {
  id: string;
  reporterId: string;
  reportedUserId: string;
  category: string;
  reason: string | null;
  createdAt: Date;
}

async function sendAlert(report: ReportRow): Promise<void> {
  const mailer = getTransport();
  if (!mailer) return;

  const now = Date.now();
  if (now - windowStartedAt > WINDOW_MS) {
    windowStartedAt = now;
    sentInWindow = 0;
  }
  if (sentInWindow >= MAX_ALERTS_PER_HOUR) {
    suppressedInWindow++;
    console.warn(`[MAIL] alert for report ${report.id} held back (over ${MAX_ALERTS_PER_HOUR}/hour) — still in the admin panel`);
    return;
  }
  sentInWindow++;
  const heldBack = suppressedInWindow;
  suppressedInWindow = 0;

  const [users, totalAgainst, openAgainst] = await Promise.all([
    prisma.user.findMany({
      where: { id: { in: [report.reporterId, report.reportedUserId] } },
      select: { id: true, username: true, userTag: true, isBanned: true },
    }),
    prisma.report.count({ where: { reportedUserId: report.reportedUserId } }),
    prisma.report.count({ where: { reportedUserId: report.reportedUserId, status: 'OPEN' } }),
  ]);
  const describe = (id: string) => {
    const u = users.find((x) => x.id === id);
    return u ? `${u.username}#${u.userTag}` : '(account no longer exists)';
  };
  const reported = users.find((x) => x.id === report.reportedUserId);

  const label = CATEGORY_LABELS[report.category] ?? report.category;
  const urgent = URGENT_CATEGORIES.has(report.category);
  const adminUrl = process.env.ADMIN_URL ?? 'https://lejacob.dev/admin/';

  const lines = [
    urgent
      ? 'A player filed a safety-related report. Please review it as soon as you can.'
      : 'A player filed a new report.',
    'Reports on user content should be acted on within 24 hours.',
    '',
    `Category : ${label}`,
    `Reported : ${describe(report.reportedUserId)}${reported?.isBanned ? '  (already banned)' : ''}`,
    `Filed by : ${describe(report.reporterId)}`,
    `When     : ${report.createdAt.toISOString().replace('T', ' ').slice(0, 16)} UTC`,
    `Report ID: ${report.id}`,
    '',
    `History  : ${totalAgainst} report${totalAgainst === 1 ? '' : 's'} against this player in total, ${openAgainst} still open.`,
    '',
    'What the reporter wrote:',
    report.reason ? `  "${report.reason}"` : '  (no details given)',
    '',
    `Review and respond: ${adminUrl}   ->  Reports`,
  ];
  if (heldBack > 0) {
    lines.push('', `Note: ${heldBack} other alert${heldBack === 1 ? ' was' : 's were'} held back in the last hour to avoid flooding you. They are all in the admin panel.`);
  }

  await mailer.sendMail({
    from: `Hunting Game Moderation <${process.env.SMTP_USER}>`,
    to: process.env.REPORT_ALERT_TO,
    subject: `[Hunting Game] ${urgent ? 'URGENT — ' : ''}Report: ${label} — ${describe(report.reportedUserId)}`,
    text: lines.join('\n'),
    priority: urgent ? 'high' : 'normal',
  });
  console.log(`[MAIL] report alert sent for ${report.id} (${report.category})`);
}

/** Fire-and-forget: returns immediately and can never throw into the request that called it. */
export function notifyNewReport(report: ReportRow): void {
  sendAlert(report).catch((err) => {
    console.error(`[MAIL] report alert for ${report.id} failed:`, err instanceof Error ? err.message : err);
  });
}
