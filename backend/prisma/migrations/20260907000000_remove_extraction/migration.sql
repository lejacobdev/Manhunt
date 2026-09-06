-- Extraction (a runner reaching a designated point to survive outright) is removed as a
-- game mechanic — a runner now only ever resolves by being caught or eliminated. The
-- corresponding `extractionPoint` field lived in GameSession.settings (a JSON blob, not a
-- real column), so nothing to drop there; any already-persisted "EXTRACTED" GameEvent rows
-- are left alone as harmless historical data (GameEvent.type is a free-text column, not an
-- enum, and nothing reads that value anymore).
ALTER TABLE "GamePlayer" DROP COLUMN "isExtracted",
DROP COLUMN "extractedAt";
