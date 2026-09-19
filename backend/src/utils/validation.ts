import { z, ZodError, ZodIssue } from 'zod';
import { cleanText } from './loginIdentity';

/**
 * Turns validation failures into sentences a player can act on.
 *
 * Every client (the iOS app included) prints the `error` string from a response exactly as it
 * arrives, so whatever this returns IS the UI. Zod's own wording — "username: Invalid",
 * "String must contain at least 8 character(s)", "userTag: Required" — is written for
 * developers and tells someone typing a username with a space in it nothing about what they
 * did wrong. It's fixed here, on the server, rather than in the app, so it also applies to
 * builds that are already out or in review.
 *
 * Two layers:
 *   - schemas whose failure a player will actually hit (username, password) carry hand-written
 *     messages, including *which* characters were rejected;
 *   - everything else falls through `describeIssue`, which rewrites zod's stock messages using
 *     a friendly field label.
 */

const FIELD_LABELS: Record<string, string> = {
  username: 'Username',
  userTag: 'Tag',
  password: 'Password',
  sessionCode: 'Game code',
  toUserId: 'Player',
  receiverId: 'Player',
  durationMinutes: 'Match length (minutes)',
  powerUpCount: 'Number of power-ups',
  boundsPolygon: 'Play area',
  jailPolygon: 'Jail area',
  jailEnabled: 'Jail mode',
  jailArrivalSeconds: 'Time to reach jail (seconds)',
  bailOutSeconds: 'Bail-out time (seconds)',
  antiCheatEnabled: 'Anti-cheat',
  mode: 'Game mode',
  role: 'Role',
  squad: 'Squad name',
  lat: 'Latitude',
  lng: 'Longitude',
  category: 'Category',
  detail: 'Details',
  message: 'Message',
  title: 'Title',
  body: 'Message text',
  reason: 'Reason',
  status: 'Status',
};

/** What one entry of a list is called, for "Latitude (point 3) is required." */
const ITEM_NOUN: Record<string, string> = { boundsPolygon: 'point', jailPolygon: 'point' };

const TYPE_WORDS: Record<string, string> = {
  string: 'text',
  number: 'a number',
  integer: 'a whole number',
  boolean: 'true or false',
  array: 'a list',
  object: 'an object',
};

/** "durationMinutes" -> "Duration minutes", for any field without a hand-written label. */
function humanise(key: string): string {
  const words = key.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function fieldLabel(path: (string | number)[]): string {
  const keys = path.filter((p): p is string => typeof p === 'string');
  const last = keys[keys.length - 1];
  const label = last ? FIELD_LABELS[last] ?? humanise(last) : 'This';

  const indexAt = path.findIndex((p) => typeof p === 'number');
  if (indexAt === -1) return label;
  const owner = path[indexAt - 1];
  const noun = (typeof owner === 'string' && ITEM_NOUN[owner]) || 'item';
  return `${label} (${noun} ${(path[indexAt] as number) + 1})`;
}

/** True when zod wrote the message itself — as opposed to a schema author's own sentence. */
function hasDefaultMessage(issue: ZodIssue): boolean {
  return z.defaultErrorMap(issue, { defaultError: issue.message, data: undefined }).message === issue.message;
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** "3 points" / "1 entry" — names a list's contents after the field that owns it. */
function countEntries(n: number, path: (string | number)[]): string {
  const owner = [...path].reverse().find((p): p is string => typeof p === 'string');
  const noun = (owner && ITEM_NOUN[owner]) || 'entry';
  return plural(n, noun, noun === 'entry' ? 'entries' : `${noun}s`);
}

function describeIssue(issue: ZodIssue): string {
  // A hand-written message is already a sentence; leave it exactly as written.
  if (issue.code === z.ZodIssueCode.custom || !hasDefaultMessage(issue)) return issue.message;

  const label = fieldLabel(issue.path);

  switch (issue.code) {
    case z.ZodIssueCode.invalid_type:
      if (issue.received === 'undefined' || issue.received === 'null') return `${label} is required.`;
      return `${label} must be ${TYPE_WORDS[issue.expected] ?? `a ${issue.expected}`}.`;

    case z.ZodIssueCode.too_small: {
      const min = Number(issue.minimum);
      if (issue.type === 'string') {
        return min <= 1 ? `${label} can't be empty.` : `${label} must be at least ${plural(min, 'character')} long.`;
      }
      if (issue.type === 'array') return `${label} needs at least ${countEntries(min, issue.path)}.`;
      return `${label} must be at least ${min}.`;
    }

    case z.ZodIssueCode.too_big: {
      const max = Number(issue.maximum);
      if (issue.type === 'string') return `${label} can be at most ${plural(max, 'character')} long.`;
      if (issue.type === 'array') return `${label} can have at most ${countEntries(max, issue.path)}.`;
      return `${label} must be at most ${max}.`;
    }

    case z.ZodIssueCode.invalid_string:
      if (issue.validation === 'uuid') return `${label} isn't a valid ID.`;
      if (issue.validation === 'email') return `${label} isn't a valid email address.`;
      if (issue.validation === 'url') return `${label} isn't a valid link.`;
      if (issue.validation === 'regex') return `${label} contains characters that aren't allowed.`;
      return `${label} isn't valid.`;

    case z.ZodIssueCode.invalid_enum_value:
      return `${label} must be one of: ${issue.options.join(', ')}.`;

    default:
      return `${label}: ${issue.message}`;
  }
}

/**
 * Flattens a ZodError into one human-readable string. Every client decodes error responses
 * as `{ error: string }`, so returning `error.flatten()` directly — an object — silently
 * fails to decode client-side and surfaces as a generic "request failed with status 400"
 * instead of the actual reason.
 *
 * Only the first problem per field is reported: an empty username otherwise fails "too
 * short" *and* "invalid characters" at once, which reads as two mistakes when it's one.
 */
export function zodErrorMessage(error: ZodError): string {
  const seen = new Set<string>();
  const messages: string[] = [];
  for (const issue of error.issues) {
    const key = issue.path.join('.');
    if (seen.has(key)) continue;
    seen.add(key);
    messages.push(describeIssue(issue));
  }
  return messages.join(' ');
}

// ---------------------------------------------------------------------------------------
// Username and password rules, shared by registration and the admin rename endpoint.
// ---------------------------------------------------------------------------------------

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 20;
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128;

/** A rejected character, in words a person would use ("spaces", not U+0020). */
function describeChar(ch: string): string {
  if (/[\u200B-\u200D\u2060\uFEFF]|\p{C}/u.test(ch)) return 'hidden characters';
  if (/\s/.test(ch)) return 'spaces';
  return ch;
}

/** What's wrong with a username, in one sentence — or null if nothing is. */
export function usernameProblem(value: string): string | null {
  const rejected = [...new Set(Array.from(value).filter((ch) => !/[A-Za-z0-9_]/.test(ch)))];
  if (rejected.length > 0) {
    const shown = [...new Set(rejected.map(describeChar))];
    const list = shown.slice(0, 6).join(', ') + (shown.length > 6 ? ', …' : '');
    let message = `Usernames can only contain letters (A–Z), numbers and underscores (_). Not allowed: ${list}.`;
    if (rejected.includes('#')) {
      // Someone typing "name#1234" into Register is nearly always an existing account holder.
      message += ' Already have an account? Switch to Login — your tag is the 4 digits after the #.';
    } else if (rejected.some((ch) => /\p{L}/u.test(ch))) {
      message += " Accented letters like ü or é aren't supported — try u or e instead.";
    }
    return message;
  }
  if (value.length === 0) return 'Please enter a username.';
  if (value.length < USERNAME_MIN) {
    return `Your username needs at least ${USERNAME_MIN} characters (yours has ${value.length}).`;
  }
  if (value.length > USERNAME_MAX) {
    return `Your username can have at most ${USERNAME_MAX} characters (yours has ${value.length}).`;
  }
  return null;
}

/**
 * Surrounding whitespace is trimmed rather than rejected: a trailing space picked up from
 * copy-paste isn't a username the person meant to choose, and login already ignores it.
 */
export function usernameField() {
  return z
    .string({ required_error: 'Please enter a username.', invalid_type_error: 'Your username must be text.' })
    .transform((value) => cleanText(value))
    .superRefine((value, ctx) => {
      const problem = usernameProblem(value);
      if (problem) ctx.addIssue({ code: z.ZodIssueCode.custom, message: problem });
    });
}

/** Deliberately not trimmed — a password with a space in it is a legitimate password. */
export function passwordField() {
  return z
    .string({ required_error: 'Please enter a password.', invalid_type_error: 'Your password must be text.' })
    .superRefine((value, ctx) => {
      let message: string | null = null;
      if (value.length === 0) message = 'Please enter a password.';
      else if (value.length < PASSWORD_MIN) {
        message = `Your password needs at least ${PASSWORD_MIN} characters (yours has ${value.length}).`;
      } else if (value.length > PASSWORD_MAX) {
        message = `Your password can have at most ${PASSWORD_MAX} characters.`;
      }
      if (message) ctx.addIssue({ code: z.ZodIssueCode.custom, message });
    });
}
