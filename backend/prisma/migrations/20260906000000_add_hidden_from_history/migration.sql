-- "Clear history" hides a player's own past-match rows from their own history list
-- without touching the underlying GameSession/GamePlayer data other members of that
-- same match still rely on (replays, other players' own history).
ALTER TABLE "GamePlayer" ADD COLUMN     "hiddenFromHistory" BOOLEAN NOT NULL DEFAULT false;
