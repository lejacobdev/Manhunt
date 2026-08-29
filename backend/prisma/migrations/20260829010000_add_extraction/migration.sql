-- AlterTable
ALTER TABLE "GamePlayer" ADD COLUMN     "extractedAt" TIMESTAMP(3),
ADD COLUMN     "isExtracted" BOOLEAN NOT NULL DEFAULT false;
