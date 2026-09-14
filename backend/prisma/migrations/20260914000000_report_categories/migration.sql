-- CreateEnum
CREATE TYPE "ReportCategory" AS ENUM ('CHEATING', 'INAPPROPRIATE_USERNAME', 'HARASSMENT', 'THREATS', 'SEXUAL_CONTENT', 'IMPERSONATION', 'UNSAFE_PLAY', 'OTHER');

-- AlterTable
-- Existing rows keep whatever prose they were filed with and land in OTHER, which is
-- accurate: they predate categories, so nothing finer can be inferred about them.
ALTER TABLE "Report" ADD COLUMN "category" "ReportCategory" NOT NULL DEFAULT 'OTHER';
ALTER TABLE "Report" ALTER COLUMN "reason" DROP NOT NULL;

-- CreateIndex
CREATE INDEX "Report_category_idx" ON "Report"("category");
