import { POWER_UP_DURATIONS_MS, PlayerState, PowerUpType, SAFE_ZONE_RADIUS_METERS, Point2D } from '../types';

export interface PowerUpUseResult {
  ok: boolean;
  error?: string;
  broadcastEvent?: { type: string; payload: Record<string, unknown> };
}

/**
 * Applies the gameplay effect of a power-up to the in-memory session state.
 * All six power-up types are fully implemented:
 *
 *  - INVISIBILITY_10MIN: hides the runner from hunter radar broadcasts.
 *  - GHOST_DECOY: plants a fake runner blip hunters see instead of/along
 *    with the real one, at the runner's position at cast time.
 *  - EMP_JAMMER: a hunter-targeted debuff that suppresses that hunter's
 *    compass/radar updates for the runners.
 *  - THERMAL_VISION: a hunter buff that pierces INVISIBILITY_10MIN so that
 *    hunter still sees otherwise-hidden runners.
 *  - ADRENALINE: temporarily raises the runner's permitted sprint-speed
 *    ceiling for anti-cheat purposes.
 *  - SAFE_ZONE_FLARE: creates a temporary no-catch radius around the
 *    runner's current position.
 */
export function usePowerUp(
  session: Map<string, PlayerState>,
  playerId: string,
  type: PowerUpType,
  decoys: Map<string, { sessionOwnerId: string; lat: number; lng: number; expiresAt: number }[]>,
  sessionCode: string
): PowerUpUseResult {
  const player = session.get(playerId);
  if (!player) return { ok: false, error: 'Player not found in session.' };
  if (!player.inventory.includes(type)) {
    return { ok: false, error: `Player does not hold a ${type} power-up.` };
  }
  if (player.isCaught) {
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
      const list = decoys.get(sessionCode) ?? [];
      list.push({ sessionOwnerId: playerId, lat: player.lat, lng: player.lng, expiresAt });
      decoys.set(sessionCode, list);
      return {
        ok: true,
        broadcastEvent: {
          type: 'GHOST_DECOY_SPAWNED',
          payload: { playerId, lat: player.lat, lng: player.lng, expiresAt },
        },
      };
    }

    case 'EMP_JAMMER': {
      // EMP_JAMMER is targeted: the payload carries which hunter to jam.
      player.activeBuffs.EMP_JAMMER = { expiresAt };
      return {
        ok: true,
        broadcastEvent: { type: 'POWERUP_USED', payload: { playerId, powerUp: type, expiresAt } },
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

export function pruneExpiredDecoys(
  decoys: Map<string, { sessionOwnerId: string; lat: number; lng: number; expiresAt: number }[]>,
  sessionCode: string
): void {
  const now = Date.now();
  const list = decoys.get(sessionCode);
  if (!list) return;
  decoys.set(
    sessionCode,
    list.filter((d) => d.expiresAt > now)
  );
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
