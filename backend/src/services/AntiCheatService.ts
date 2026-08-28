import { ADRENALINE_SPEED_MPS, MAX_HUMAN_SPEED_MPS, PlayerState } from '../types';

export interface SpeedCheckResult {
  allowed: boolean;
  reason?: string;
  ceilingMps: number;
}

/**
 * Rejects location updates that imply superhuman movement, accounting for
 * the temporary ceiling raise granted by an active ADRENALINE power-up.
 */
export function checkSpeed(player: PlayerState, speedMps: number | undefined): SpeedCheckResult {
  const hasAdrenaline =
    !!player.activeBuffs.ADRENALINE && player.activeBuffs.ADRENALINE.expiresAt > Date.now();
  const ceiling = hasAdrenaline ? ADRENALINE_SPEED_MPS : MAX_HUMAN_SPEED_MPS;

  if (typeof speedMps === 'number' && speedMps > ceiling) {
    return {
      allowed: false,
      reason: `Movement velocity ${speedMps.toFixed(2)} m/s exceeded maximum threshold of ${ceiling.toFixed(2)} m/s.`,
      ceilingMps: ceiling,
    };
  }
  return { allowed: true, ceilingMps: ceiling };
}

/**
 * Basic GPS-jump detector: rejects an implied teleport between two fixes
 * that no continuous foot movement (even at the raised ADRENALINE ceiling)
 * could explain.
 */
export function checkTeleport(
  prev: { lat: number; lng: number; timestamp: number } | undefined,
  next: { lat: number; lng: number; timestamp: number },
  ceilingMps: number
): boolean {
  if (!prev) return true;
  const dtSec = Math.max(0.5, (next.timestamp - prev.timestamp) / 1000);
  const distanceMeters = haversineMeters(prev.lat, prev.lng, next.lat, next.lng);
  const impliedSpeed = distanceMeters / dtSec;
  return impliedSpeed <= ceilingMps * 1.15; // small tolerance for GPS jitter
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
