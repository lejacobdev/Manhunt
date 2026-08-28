import { Prisma } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { generateArrestCode, generateGameCode } from '../utils/arrestCode';
import { overpassSpawner } from './OverpassSpawner';
import { GameMode, Point2D, PowerUpType } from '../types';

export interface CreateSessionInput {
  hostId: string;
  durationMinutes: number;
  radarIntervalSec: number;
  boundsPolygon: Point2D[];
  powerUpCount?: number;
  mode?: GameMode;
}

export class GameService {
  public async createSession(input: CreateSessionInput) {
    let code = generateGameCode();
    // Guarantee uniqueness of the human-readable join code.
    while (await prisma.gameSession.findUnique({ where: { code } })) {
      code = generateGameCode();
    }

    const session = await prisma.gameSession.create({
      data: {
        code,
        hostId: input.hostId,
        status: 'LOBBY',
        mode: input.mode ?? 'STANDARD',
        settings: {
          durationMinutes: input.durationMinutes,
          radarIntervalSec: input.radarIntervalSec,
          boundsPolygon: input.boundsPolygon,
        } as unknown as Prisma.InputJsonValue,
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
    role: 'HUNTER' | 'RUNNER' | 'SUPERVISOR' | 'SPECTATOR',
    squad?: string
  ) {
    const existing = await prisma.gamePlayer.findUnique({
      where: { sessionId_userId: { sessionId, userId } },
    });
    if (existing) return existing;

    return prisma.gamePlayer.create({
      data: {
        sessionId,
        userId,
        role,
        squad,
        arrestCode: generateArrestCode(),
        inventory: [],
        activeBuffs: {},
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
      include: { players: { include: { user: true } }, powerUps: true },
    });
  }
}

export const gameService = new GameService();
