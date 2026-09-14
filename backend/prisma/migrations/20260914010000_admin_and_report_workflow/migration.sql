-- CreateEnum
CREATE TYPE "ReportStatus" AS ENUM ('OPEN', 'RESOLVED', 'DISMISSED');

-- AlterTable
ALTER TABLE "User" ADD COLUMN "isAdmin" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "User" ADD COLUMN "isBanned" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "User" ADD COLUMN "bannedAt" TIMESTAMP(3);
ALTER TABLE "User" ADD COLUMN "banReason" TEXT;

-- AlterTable
-- Existing reports are all unhandled by definition, so OPEN is the correct backfill.
ALTER TABLE "Report" ADD COLUMN "status" "ReportStatus" NOT NULL DEFAULT 'OPEN';
ALTER TABLE "Report" ADD COLUMN "adminResponse" TEXT;
ALTER TABLE "Report" ADD COLUMN "respondedAt" TIMESTAMP(3);
ALTER TABLE "Report" ADD COLUMN "handledBy" TEXT;

-- CreateIndex
CREATE INDEX "Report_status_idx" ON "Report"("status");

-- CreateTable
CREATE TABLE "AdminAction" (
    "id" TEXT NOT NULL,
    "adminId" TEXT NOT NULL,
    "adminName" TEXT NOT NULL,
    "action" TEXT NOT NULL,
    "targetType" TEXT NOT NULL,
    "targetId" TEXT NOT NULL,
    "detail" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "AdminAction_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "AdminAction_createdAt_idx" ON "AdminAction"("createdAt");
CREATE INDEX "AdminAction_targetId_idx" ON "AdminAction"("targetId");
