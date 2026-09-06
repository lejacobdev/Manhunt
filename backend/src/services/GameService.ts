import { Prisma } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { generateArrestCode, generateGameCode } from '../utils/arrestCode';
import { overpassSpawner } from './OverpassSpawner';
import { GameMode, HUNTER_STARTING_HEARTS, Point2D, PowerUpType, RUNNER_STARTING_HEARTS } from '../types';

export interface CreateSessionInput {
  hostId: string;
  durationMinutes: number;
  /** Empty is valid — setup can finish later from the lobby via `setBoundary`, and the
   *  match can't start until it's been set (see the `/start` route's guard). */
  boundsPolygon: Point2D[];
  powerUpCount?: number;
  mode?: GameMode;
  jailEnabled?: boolean;
  jailPolygon?: Point2D[];
  gamblingEnabled?: boolean;
  antiCheatEnabled?: boolean;
}

const POWER_UP_TYPES: PowerUpType[] = [
  'INVISIBILITY_10MIN',
  'GHOST_DECOY',
  'EMP_JAMMER',
  'THERMAL_VISION',
  'ADRENALINE',
  'SAFE_ZONE_FLARE',
];

export interface GameSettings {
  durationMinutes: number;
  boundsPolygon: Point2D[];
  extractionPoint?: Point2D;
  jailEnabled?: boolean;
  jailPolygon?: Point2D[];
  gamblingEnabled?: boolean;
  /** Absent means enabled — see the route schema for why this defaults on. */
  antiCheatEnabled?: boolean;
}

export class GameService {
  public async createSession(input: CreateSessionInput) {
    let code = generateGameCode();
    // Guarantee uniqueness of the human-readable join code.
    while (await prisma.gameSession.findUnique({ where: { code } })) {
      code = generateGameCode();
    }

    const mode = input.mode ?? 'STANDARD';
    const hasBoundary = input.boundsPolygon.length >= 3;
    const extractionPoint = hasBoundary ? await this.generateExtractionPoint(input.boundsPolygon, mode) : undefined;

    const settings: GameSettings = {
      durationMinutes: input.durationMinutes,
      boundsPolygon: input.boundsPolygon,
      extractionPoint,
      jailEnabled: input.jailEnabled ?? false,
      jailPolygon: input.jailEnabled ? input.jailPolygon : undefined,
      gamblingEnabled: input.gamblingEnabled ?? false,
      antiCheatEnabled: input.antiCheatEnabled ?? true,
    };

    const session = await prisma.gameSession.create({
      data: {
        code,
        hostId: input.hostId,
        status: 'LOBBY',
        mode,
        settings: settings as unknown as Prisma.InputJsonValue,
      },
    });

    // A host can now open the lobby before drawing the play area at all — spawns only get
    // laid out once there's a real boundary to place them inside: here immediately if one
    // was supplied up front, or later from the settings route once it is.
    if (hasBoundary) {
      await this.layOutSpawns(session.id, input.boundsPolygon, input.durationMinutes, input.powerUpCount);
    }

    return session;
  }

  /** The extraction point for STANDARD mode, generated from a boundary — used both at
   *  creation and by the settings route when the boundary is set later from the lobby. */
  public async generateExtractionPoint(boundsPolygon: Point2D[], mode: GameMode): Promise<Point2D | undefined> {
    if (mode !== 'STANDARD') return undefined;
    const candidates = await overpassSpawner.generatePublicPowerUpSpawns(boundsPolygon, 1);
    return candidates[0];
  }

  /**
   * Scatters power-up spawns across a play-area boundary — at creation (a boundary supplied
   * up front), later from the lobby settings route once one is drawn, or again on every
   * subsequent redraw. Clears whatever was laid out for the previous shape first, or spawns
   * from an earlier boundary would linger outside the new play area forever.
   */
  public async layOutSpawns(sessionId: string, boundsPolygon: Point2D[], durationMinutes: number, powerUpCount?: number) {
    await prisma.powerUpSpawn.deleteMany({ where: { sessionId } });
    const spawnPoints = await overpassSpawner.generatePublicPowerUpSpawns(boundsPolygon, powerUpCount ?? 8);
    const expiresAt = new Date(Date.now() + durationMinutes * 60 * 1000);
    await prisma.powerUpSpawn.createMany({
      data: spawnPoints.map((pt) => ({
        sessionId,
        type: POWER_UP_TYPES[Math.floor(Math.random() * POWER_UP_TYPES.length)],
        latitude: pt.lat,
        longitude: pt.lng,
        expiresAt,
      })),
    });
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

  /** Host-only lobby role assignment — reseeds hearts for the new role, same as a fresh
   *  join. Only meaningful before the match starts; the socket handler enforces that. */
  public async setPlayerRole(gamePlayerId: string, role: 'HUNTER' | 'RUNNER' | 'SPECTATOR') {
    const hearts = role === 'HUNTER' ? HUNTER_STARTING_HEARTS : role === 'RUNNER' ? RUNNER_STARTING_HEARTS : 0;
    return prisma.gamePlayer.update({
      where: { id: gamePlayerId },
      data: { role, hearts },
    });
  }

  /** Host-only lobby settings edit — see the route for why boundsPolygon can't move here. */
  public async updateSessionSettings(sessionId: string, settings: GameSettings) {
    return prisma.gameSession.update({
      where: { id: sessionId },
      data: { settings: settings as unknown as Prisma.InputJsonValue },
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

  /** Full elimination — either role, via containment/storm damage, losing a gamble duel, or
   *  breaking jail. Distinct from `isCaught`: a jailed runner is caught but not out; this is
   *  the terminal "now a spectator" state. */
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
