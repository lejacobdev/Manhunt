import * as turf from '@turf/turf';
import { Point2D } from '../types';

export interface ZoneState {
  center: Point2D;
  radiusMeters: number;
  fullRadiusMeters: number;
  finalRadiusMeters: number;
  progress: number; // 0 at match start, 1 at match end
}

const FINAL_RADIUS_METERS = 40;

/**
 * Standard-mode shrinking safe zone: a circle centered on the play area's
 * centroid that linearly contracts from the boundary's own radius down to a
 * small final radius as the match clock runs out, pushing runners toward a
 * shared public center rather than letting them camp the map edge for the
 * whole match.
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
  const centroidFeature = turf.centroid(poly);
  const center: Point2D = { lat: centroidFeature.geometry.coordinates[1], lng: centroidFeature.geometry.coordinates[0] };

  let fullRadiusMeters = 0;
  for (const p of boundsPolygon) {
    const d = turf.distance(turf.point([center.lng, center.lat]), turf.point([p.lng, p.lat]), { units: 'meters' });
    if (d > fullRadiusMeters) fullRadiusMeters = d;
  }
  fullRadiusMeters = Math.max(fullRadiusMeters, FINAL_RADIUS_METERS * 2);

  const elapsedMs = now.getTime() - startedAt.getTime();
  const totalMs = durationMinutes * 60 * 1000;
  const progress = Math.min(1, Math.max(0, elapsedMs / totalMs));

  const radiusMeters = fullRadiusMeters - (fullRadiusMeters - FINAL_RADIUS_METERS) * progress;

  return { center, radiusMeters, fullRadiusMeters, finalRadiusMeters: FINAL_RADIUS_METERS, progress };
}

export function distanceOutsideZone(point: Point2D, zone: ZoneState): number {
  const d = turf.distance(turf.point([zone.center.lng, zone.center.lat]), turf.point([point.lng, point.lat]), {
    units: 'meters',
  });
  return Math.max(0, d - zone.radiusMeters);
}
