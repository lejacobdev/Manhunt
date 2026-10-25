/**
 * Every cosmetic in the game. Cosmetics are looks only — nothing here changes how a match plays
 * or who wins. Each item is free, unlocked by playing (a career-stat milestone), or part of an
 * App Store pack; the Supporter purchase includes every pack plus Supporter-only items.
 *
 * The app renders items by id (colours, glyphs, map styles live in CosmeticStyle.swift), so an id
 * here must never be renamed once shipped — players own it.
 */

export type CosmeticCategory = 'mapStyle' | 'radarSkin' | 'marker' | 'banner' | 'badge';

export type UnlockStat = 'matchesPlayed' | 'wins' | 'catchesMade' | 'minutesPlayed' | 'powerUpsCollected' | 'playersRecruited';

export interface CosmeticItem {
  id: string;
  category: CosmeticCategory;
  name: string;
  description: string;
  unlock:
    | { kind: 'free' }
    | { kind: 'play'; stat: UnlockStat; goal: number; label: string }
    | { kind: 'pack'; productId: string }
    | { kind: 'supporter' };
}

export interface CosmeticProduct {
  productId: string;
  name: string;
  description: string;
  /** Item ids this product grants (the Supporter product grants every pack's items too). */
  items: string[];
}

const P = 'com.huntinggame.app';
export const PRODUCT_IDS = {
  maps: `${P}.pack.maps`,
  radar: `${P}.pack.radar`,
  markers: `${P}.pack.markers`,
  banners: `${P}.pack.banners`,
  supporter: `${P}.supporter`,
} as const;

export const COSMETICS: CosmeticItem[] = [
  // Map style — only you see it.
  { id: 'map.standard', category: 'mapStyle', name: 'Standard', description: 'The classic dark map.', unlock: { kind: 'free' } },
  { id: 'map.muted', category: 'mapStyle', name: 'Night Ops', description: 'A muted map that lets blips and zones stand out.', unlock: { kind: 'play', stat: 'matchesPlayed', goal: 5, label: 'Play 5 matches' } },
  { id: 'map.satellite', category: 'mapStyle', name: 'Satellite', description: 'Real aerial imagery.', unlock: { kind: 'pack', productId: PRODUCT_IDS.maps } },
  { id: 'map.hybrid', category: 'mapStyle', name: 'Hybrid', description: 'Aerial imagery with street names.', unlock: { kind: 'pack', productId: PRODUCT_IDS.maps } },

  // Radar skin — only you see it.
  { id: 'radar.classic', category: 'radarSkin', name: 'Classic', description: 'Your role colour.', unlock: { kind: 'free' } },
  { id: 'radar.ghost', category: 'radarSkin', name: 'Ghost', description: 'A spectral violet sweep.', unlock: { kind: 'play', stat: 'wins', goal: 10, label: 'Win 10 matches' } },
  { id: 'radar.arctic', category: 'radarSkin', name: 'Arctic', description: 'Ice-blue sweep.', unlock: { kind: 'pack', productId: PRODUCT_IDS.radar } },
  { id: 'radar.gold', category: 'radarSkin', name: 'Gold', description: 'A gold sweep.', unlock: { kind: 'pack', productId: PRODUCT_IDS.radar } },
  { id: 'radar.mono', category: 'radarSkin', name: 'Mono', description: 'Pure white, maximum contrast.', unlock: { kind: 'pack', productId: PRODUCT_IDS.radar } },
  { id: 'radar.supporter', category: 'radarSkin', name: 'Supporter', description: 'An aurora sweep for Supporters.', unlock: { kind: 'supporter' } },

  // Map marker — your teammates see it.
  { id: 'marker.default', category: 'marker', name: 'Standard', description: 'The role figure.', unlock: { kind: 'free' } },
  { id: 'marker.hare', category: 'marker', name: 'Hare', description: 'Fast and hard to catch.', unlock: { kind: 'play', stat: 'catchesMade', goal: 25, label: 'Make 25 catches' } },
  { id: 'marker.bolt', category: 'marker', name: 'Bolt', description: 'A lightning bolt.', unlock: { kind: 'pack', productId: PRODUCT_IDS.markers } },
  { id: 'marker.flame', category: 'marker', name: 'Flame', description: 'A flame.', unlock: { kind: 'pack', productId: PRODUCT_IDS.markers } },
  { id: 'marker.star', category: 'marker', name: 'Star', description: 'A star.', unlock: { kind: 'pack', productId: PRODUCT_IDS.markers } },
  { id: 'marker.paw', category: 'marker', name: 'Paw', description: 'A paw print.', unlock: { kind: 'pack', productId: PRODUCT_IDS.markers } },

  // Profile banner — everyone sees it.
  { id: 'banner.default', category: 'banner', name: 'Standard', description: 'Cyan, like the radar.', unlock: { kind: 'free' } },
  { id: 'banner.royal', category: 'banner', name: 'Royal', description: 'Deep violet.', unlock: { kind: 'play', stat: 'matchesPlayed', goal: 20, label: 'Play 20 matches' } },
  { id: 'banner.toxic', category: 'banner', name: 'Toxic', description: 'Acid green.', unlock: { kind: 'play', stat: 'powerUpsCollected', goal: 25, label: 'Collect 25 power-ups' } },
  { id: 'banner.ember', category: 'banner', name: 'Ember', description: 'Red to amber.', unlock: { kind: 'pack', productId: PRODUCT_IDS.banners } },
  { id: 'banner.ice', category: 'banner', name: 'Ice', description: 'White to cyan.', unlock: { kind: 'pack', productId: PRODUCT_IDS.banners } },
  { id: 'banner.aurora', category: 'banner', name: 'Aurora', description: 'Green to violet.', unlock: { kind: 'pack', productId: PRODUCT_IDS.banners } },
  { id: 'banner.supporter', category: 'banner', name: 'Supporter', description: 'Gold, for Supporters.', unlock: { kind: 'supporter' } },

  // Badge — everyone sees it, on your profile and in the lobby.
  { id: 'badge.none', category: 'badge', name: 'None', description: 'No badge.', unlock: { kind: 'free' } },
  { id: 'badge.tracker', category: 'badge', name: 'Tracker', description: 'For 50 catches.', unlock: { kind: 'play', stat: 'catchesMade', goal: 50, label: 'Make 50 catches' } },
  { id: 'badge.marathon', category: 'badge', name: 'Marathon', description: 'For 10 hours of play.', unlock: { kind: 'play', stat: 'minutesPlayed', goal: 600, label: 'Play for 10 hours' } },
  { id: 'badge.recruiter', category: 'badge', name: 'Recruiter', description: 'For hosting 3 players in their first ever match.', unlock: { kind: 'play', stat: 'playersRecruited', goal: 3, label: 'Bring 3 new players' } },
  { id: 'badge.veteran', category: 'badge', name: 'Veteran', description: 'For 100 matches.', unlock: { kind: 'play', stat: 'matchesPlayed', goal: 100, label: 'Play 100 matches' } },
  { id: 'badge.supporter', category: 'badge', name: 'Supporter', description: 'Thanks for supporting Hunting Game.', unlock: { kind: 'supporter' } },
];

const packItems = (productId: string) => COSMETICS.filter((c) => c.unlock.kind === 'pack' && c.unlock.productId === productId).map((c) => c.id);

export const PRODUCTS: CosmeticProduct[] = [
  { productId: PRODUCT_IDS.maps, name: 'Map Pack', description: 'Satellite and Hybrid map styles.', items: packItems(PRODUCT_IDS.maps) },
  { productId: PRODUCT_IDS.radar, name: 'Radar Skins', description: 'Arctic, Gold and Mono radar sweeps.', items: packItems(PRODUCT_IDS.radar) },
  { productId: PRODUCT_IDS.markers, name: 'Marker Pack', description: 'Bolt, Flame, Star and Paw map markers.', items: packItems(PRODUCT_IDS.markers) },
  { productId: PRODUCT_IDS.banners, name: 'Banner Pack', description: 'Ember, Ice and Aurora profile banners.', items: packItems(PRODUCT_IDS.banners) },
  {
    productId: PRODUCT_IDS.supporter,
    name: 'Supporter',
    description: 'Every pack, plus a Supporter badge, banner and radar. Keeps Hunting Game free and ad-free.',
    items: [
      ...packItems(PRODUCT_IDS.maps), ...packItems(PRODUCT_IDS.radar), ...packItems(PRODUCT_IDS.markers), ...packItems(PRODUCT_IDS.banners),
      ...COSMETICS.filter((c) => c.unlock.kind === 'supporter').map((c) => c.id),
    ],
  },
];

export const CATEGORIES: CosmeticCategory[] = ['mapStyle', 'radarSkin', 'marker', 'banner', 'badge'];
export const DEFAULTS: Record<CosmeticCategory, string> = {
  mapStyle: 'map.standard', radarSkin: 'radar.classic', marker: 'marker.default', banner: 'banner.default', badge: 'badge.none',
};
export const byId = new Map(COSMETICS.map((c) => [c.id, c]));
