import * as turf from '@turf/turf';
import { Point2D } from '../types';

// Same ring-closing convention as OverpassSpawner.ts's boundary polygon construction —
// kept identical rather than sharing a helper across files for a two-line function.
function closedRing(polygon: Point2D[]): number[][] {
  const ring = polygon.map((p) => [p.lng, p.lat]);
  ring.push([polygon[0].lng, polygon[0].lat]);
  return ring;
}

/** Used for both the outer game-area boundary and (separately) the jail polygon. */
export function isInsidePolygon(point: Point2D, polygon: Point2D[]): boolean {
  return turf.booleanPointInPolygon(turf.point([point.lng, point.lat]), turf.polygon([closedRing(polygon)]));
}

/** 0 if inside; otherwise the point's distance to the polygon's own outline (not its
 *  centroid), so a large polygon doesn't make "just outside the edge" read as far away. */
export function distanceOutsidePolygonMeters(point: Point2D, polygon: Point2D[]): number {
  const pt = turf.point([point.lng, point.lat]);
  if (isInsidePolygon(point, polygon)) return 0;
  return turf.pointToLineDistance(pt, turf.lineString(closedRing(polygon)), { units: 'meters' });
}
