import { prisma } from '../lib/prisma';

/**
 * Username screening.
 *
 * The registration regex already restricts usernames to [A-Za-z0-9_], which removes a whole
 * class of evasion before this runs — no Cyrillic "а", no fullwidth "ａ", no zero-width
 * joiners. What's left is the stuff you can spell in plain ASCII: leetspeak (n1gg3r),
 * separators (f_u_c_k), padding (fuuuuck), and case. Those are what the normaliser below
 * targets. The homoglyph map is kept anyway, cheaply, because this same function guards the
 * admin rename endpoint and would otherwise be one loosened regex away from being bypassable.
 *
 * The hard part of a filter like this isn't catching slurs, it's *not* catching Cassandra,
 * Scunthorpe or cocktail. Every blocked hit is therefore re-checked against a list of
 * innocent words that legitimately contain the same letters, and suppressed if the match
 * only exists inside one of them.
 */

/** Characters people substitute for letters, folded back before matching. */
const CHAR_MAP: Record<string, string> = {
  '0': 'o', '1': 'i', '2': 'z', '3': 'e', '4': 'a', '5': 's', '6': 'g', '7': 't', '8': 'b', '9': 'g',
  '@': 'a', '$': 's', '!': 'i', '|': 'l', '+': 't', '(': 'c', ')': 'c', '{': 'c', '[': 'c',
  '<': 'c', '*': 'a', '^': 'a', '&': 'a', '#': 'h', '%': 'o', '?': 'p',
  // Latin-1 / common accented forms, in case this is ever called on looser input.
  á: 'a', à: 'a', â: 'a', ä: 'a', ã: 'a', å: 'a', æ: 'a',
  é: 'e', è: 'e', ê: 'e', ë: 'e', í: 'i', ì: 'i', î: 'i', ï: 'i',
  ó: 'o', ò: 'o', ô: 'o', ö: 'o', õ: 'o', ø: 'o', ú: 'u', ù: 'u', û: 'u', ü: 'u',
  ý: 'y', ÿ: 'y', ñ: 'n', ç: 'c', ß: 's', þ: 'b', ð: 'd',
  // Cyrillic and Greek lookalikes.
  а: 'a', е: 'e', о: 'o', р: 'p', с: 'c', х: 'x', у: 'y', к: 'k', м: 'm', т: 't', в: 'b', н: 'h',
  α: 'a', ε: 'e', ο: 'o', ρ: 'p', ι: 'i', κ: 'k', ν: 'v', τ: 't', υ: 'u', γ: 'y',
};

/**
 * Terms that block a username outright. Grouped only for the admin UI's benefit — every
 * category is enforced identically. Extend at runtime from the admin panel rather than
 * here; this is the floor, not the whole list.
 */
const DEFAULT_BLOCKED: { term: string; category: string }[] = [
  // Slurs. The entire reason a filter like this exists.
  ...['nigger', 'nigga', 'niger', 'nigr', 'niga', 'negro', 'chink', 'gook', 'spic', 'wetback', 'kike', 'yid',
    'towelhead', 'raghead', 'paki', 'coon', 'darkie', 'jigaboo', 'tarbaby', 'zipperhead',
    'faggot', 'fagot', 'fag', 'dyke', 'tranny', 'shemale', 'ladyboy',
    'retard', 'retarded', 'spastic', 'mongoloid', 'cripple',
    'hitler', 'nazi', 'heilhitler', 'sieghell', 'kkk', 'whitepower', 'holocaust', 'genocide',
  ].map((term) => ({ term, category: 'SLUR' })),

  // Sexual content.
  ...['penis', 'vagina', 'pussy', 'cock', 'dick', 'cunt', 'twat', 'clit', 'boobs', 'titties',
    'tits', 'blowjob', 'handjob', 'rimjob', 'cumshot', 'creampie', 'bukkake', 'anal', 'anus',
    'butthole', 'asshole', 'arsehole', 'dildo', 'fleshlight', 'masturbate', 'wanker', 'wanking',
    'jizz', 'semen', 'porn', 'porno', 'pornhub', 'hentai', 'incest', 'bestiality', 'pedo',
    'pedophile', 'paedophile', 'childporn', 'cp', 'loli', 'shota', 'rape', 'rapist', 'molest',
    'whore', 'slut', 'hooker', 'prostitute', 'milf', 'gangbang', 'deepthroat',
  ].map((term) => ({ term, category: 'SEXUAL' })),

  // General profanity.
  ...['fuck', 'fock', 'fuk', 'fuq', 'phuk', 'fcuk', 'fucker', 'fucking', 'motherfucker',
    'shit', 'shyt', 'shitty', 'bullshit', 'bitch', 'biatch', 'beatch',
    'bastard', 'ass', 'arse', 'damn', 'crap', 'piss', 'prick', 'douche', 'skank', 'scumbag',
    'azzhole', 'azz',
    'wtf', 'stfu', 'fml',
  ].map((term) => ({ term, category: 'PROFANITY' })),

  // Names that let someone pass themselves off as staff. Not rude, but a support-impersonation
  // account is a more effective scam than any slur.
  ...['admin', 'administrator', 'moderator', 'mod', 'staff', 'official', 'support',
    'huntinggame', 'huntinggameteam', 'system', 'server', 'root', 'owner', 'developer',
    'apple', 'appstore', 'appleteam', 'applesupport',
  ].map((term) => ({ term, category: 'IMPERSONATION' })),

  // Self-harm and violence, which we'd rather not have on a leaderboard.
  ...['killyourself', 'kys', 'suicide', 'selfharm', 'cutter', 'schoolshooter', 'terrorist',
    'isis', 'alqaeda', 'bomber',
  ].map((term) => ({ term, category: 'HARM' })),
];

/**
 * Innocent words that contain a blocked term as a substring. A hit is discarded if it only
 * exists inside one of these — this is the difference between a filter people tolerate and
 * one that rejects everybody called Cassandra.
 */
const DEFAULT_ALLOWED = [
  // ass
  'assassin', 'assassinate', 'assist', 'assistant', 'assign', 'assignment', 'associate',
  'association', 'assume', 'assure', 'assert', 'assemble', 'assembly', 'asset', 'assess',
  'bass', 'bassist', 'brass', 'class', 'classic', 'glass', 'grass', 'pass', 'passage',
  'passion', 'password', 'compass', 'embassy', 'ambassador', 'harass', 'potassium',
  'cassette', 'casserole', 'cassandra', 'lass', 'mass', 'massive', 'molasses', 'carcass',
  'canvass', 'surpass', 'bypass', 'overpass', 'underpass', 'assam', 'assyria',
  // cock
  'cocktail', 'peacock', 'cockpit', 'cockney', 'hancock', 'woodcock', 'shuttlecock', 'cockatoo',
  // cum
  'cucumber', 'document', 'documentary', 'circumstance', 'accumulate', 'incumbent',
  'cumulative', 'cumin', 'scum',
  // tit
  'title', 'titles', 'titan', 'titanic', 'competitive', 'constitution', 'institute',
  'institution', 'petition', 'appetite', 'attitude', 'multitude', 'latitude', 'altitude',
  'gratitude', 'entitle', 'subtitle', 'practitioner', 'partition', 'repetition',
  // anal
  'analysis', 'analyst', 'analyse', 'analyze', 'analog', 'analogue', 'analogy', 'canal',
  'banal', 'analytics',
  // sex
  'essex', 'sussex', 'middlesex', 'wessex', 'sexton', 'sextant',
  // hell
  'hello', 'shell', 'shelly', 'michelle', 'othello', 'hellenic', 'seashell', 'bombshell',
  // rape
  'grape', 'grapes', 'drape', 'scrape', 'trapeze', 'therapy', 'therapist', 'grapefruit',
  // shit
  'shiitake', 'shitake',
  // dick
  'dickens', 'dickinson', 'dicky',
  // mod / admin-ish
  'model', 'modern', 'module', 'moderate', 'modest', 'modify', 'commodore', 'nomad',
  // cunt — the classic false-positive family that gives the problem its name
  'scunthorpe', 'penistone', 'lightwater', 'clbuttic',
  // misc
  'nightmare', 'benign', 'signal', 'design', 'cognition', 'nigeria', 'nigerian',
  'assumption', 'crapshoot', 'scrapper',
];

/** Folds a username down to the letters it would actually be read as. */
function normalise(input: string): string {
  return input
    .toLowerCase()
    .normalize('NFKD')
    // Strip combining marks left behind by NFKD (é -> e + ́ -> e).
    .replace(/[̀-ͯ]/g, '')
    .split('')
    .map((ch) => CHAR_MAP[ch] ?? ch)
    .join('')
    .replace(/[^a-z]/g, '');
}

/** "fuuuuck" -> "fuck". Applied to both sides so the comparison stays symmetrical. */
function collapse(input: string): string {
  return input.replace(/(.)\1+/g, '$1');
}

/**
 * A second reading of the same string, for substitutions that aren't one-to-one character
 * swaps: "ph" read as "f" (phuck), and "v" standing in for "u" (fvck). Kept as a separate
 * candidate rather than folded into the main normaliser, because these rewrites are lossy
 * on innocent words too — "Stephanie" becomes "stefanie" and "Vince" becomes "uince", which
 * is harmless to *compare* against but would be wrong to treat as the canonical form.
 */
function phoneticVariant(input: string): string {
  return input.replace(/ph/g, 'f').replace(/v/g, 'u');
}

/** Every reading of a username worth checking a term against. */
function candidates(username: string): { direct: string[]; collapsed: string[] } {
  const base = normalise(username);
  const variant = phoneticVariant(base);
  const direct = [...new Set([base, variant])];
  return { direct, collapsed: [...new Set(direct.map(collapse))] };
}

export interface UsernameVerdict {
  allowed: boolean;
  term?: string;
  category?: string;
}

let cache: { at: number; blocked: { term: string; category: string }[]; allowed: string[] } | null = null;
const CACHE_MS = 60_000;

/** Default list plus anything added from the admin panel, cached briefly. */
async function lists() {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache;

  let custom: { term: string; category: string; isAllowlist: boolean }[] = [];
  try {
    custom = await prisma.blockedTerm.findMany({
      select: { term: true, category: true, isAllowlist: true },
    });
  } catch {
    // Table missing (a deploy mid-migration) shouldn't take registration down with it —
    // the built-in list still applies.
  }

  cache = {
    at: Date.now(),
    blocked: [
      ...DEFAULT_BLOCKED,
      ...custom.filter((c) => !c.isAllowlist).map((c) => ({ term: normalise(c.term), category: c.category })),
    ].filter((b) => b.term.length > 1),
    allowed: [...DEFAULT_ALLOWED, ...custom.filter((c) => c.isAllowlist).map((c) => c.term)].map(normalise),
  };
  return cache;
}

/** Drops the cache so an admin's edit takes effect immediately rather than within a minute. */
export function invalidateUsernameFilterCache() {
  cache = null;
}

/**
 * Checks a username against the blocklist.
 *
 * Two passes: the literal normalised form, then a repeat-collapsed form that catches
 * padding. The collapsed pass only considers terms still at least four characters after
 * collapsing — "ass" collapses to "as", and matching that would reject Jonas, Lucas and
 * every other name with those two letters in sequence.
 */
export async function screenUsername(username: string): Promise<UsernameVerdict> {
  const { blocked, allowed } = await lists();
  const { direct, collapsed } = candidates(username);

  const strip = (text: string) => {
    let residue = text;
    for (const safe of allowed) {
      if (safe.length >= 3 && residue.includes(safe)) {
        residue = residue.split(safe).join(' ');
      }
    }
    return residue;
  };

  for (const { term, category } of blocked) {
    const collapsedTerm = collapse(term);
    const canCollapse = collapsedTerm.length >= 4;

    const hit =
      direct.some((c) => c.includes(term)) ||
      (canCollapse && collapsed.some((c) => c.includes(collapsedTerm)));
    if (!hit) continue;

    // Suppress the hit if it only survives inside an innocent word — blank out every
    // allowlisted word and see whether the term is still there. This is what keeps
    // Scunthorpe, Cassandra and cocktail out of the rejection pile.
    const survives =
      direct.some((c) => strip(c).includes(term)) ||
      (canCollapse && direct.some((c) => collapse(strip(c)).includes(collapsedTerm)));
    if (!survives) continue;

    return { allowed: false, term, category };
  }

  return { allowed: true };
}

/** Human-readable rejection, deliberately vague about which term matched. */
export function rejectionMessage(verdict: UsernameVerdict): string {
  if (verdict.category === 'IMPERSONATION') {
    return 'That username is reserved — please choose another.';
  }
  return "That username isn't allowed. Please choose another.";
}

/** Runs the filter over every existing account, for the admin panel's audit view. */
export async function scanExistingUsernames() {
  const users = await prisma.user.findMany({
    select: { id: true, username: true, userTag: true, createdAt: true, isBanned: true },
  });
  const flagged: {
    id: string;
    username: string;
    userTag: string;
    createdAt: Date;
    isBanned: boolean;
    term: string;
    category: string;
  }[] = [];
  for (const user of users) {
    const verdict = await screenUsername(user.username);
    if (!verdict.allowed) {
      flagged.push({ ...user, term: verdict.term!, category: verdict.category! });
    }
  }
  return flagged;
}
