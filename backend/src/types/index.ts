export type PlayerRole = 'HUNTER' | 'RUNNER' | 'SPECTATOR';

export type GameMode = 'STANDARD' | 'INFECTION' | 'SQUAD';

export type PowerUpType =
  | 'INVISIBILITY_10MIN'
  | 'GHOST_DECOY'
  | 'EMP_JAMMER'
  | 'THERMAL_VISION'
  | 'ADRENALINE'
  | 'SAFE_ZONE_FLARE';

export interface Point2D {
  lat: number;
  lng: number;
}

export interface ActiveBuff {
  expiresAt: number;
  meta?: Record<string, unknown>;
}

export interface PlayerState {
  id: string;
  userId: string;
  username: string;
  role: PlayerRole;
  squad?: string;
  lat: number;
  lng: number;
  speed: number;
  accuracy: number;
  battery: number;
  isMovingOnFoot: boolean;
  arrestCode: string;
  isCaught: boolean;
  isExtracted: boolean;
  isJailed: boolean;
  isOut: boolean;
  hearts: number;
  inventory: PowerUpType[];
  activeBuffs: Partial<Record<PowerUpType, ActiveBuff>>;
  lastUpdate: number;
  /** Set once by the server on join_room; the last full radar/roster push each socket received. */
  lastRadarPushAt?: number;
}

export interface AuthTokenPayload {
  userId: string;
  username: string;
}

/** Per section 1.3 of the design spec. */
export const POWER_UP_DURATIONS_MS: Record<PowerUpType, number> = {
  INVISIBILITY_10MIN: 10 * 60 * 1000,
  GHOST_DECOY: 3 * 60 * 1000,
  EMP_JAMMER: 60 * 1000,
  THERMAL_VISION: 45 * 1000,
  ADRENALINE: 90 * 1000,
  SAFE_ZONE_FLARE: 90 * 1000,
};

export const MAX_HUMAN_SPEED_MPS = 9.72; // ~35 km/h sprint ceiling for anti-cheat
export const ADRENALINE_SPEED_MPS = 12.5; // raised ceiling while ADRENALINE is active
export const SAFE_ZONE_RADIUS_METERS = 30;
export const CATCH_VERIFICATION_RADIUS_METERS = 15;
/** Power-up pickup is lower-stakes than a catch, so it gets a more forgiving base radius
 *  — the actual check also widens this by the collector's own reported GPS accuracy. */
export const POWER_UP_COLLECTION_RADIUS_METERS = 25;
export const EMP_JAMMER_RADIUS_METERS = 200;
export const THERMAL_VISION_RADIUS_METERS = 300;
export const THERMAL_VISION_INTERVAL_MS = 1000;
export const GHOST_DECOY_SPEED_MPS = 1.4; // brisk walking pace for the simulated foot path

/** Location updates worse than this horizontal accuracy are rejected server-side (GPS spoofing/signal guard). */
export const MAX_ACCURACY_METERS = 30;

/** Extraction win condition: a runner within this radius of an extraction point is safe. */
export const EXTRACTION_RADIUS_METERS = 20;

/** Starting hearts per role — hunters get more, making it comparatively riskier for a
 *  runner to gamble away one of their own scarcer hearts. Set explicitly in joinSession;
 *  the Prisma column default only backfills pre-existing rows. */
export const HUNTER_STARTING_HEARTS = 5;
export const RUNNER_STARTING_HEARTS = 3;

/** Boundary ("storm") containment — leaving the outer play-area polygon (either role)
 *  warns first, then drains a heart every tick while still outside. Replaces the old
 *  shrinking-zone instant-catch entirely. */
export const BOUNDARY_BUFFER_METERS = 10;
export const BOUNDARY_WARNING_GRACE_MS = 8_000;
export const BOUNDARY_DAMAGE_TICK_MS = 8_000;

/** Jail containment — a jailed runner who strays past jail+buffer gets an urgent
 *  countdown; failing to return within it is full elimination, not just re-jailing. */
export const JAIL_BUFFER_METERS = 10;
export const JAIL_VIOLATION_COUNTDOWN_MS = 10_000;

/** A catch request a runner never answers (backgrounded app, etc.) auto-expires so it
 *  can't permanently block the hunter from requesting again. */
export const CATCH_REQUEST_TIMEOUT_MS = 20_000;
