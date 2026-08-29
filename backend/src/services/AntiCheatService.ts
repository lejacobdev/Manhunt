import { ADRENALINE_SPEED_MPS, MAX_ACCURACY_METERS, MAX_HUMAN_SPEED_MPS, PlayerState } from '../types';

export interface SpeedCheckResult {
  allowed: boolean;
  reason?: string;
  ceilingMps: number;
}

export interface SimpleCheckResult {
  allowed: boolean;
  reason?: string;
}

/**
 * GPS spoofing / signal quality guard: rejects fixes with unusably poor
 * horizontal accuracy. The iOS client already filters these client-side,
 * but that alone is trivially bypassed by a modified client — this is the
 * check that actually matters.
 */
export function checkAccuracy(accuracyMeters: number): SimpleCheckResult {
  if (accuracyMeters > MAX_ACCURACY_METERS) {
    return {
      allowed: false,
      reason: `GPS accuracy ${accuracyMeters.toFixed(1)}m exceeds the ${MAX_ACCURACY_METERS}m threshold.`,
    };
  }
  return { allowed: true };
}

/**
 * Cross-references the client's CoreMotion-derived on-foot signal. The iOS
 * client only reports isMovingOnFoot=false when CMMotionActivityManager
 * explicitly detects automotive or cycling activity (not merely "unknown"),
 * so this is a deliberate, low-false-positive signal worth rejecting on.
 */
export function checkMotion(isMovingOnFoot: boolean): SimpleCheckResult {
  if (!isMovingOnFoot) {
    return { allowed: false, reason: 'Motion sensors indicate non-foot travel (vehicle or bicycle).' };
  }
  return { allowed: true };
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
