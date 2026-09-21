-- Sign in with Apple / Game Center identities, and owner-initiated renames.

-- An account created through a provider has no password at all. Existing rows keep theirs.
ALTER TABLE "User" ALTER COLUMN "passwordHash" DROP NOT NULL;

ALTER TABLE "User" ADD COLUMN "appleUserId" TEXT;
ALTER TABLE "User" ADD COLUMN "gameCenterPlayerId" TEXT;
ALTER TABLE "User" ADD COLUMN "nameChangedAt" TIMESTAMP(3);

-- One account per Apple identity and per Game Center player. Postgres unique indexes ignore
-- NULLs, so every existing account (both columns null) stays valid.
CREATE UNIQUE INDEX "User_appleUserId_key" ON "User"("appleUserId");
CREATE UNIQUE INDEX "User_gameCenterPlayerId_key" ON "User"("gameCenterPlayerId");
