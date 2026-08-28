export type PlayerRole = 'HUNTER' | 'RUNNER' | 'SUPERVISOR' | 'SPECTATOR';

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
  arrestCode: string;
  isCaught: boolean;
  inventory: PowerUpType[];
  activeBuffs: Partial<Record<PowerUpType, ActiveBuff>>;
  lastUpdate: number;
}

export interface AuthTokenPayload {
  userId: string;
  username: string;
}

export const POWER_UP_DURATIONS_MS: Record<PowerUpType, number> = {
  INVISIBILITY_10MIN: 10 * 60 * 1000,
  GHOST_DECOY: 5 * 60 * 1000,
  EMP_JAMMER: 3 * 60 * 1000,
  THERMAL_VISION: 4 * 60 * 1000,
  ADRENALINE: 90 * 1000,
  SAFE_ZONE_FLARE: 2 * 60 * 1000,
};

export const MAX_HUMAN_SPEED_MPS = 9.72; // ~35 km/h sprint ceiling for anti-cheat
export const ADRENALINE_SPEED_MPS = 12.5; // raised ceiling while ADRENALINE is active
export const SAFE_ZONE_RADIUS_METERS = 30;
export const CATCH_VERIFICATION_RADIUS_METERS = 15;
