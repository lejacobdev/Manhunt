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
export const EMP_JAMMER_RADIUS_METERS = 200;
export const THERMAL_VISION_RADIUS_METERS = 300;
export const THERMAL_VISION_INTERVAL_MS = 1000;
export const GHOST_DECOY_SPEED_MPS = 1.4; // brisk walking pace for the simulated foot path

/** Location updates worse than this horizontal accuracy are rejected server-side (GPS spoofing/signal guard). */
export const MAX_ACCURACY_METERS = 30;

/** Extraction win condition: a runner within this radius of an extraction point is safe. */
export const EXTRACTION_RADIUS_METERS = 20;

/** How far outside the current shrinking zone a runner can stray before being auto-caught by it. */
export const ZONE_GRACE_METERS = 10;
export const ZONE_GRACE_MS = 20_000;
