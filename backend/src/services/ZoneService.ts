import * as turf from '@turf/turf';
import { Point2D, ZONE_FINAL_RADIUS_METERS } from '../types';

export interface ZoneState {
  center: Point2D;
  radiusMeters: number;
  fullRadiusMeters: number;
  finalRadiusMeters: number;
  progress: number; // 0 at match start, 1 at match end
}

/**
 * The shrinking play zone: a circle centered on the play area's centroid that
 * linearly contracts from the boundary's own circumscribed radius down to a
 * small final radius as the match clock runs out, pushing players toward a
 * shared center rather than letting them camp the map edge all match.
 *
 * Unlike the original version of this (which auto-caught a runner who stayed
 * outside it), being outside the zone now feeds the same slow heart drain the
 * outer boundary uses — see checkContainment in server.ts.
 */
export function computeZoneState(
  boundsPolygon: Point2D[],
  startedAt: Date,
  durationMinutes: number,
  now: Date = new Date()
): ZoneState {
  const ring = boundsPolygon.map((p) => [p.lng, p.lat]);
  ring.push([boundsPolygon[0].lng, boundsPolygon[0].lat]);
  const poly = turf.polygon([ring]);
  // The zone closes in on a point that is guaranteed to be inside the play area. The plain
  // centroid of an L-shaped or crescent area lies outside it, which made the final circle sit
  // outside the boundary and drained everyone's hearts at the end however well they played.
  let centerFeature = turf.centroid(poly);
  if (!turf.booleanPointInPolygon(centerFeature, poly)) centerFeature = turf.pointOnFeature(poly);
  const center: Point2D = {
    lat: centerFeature.geometry.coordinates[1],
    lng: centerFeature.geometry.coordinates[0],
  };

  let fullRadiusMeters = 0;
  for (const p of boundsPolygon) {
    const d = turf.distance(turf.point([center.lng, center.lat]), turf.point([p.lng, p.lat]), { units: 'meters' });
    if (d > fullRadiusMeters) fullRadiusMeters = d;
  }
  // The final circle scales with the play area: a fixed 40 m was a sensible end for a park and
  // impossibly tight for a whole neighbourhood.
  const finalRadiusMeters = Math.min(150, Math.max(ZONE_FINAL_RADIUS_METERS, fullRadiusMeters * 0.08));
  fullRadiusMeters = Math.max(fullRadiusMeters, finalRadiusMeters * 2);

  const elapsedMs = now.getTime() - startedAt.getTime();
  const totalMs = durationMinutes * 60 * 1000;
  const progress = Math.min(1, Math.max(0, elapsedMs / totalMs));
  const shrink = zoneShrinkFraction(progress);
  const radiusMeters = fullRadiusMeters - (fullRadiusMeters - finalRadiusMeters) * shrink;

  return { center, radiusMeters, fullRadiusMeters, finalRadiusMeters, progress };
}

/**
 * How far the zone has closed (0 → 1) at a point in the match (0 → 1), scaled to the match's
 * own length rather than shrinking at one constant rate from the first second:
 *  - the first 20 % holds the full area (the head start and the early game);
 *  - it then closes slowly at first and faster later (ease-in), so the middle of the match
 *    still has room to hide and the pressure builds towards the end;
 *  - the final circle is reached at 90 % and holds for the closing stretch.
 * The old linear shrink was fastest exactly when it should be slowest, and on a 10-minute
 * match it was squeezing players from the very first minute.
 */
export function zoneShrinkFraction(progress: number): number {
  const HOLD = 0.2;
  const CLOSED = 0.9;
  const t = Math.min(1, Math.max(0, (progress - HOLD) / (CLOSED - HOLD)));
  return t * t;
}

/** Metres a point sits outside the current zone circle; 0 when inside it. */
export function distanceOutsideZone(point: Point2D, zone: ZoneState): number {
  const d = turf.distance(turf.point([zone.center.lng, zone.center.lat]), turf.point([point.lng, point.lat]), {
    units: 'meters',
  });
  return Math.max(0, d - zone.radiusMeters);
}
