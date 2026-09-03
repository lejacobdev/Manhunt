-- Remove the SUPERVISOR role: hosting a game no longer forces a separate
-- observer-only role — the host picks HUNTER/RUNNER/SPECTATOR like anyone
-- else and keeps host-only admin actions (end game, override a catch)
-- via GameSession.hostId instead of a role check.
--
-- Any existing SUPERVISOR rows are remapped to SPECTATOR first (the closest
-- existing role — both are non-playing observers) since Postgres can't cast
-- a value into an enum type that no longer has that member.
BEGIN;

UPDATE "GamePlayer" SET "role" = 'SPECTATOR' WHERE "role" = 'SUPERVISOR';

CREATE TYPE "PlayerRole_new" AS ENUM ('HUNTER', 'RUNNER', 'SPECTATOR');
ALTER TABLE "GamePlayer" ALTER COLUMN "role" TYPE "PlayerRole_new" USING ("role"::text::"PlayerRole_new");
ALTER TYPE "PlayerRole" RENAME TO "PlayerRole_old";
ALTER TYPE "PlayerRole_new" RENAME TO "PlayerRole";
DROP TYPE "PlayerRole_old";

COMMIT;
