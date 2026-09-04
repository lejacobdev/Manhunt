import { Prisma } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { generateArrestCode, generateGameCode } from '../utils/arrestCode';
import { overpassSpawner } from './OverpassSpawner';
import { GameMode, HUNTER_STARTING_HEARTS, Point2D, PowerUpType, RUNNER_STARTING_HEARTS } from '../types';

export interface CreateSessionInput {
  hostId: string;
  durationMinutes: number;
  radarIntervalSec: number;
  boundsPolygon: Point2D[];
  powerUpCount?: number;
  mode?: GameMode;
  jailEnabled?: boolean;
  jailPolygon?: Point2D[];
  gamblingEnabled?: boolean;
}

export interface GameSettings {
  durationMinutes: number;
  radarIntervalSec: number;
  boundsPolygon: Point2D[];
  extractionPoint?: Point2D;
  jailEnabled?: boolean;
  jailPolygon?: Point2D[];
  gamblingEnabled?: boolean;
}

export class GameService {
  public async createSession(input: CreateSessionInput) {
    let code = generateGameCode();
    // Guarantee uniqueness of the human-readable join code.
    while (await prisma.gameSession.findUnique({ where: { code } })) {
      code = generateGameCode();
    }

    // Standard mode's alternate win condition: reach a designated, verified
    // public-land extraction point. Auto-selected from real Overpass data
    // (parks/footways/plazas) rather than requiring host-side UI to place one.
    let extractionPoint: Point2D | undefined;
    if ((input.mode ?? 'STANDARD') === 'STANDARD') {
      const extractionCandidates = await overpassSpawner.generatePublicPowerUpSpawns(input.boundsPolygon, 1);
      extractionPoint = extractionCandidates[0];
    }

    const settings: GameSettings = {
      durationMinutes: input.durationMinutes,
      radarIntervalSec: input.radarIntervalSec,
      boundsPolygon: input.boundsPolygon,
      extractionPoint,
      jailEnabled: input.jailEnabled ?? false,
      jailPolygon: input.jailEnabled ? input.jailPolygon : undefined,
      gamblingEnabled: input.gamblingEnabled ?? false,
    };

    const session = await prisma.gameSession.create({
      data: {
        code,
        hostId: input.hostId,
        status: 'LOBBY',
        mode: input.mode ?? 'STANDARD',
        settings: settings as unknown as Prisma.InputJsonValue,
      },
    });

    const spawnPoints = await overpassSpawner.generatePublicPowerUpSpawns(
      input.boundsPolygon,
      input.powerUpCount ?? 8
    );

    const powerUpTypes: PowerUpType[] = [
      'INVISIBILITY_10MIN',
      'GHOST_DECOY',
      'EMP_JAMMER',
      'THERMAL_VISION',
      'ADRENALINE',
      'SAFE_ZONE_FLARE',
    ];

    const expiresAt = new Date(Date.now() + input.durationMinutes * 60 * 1000);

    await prisma.powerUpSpawn.createMany({
      data: spawnPoints.map((pt) => ({
        sessionId: session.id,
        type: powerUpTypes[Math.floor(Math.random() * powerUpTypes.length)],
        latitude: pt.lat,
        longitude: pt.lng,
        expiresAt,
      })),
    });

    return session;
  }

  public async joinSession(
    sessionId: string,
    userId: string,
    role: 'HUNTER' | 'RUNNER' | 'SPECTATOR',
    squad?: string
  ) {
    const existing = await prisma.gamePlayer.findUnique({
      where: { sessionId_userId: { sessionId, userId } },
    });
    if (existing) return existing;

    const hearts = role === 'HUNTER' ? HUNTER_STARTING_HEARTS : role === 'RUNNER' ? RUNNER_STARTING_HEARTS : 0;

    return prisma.gamePlayer.create({
      data: {
        sessionId,
        userId,
        role,
        squad,
        arrestCode: generateArrestCode(),
        inventory: [],
        activeBuffs: {},
        hearts,
      },
    });
  }

  public async startSession(sessionId: string) {
    return prisma.gameSession.update({
      where: { id: sessionId },
      data: { status: 'ACTIVE', startedAt: new Date() },
    });
  }

  public async endSession(sessionId: string) {
    return prisma.gameSession.update({
      where: { id: sessionId },
      data: { status: 'ENDED', endedAt: new Date() },
    });
  }

  public async recordCatch(sessionId: string, hunterPlayerId: string, runnerPlayerId: string) {
    await prisma.gamePlayer.update({
      where: { id: runnerPlayerId },
      data: { isCaught: true, caughtAt: new Date() },
    });
    return prisma.gameEvent.create({
      data: {
        sessionId,
        type: 'CATCH',
        payload: { hunterPlayerId, runnerPlayerId, timestamp: new Date().toISOString() },
      },
    });
  }

  /** Alternate win condition: a runner who reaches the designated extraction point is safe for the rest of the match. */
  public async recordExtraction(sessionId: string, playerId: string) {
    await prisma.gamePlayer.update({
      where: { id: playerId },
      data: { isExtracted: true, extractedAt: new Date() },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'EXTRACTED', payload: { playerId, timestamp: new Date().toISOString() } },
    });
  }

  /** A runner accepted a catch request — jailed (confined, still in the match) if jail mode
   *  is on for this session, otherwise resolved exactly like the old code-entry catch. */
  public async recordCatchAccepted(sessionId: string, hunterPlayerId: string, runnerPlayerId: string, jailed: boolean) {
    await prisma.gamePlayer.update({
      where: { id: runnerPlayerId },
      data: { isCaught: true, caughtAt: new Date(), isJailed: jailed },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'CATCH', payload: { hunterPlayerId, runnerPlayerId, jailed, timestamp: new Date().toISOString() } },
    });
  }

  /** A gamble's final, persisted heart totals — `hunterHeartsAfter` is always the hunter's
   *  pre-gamble baseline (a hunter's gamble loss heals back immediately; only a runner's
   *  loss persists), so this write is a no-op for the hunter unless they were unaffected. */
  public async recordGambleResult(
    sessionId: string,
    hunterPlayerId: string,
    runnerPlayerId: string,
    gambleChoice: 'heads' | 'tails',
    result: 'heads' | 'tails',
    heartsLostBy: 'HUNTER' | 'RUNNER',
    hunterHeartsAfter: number,
    runnerHeartsAfter: number
  ) {
    await prisma.gamePlayer.update({ where: { id: hunterPlayerId }, data: { hearts: hunterHeartsAfter } });
    await prisma.gamePlayer.update({ where: { id: runnerPlayerId }, data: { hearts: runnerHeartsAfter } });
    return prisma.gameEvent.create({
      data: {
        sessionId,
        type: 'GAMBLE',
        payload: { hunterPlayerId, runnerPlayerId, gambleChoice, result, heartsLostBy, hunterHeartsAfter, runnerHeartsAfter },
      },
    });
  }

  /** Full elimination — either role, via boundary/storm damage, a lost-all-hearts gamble
   *  (runner only), or breaking jail. Distinct from `isCaught`: a jailed runner is caught
   *  but not out; this is the terminal "now a spectator" state. */
  public async recordPlayerOut(sessionId: string, playerId: string, reason: 'GAMBLE' | 'BOUNDARY' | 'JAIL_BREACH') {
    await prisma.gamePlayer.update({
      where: { id: playerId },
      data: { isOut: true, outAt: new Date() },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'PLAYER_OUT', payload: { playerId, reason, timestamp: new Date().toISOString() } },
    });
  }

  /** Squad mode: a squadmate within range of a caught teammate can revive them back into play. */
  public async revivePlayer(sessionId: string, playerId: string, revivedById: string) {
    await prisma.gamePlayer.update({
      where: { id: playerId },
      data: { isCaught: false, caughtAt: null },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'REVIVED', payload: { playerId, revivedById, timestamp: new Date().toISOString() } },
    });
  }

  /** Host override: force-resolve a disputed catch/status. */
  public async hostOverridePlayerStatus(sessionId: string, playerId: string, isCaught: boolean) {
    await prisma.gamePlayer.update({
      where: { id: playerId },
      data: { isCaught, caughtAt: isCaught ? new Date() : null },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'HOST_OVERRIDE', payload: { playerId, isCaught, timestamp: new Date().toISOString() } },
    });
  }

  /** INFECTION mode: a caught runner flips sides and rejoins as a hunter instead of being eliminated. */
  public async convertRunnerToHunter(sessionId: string, playerId: string) {
    await prisma.gamePlayer.update({
      where: { id: playerId },
      data: { role: 'HUNTER', isCaught: false, caughtAt: null },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'INFECTED', payload: { playerId, timestamp: new Date().toISOString() } },
    });
  }

  public async recordPowerUpCollected(sessionId: string, spawnId: string, playerId: string) {
    await prisma.powerUpSpawn.update({
      where: { id: spawnId },
      data: { isCollected: true, collectedBy: playerId },
    });
    return prisma.gameEvent.create({
      data: { sessionId, type: 'POWERUP_COLLECTED', payload: { spawnId, playerId } },
    });
  }

  public async recordPowerUpUsed(sessionId: string, playerId: string, powerUpType: PowerUpType) {
    return prisma.gameEvent.create({
      data: { sessionId, type: 'POWERUP_USED', payload: { playerId, powerUpType } },
    });
  }

  public async logLocationBatch(
    sessionId: string,
    entries: { playerId: string; lat: number; lng: number; accuracy: number; speed?: number }[]
  ) {
    if (entries.length === 0) return;
    await prisma.locationLog.createMany({
      data: entries.map((e) => ({
        sessionId,
        playerId: e.playerId,
        latitude: e.lat,
        longitude: e.lng,
        accuracy: e.accuracy,
        speed: e.speed,
      })),
    });
  }

  public async getSessionByCode(code: string) {
    return prisma.gameSession.findUnique({
      where: { code },
      include: {
        // select (not include: true) so passwordHash never leaves the server in a
        // session/player payload — every /games route returns this verbatim to clients.
        players: { include: { user: { select: { id: true, username: true, userTag: true, avatarUrl: true } } } },
        powerUps: true,
      },
    });
  }
}

export const gameService = new GameService();
