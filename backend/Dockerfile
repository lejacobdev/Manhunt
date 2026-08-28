FROM node:20-alpine AS build
WORKDIR /app
# Prisma's engine binaries link against OpenSSL and fail to even start
# without it — node:20-alpine doesn't ship it. Installing it here (before
# `prisma generate`) lets Prisma correctly detect the real OpenSSL version
# and fetch the matching engine, instead of guessing and getting it wrong.
RUN apk add --no-cache openssl
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npx prisma generate
RUN npm run build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
# Needed again in the runtime stage: the engine binary generated above
# needs libssl present at runtime, not just at generate-time.
RUN apk add --no-cache openssl
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/package.json ./package.json

EXPOSE 4000
# Applies any pending migrations, then starts the server — safe to run on
# every container start, it's a no-op once the schema is up to date.
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/index.js"]
