-- Hearts (both roles), jail confinement, and full-elimination tracking for the new
-- request/accept/gamble catch flow and the boundary/jail containment mechanics that
-- replace the old shrinking-zone auto-catch. See ZoneService.ts's removal in this
-- same change for the mechanic this heart system replaces.
ALTER TABLE "GamePlayer" ADD COLUMN     "hearts" INTEGER NOT NULL DEFAULT 3,
ADD COLUMN     "isJailed" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "isOut" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "outAt" TIMESTAMP(3);
