import * as turf from '@turf/turf';
import {
  EMP_JAMMER_RADIUS_METERS,
  POWER_UP_DURATIONS_MS,
  PlayerState,
  PowerUpType,
  SAFE_ZONE_RADIUS_METERS,
  Point2D,
  GHOST_DECOY_SPEED_MPS,
} from '../types';

export interface PowerUpUseResult {
  ok: boolean;
  error?: string;
  broadcastEvent?: { type: string; payload: Record<string, unknown> };
}

export interface DecoyRecord {
  sessionOwnerId: string;
  originLat: number;
  originLng: number;
  bearingDegrees: number;
  spawnedAt: number;
  expiresAt: number;
}

export type DecoyMap = Map<string, DecoyRecord[]>;

/**
 * Applies the gameplay effect of a power-up to the in-memory session state.
 * All six power-up types are fully implemented per the design spec:
 *
 *  - INVISIBILITY_10MIN: hides the runner from hunter radar broadcasts.
 *  - GHOST_DECOY: plants a fake runner blip that walks a simulated foot
 *    path opposite the runner's real direction of travel for 3 minutes.
 *  - EMP_JAMMER: a runner-cast AOE that blinds every hunter within 200m at
 *    the moment of casting for 60 seconds (their radar + compass go dark).
 *  - THERMAL_VISION: a hunter buff that pierces INVISIBILITY_10MIN for
 *    runners within 300m and forces 1-second radar refresh, for 45 seconds.
 *  - ADRENALINE: temporarily raises the runner's permitted sprint-speed
 *    ceiling for anti-cheat purposes.
 *  - SAFE_ZONE_FLARE: creates a temporary 30m no-catch radius for 90s.
 */
export function usePowerUp(
  session: Map<string, PlayerState>,
  playerId: string,
  type: PowerUpType,
  decoys: DecoyMap,
  sessionCode: string,
  runnerBearingDegrees?: number
): PowerUpUseResult {
  const player = session.get(playerId);
  if (!player) return { ok: false, error: 'Player not found in session.' };
  if (!player.inventory.includes(type)) {
    return { ok: false, error: `Player does not hold a ${type} power-up.` };
  }
  if (player.isCaught || player.isOut) {
    return { ok: false, error: 'Caught players cannot use power-ups.' };
  }

  // Consume from inventory
  const idx = player.inventory.indexOf(type);
  player.inventory.splice(idx, 1);

  const now = Date.now();
  const expiresAt = now + POWER_UP_DURATIONS_MS[type];

  switch (type) {
    case 'INVISIBILITY_10MIN': {
      player.activeBuffs.INVISIBILITY_10MIN = { expiresAt };
      return {
        ok: true,
        broadcastEvent: { type: 'POWERUP_USED', payload: { playerId, powerUp: type, expiresAt } },
      };
    }

    case 'ADRENALINE': {
      player.activeBuffs.ADRENALINE = { expiresAt };
      return {
        ok: true,
        broadcastEvent: { type: 'POWERUP_USED', payload: { playerId, powerUp: type, expiresAt } },
      };
    }

    case 'SAFE_ZONE_FLARE': {
      player.activeBuffs.SAFE_ZONE_FLARE = {
        expiresAt,
        meta: { lat: player.lat, lng: player.lng, radiusMeters: SAFE_ZONE_RADIUS_METERS },
      };
      return {
        ok: true,
        broadcastEvent: {
          type: 'SAFE_ZONE_CREATED',
          payload: { playerId, lat: player.lat, lng: player.lng, radiusMeters: SAFE_ZONE_RADIUS_METERS, expiresAt },
        },
      };
    }

    case 'THERMAL_VISION': {
      player.activeBuffs.THERMAL_VISION = { expiresAt };
      return {
        ok: true,
        broadcastEvent: { type: 'POWERUP_USED', payload: { playerId, powerUp: type, expiresAt } },
      };
    }

    case 'GHOST_DECOY': {
      // Walks off in the direction opposite the runner's own recent bearing
      // (falling back to a random heading if we don't have one yet), so a
      // hunter chasing the decoy is drawn away from the real runner.
      const bearing = ((runnerBearingDegrees ?? Math.random() * 360) + 180) % 360;
      const list = decoys.get(sessionCode) ?? [];
      list.push({
        sessionOwnerId: playerId,
        originLat: player.lat,
        originLng: player.lng,
        bearingDegrees: bearing,
        spawnedAt: now,
        expiresAt,
      });
      decoys.set(sessionCode, list);
      return {
        ok: true,
        broadcastEvent: {
          type: 'GHOST_DECOY_SPAWNED',
          payload: { playerId, lat: player.lat, lng: player.lng, bearingDegrees: bearing, expiresAt },
        },
      };
    }

    case 'EMP_JAMMER': {
      const casterPt = turf.point([player.lng, player.lat]);
      const jammedHunterIds: string[] = [];
      for (const other of session.values()) {
        if (other.role !== 'HUNTER' || other.id === playerId) continue;
        const dist = turf.distance(casterPt, turf.point([other.lng, other.lat]), { units: 'meters' });
        if (dist <= EMP_JAMMER_RADIUS_METERS) {
          other.activeBuffs.EMP_JAMMER = { expiresAt };
          jammedHunterIds.push(other.id);
        }
      }
      return {
        ok: true,
        broadcastEvent: {
          type: 'EMP_JAMMER_USED',
          payload: { playerId, jammedHunterIds, radiusMeters: EMP_JAMMER_RADIUS_METERS, expiresAt },
        },
      };
    }

    default:
      return { ok: false, error: `Unknown power-up type: ${type}` };
  }
}

export function grantPowerUp(player: PlayerState, type: PowerUpType): void {
  player.inventory.push(type);
}

export function isBuffActive(player: PlayerState, type: PowerUpType): boolean {
  const buff = player.activeBuffs[type];
  return !!buff && buff.expiresAt > Date.now();
}

export function pruneExpiredBuffs(player: PlayerState): void {
  const now = Date.now();
  for (const key of Object.keys(player.activeBuffs) as PowerUpType[]) {
    const buff = player.activeBuffs[key];
    if (buff && buff.expiresAt <= now) {
      delete player.activeBuffs[key];
    }
  }
}

export function pruneExpiredDecoys(decoys: DecoyMap, sessionCode: string): void {
  const now = Date.now();
  const list = decoys.get(sessionCode);
  if (!list) return;
  decoys.set(
    sessionCode,
    list.filter((d) => d.expiresAt > now)
  );
}

/** Computes a decoy's current position by walking it along its cast bearing at a brisk foot pace. */
export function currentDecoyPosition(decoy: DecoyRecord, now: number = Date.now()): Point2D {
  const elapsedSec = Math.max(0, (now - decoy.spawnedAt) / 1000);
  const distanceKm = (GHOST_DECOY_SPEED_MPS * elapsedSec) / 1000;
  const destination = turf.destination([decoy.originLng, decoy.originLat], distanceKm, decoy.bearingDegrees, {
    units: 'kilometers',
  });
  return { lng: destination.geometry.coordinates[0], lat: destination.geometry.coordinates[1] };
}

export function isWithinAnySafeZone(session: Map<string, PlayerState>, point: Point2D): boolean {
  for (const p of session.values()) {
    const buff = p.activeBuffs.SAFE_ZONE_FLARE;
    if (buff && buff.expiresAt > Date.now() && buff.meta) {
      const meta = buff.meta as { lat: number; lng: number; radiusMeters: number };
      const distance = haversineMeters(point.lat, point.lng, meta.lat, meta.lng);
      if (distance <= meta.radiusMeters) return true;
    }
  }
  return false;
}

function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) * Math.cos((lat2 * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}
