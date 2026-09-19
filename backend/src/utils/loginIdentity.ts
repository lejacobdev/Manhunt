/**
 * Turns whatever someone typed into the login form into the (username, tag) pair it was
 * meant to be.
 *
 * Why this exists: App Review rejected the app twice (submissions fdcbff62, builds 34 and 35)
 * with "unable to sign in with the demo account credentials", while the credentials
 * themselves were verifiably correct. The login handler was fully literal — exact case, exact
 * tag, no trimming — so any slip in how a reviewer entered "applereview#0000" (App Store
 * Connect has one "User Name" box, so the tag has to be embedded in it) came back as a bare
 * 401. Being forgiving about *formatting* costs nothing security-wise: the tag is public
 * (it's shown next to every player's name) and the password is still the real credential.
 *
 * Done server-side rather than in the app so it also covers builds already in review, which
 * can't be changed.
 */

/** Zero-width characters String.trim() doesn't consider whitespace, but copy-paste picks up. */
const INVISIBLE = /[\u200B-\u200D\u2060\uFEFF]/g;

/** Strips invisible characters, then trims ordinary and Unicode whitespace (incl. NBSP). */
export function cleanText(input: string): string {
  return input.replace(INVISIBLE, '').trim();
}

export interface LoginIdentity {
  username: string;
  /** Null when no tag could be found anywhere — the caller decides what that means. */
  userTag: string | null;
}

export function parseLoginIdentity(rawUsername: string, rawTag: string): LoginIdentity {
  let username = cleanText(rawUsername);
  // "#0000" pasted into the tag box.
  let tag = cleanText(rawTag).replace(/^#+/, '').trim();

  const hash = username.lastIndexOf('#');
  if (hash !== -1) {
    // "applereview#0000" in the username box — the shape App Store Connect hands out. An
    // explicit tag in the tag box still wins if both are filled in.
    const fromHash = cleanText(username.slice(hash + 1));
    username = cleanText(username.slice(0, hash));
    if (!tag) tag = fromHash;
  } else if (!tag) {
    // "applereview 0000" — the same thing with a space where the # should be.
    const spaced = username.match(/^(\S+)\s+(\d{4})$/);
    if (spaced) {
      username = spaced[1];
      tag = spaced[2];
    }
  }

  return { username, userTag: tag || null };
}

/** Renders a string with every non-printable/non-ASCII character escaped, for log lines. */
export function printable(input: string, max = 48): string {
  return JSON.stringify(input.slice(0, max)).replace(
    /[^\x20-\x7e]/g,
    (ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'),
  );
}
