# Game end-to-end tests

Plays every power-up through a real match over Socket.IO, with two hunters and two runners, and
checks each player's radar and compass *without anyone moving afterwards* — the case the old code
got wrong. Runs against a throwaway database, never production:

```sh
docker network create hgtest
docker run -d --name hgtest-db --network hgtest -e POSTGRES_USER=t -e POSTGRES_PASSWORD=t -e POSTGRES_DB=t postgres:16-alpine
docker build -t hg-backend-test backend
docker run -d --name hgtest-api --network hgtest -p 127.0.0.1:4555:4000 \
  -e DATABASE_URL="postgresql://t:t@hgtest-db:5432/t?schema=public" -e JWT_SECRET=test -e PORT=4000 \
  -e APNS_TEAM_ID=TESTTEAM01 -e OVERPASS_API_URL=http://127.0.0.1:9/ hg-backend-test
cd backend/scripts/e2e && npm i socket.io-client@4
node powerups.mjs   # ~75 s: every power-up, waits for buffs to expire
node rules.mjs      # ~90 s: catches, disputes, jail, jailbreaks, modes, win conditions, privacy
node ping.mjs       # ~30 s: the radar ping interval and Thermal Vision between pings
node squadup.mjs    # ~20 s: invite links, Universal Links, previews, rematches, report screenshots, Recruiter
MATCHES=60 SECONDS=60 node loadtest.mjs   # load: 60 matches × 6 players on a live radar
docker rm -f hgtest-api hgtest-db && docker network rm hgtest
```

Load test, October 2026 (16-core server, one backend process): 360 players in 60 live matches ran
smoothly (radar p50 12 ms, p95 177 ms); at 900 players the process saturates and radar updates lag
by 0.7–1 s. Production had about 25 connected players at the time.
