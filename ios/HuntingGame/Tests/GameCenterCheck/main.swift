import Foundation

// A standalone check of the Game Center logic in Sources/Services/GameCenter/GameCenterCatalog.swift.
// Run by .github/workflows/watch-check.yml as:
//   swiftc Sources/Services/GameCenter/GameCenterCatalog.swift Tests/GameCenterCheck/main.swift -o gccheck
//   ./gccheck GameCenter/catalog.json
//
// Game Center is the kind of feature that fails silently: a wrong identifier or a progress value
// that goes backwards produces no error anywhere, it just never shows up. So the logic that decides
// what to report is proven here, and the identifiers are checked against the file that creates them.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("  ok    \(message)") } else { print("  FAIL  \(message)"); failures += 1 }
}

print("Percent complete")
check(GameCenterProgress.percent(progress: 0, goal: 10) == 0, "no progress is 0%")
check(GameCenterProgress.percent(progress: 5, goal: 10) == 50, "half way is 50%")
check(GameCenterProgress.percent(progress: 10, goal: 10) == 100, "reaching the goal is exactly 100%")
check(GameCenterProgress.percent(progress: 37, goal: 10) == 100, "exceeding the goal is clamped to 100%")
check(GameCenterProgress.percent(progress: 1, goal: 3) < 100, "one short of the goal is below 100%")
check(GameCenterProgress.percent(progress: 5, goal: 0) == 0, "a zero goal cannot divide by zero")
check(GameCenterProgress.percent(progress: -3, goal: 10) == 0, "negative progress is 0%")

print("Achievement updates")
let readings = [
    GCAchievementReading(key: "first_catch", progress: 1, goal: 1),
    GCAchievementReading(key: "catches_10", progress: 4, goal: 10),
    GCAchievementReading(key: "wins_10", progress: 0, goal: 10),
    GCAchievementReading(key: "not_in_the_catalogue", progress: 9, goal: 9),
]
let firstRun = GameCenterProgress.achievementUpdates(readings, lastReported: [:])
check(firstRun.count == 2, "first run reports the two with progress (\(firstRun.count))")
check(firstRun.contains(GCAchievementUpdate(id: "hg.achievement.first_catch", percent: 100)), "a completed achievement reports 100%")
check(firstRun.contains(GCAchievementUpdate(id: "hg.achievement.catches_10", percent: 40)), "a partial one reports its percentage")
check(!firstRun.contains { $0.id.contains("wins_10") }, "0% on an untouched achievement is not reported")
check(!firstRun.contains { $0.id.contains("not_in_the_catalogue") }, "an id the catalogue does not know is never sent to Game Center")

let cache = Dictionary(uniqueKeysWithValues: firstRun.map { ($0.id, $0.percent) })
check(GameCenterProgress.achievementUpdates(readings, lastReported: cache).isEmpty, "running again with nothing new reports nothing")

let moved = readings.map { $0.key == "catches_10" ? GCAchievementReading(key: "catches_10", progress: 7, goal: 10) : $0 }
let secondRun = GameCenterProgress.achievementUpdates(moved, lastReported: cache)
check(secondRun == [GCAchievementUpdate(id: "hg.achievement.catches_10", percent: 70)], "only the one that moved is reported")

let regressed = readings.map { $0.key == "catches_10" ? GCAchievementReading(key: "catches_10", progress: 2, goal: 10) : $0 }
check(GameCenterProgress.achievementUpdates(regressed, lastReported: cache).isEmpty, "progress never goes backwards")

print("Leaderboard scores")
let scores = [
    GCScoreReading(sort: "wins", score: 4),
    GCScoreReading(sort: "catches", score: 0),
    GCScoreReading(sort: "matches", score: 12),
    GCScoreReading(sort: "playtime", score: 95),
    GCScoreReading(sort: "unknown_board", score: 50),
]
let firstScores = GameCenterProgress.scoreUpdates(scores, lastSubmitted: [:])
check(firstScores.count == 3, "first run submits the three non-zero known boards (\(firstScores.count))")
check(firstScores.contains(GCScoreUpdate(leaderboardID: "hg.leaderboard.wins", score: 4)), "wins maps to its leaderboard")
check(!firstScores.contains { $0.leaderboardID.hasSuffix("catches") }, "a score of 0 is never submitted")
check(!firstScores.contains { $0.leaderboardID.contains("unknown") }, "an unknown board is ignored")

let scoreCache = Dictionary(uniqueKeysWithValues: firstScores.map { ($0.leaderboardID, $0.score) })
check(GameCenterProgress.scoreUpdates(scores, lastSubmitted: scoreCache).isEmpty, "unchanged scores are not resubmitted")
let better = scores.map { $0.sort == "wins" ? GCScoreReading(sort: "wins", score: 5) : $0 }
check(GameCenterProgress.scoreUpdates(better, lastSubmitted: scoreCache) == [GCScoreUpdate(leaderboardID: "hg.leaderboard.wins", score: 5)],
      "only a higher score is submitted")
let worse = scores.map { $0.sort == "wins" ? GCScoreReading(sort: "wins", score: 2) : $0 }
check(GameCenterProgress.scoreUpdates(worse, lastSubmitted: scoreCache).isEmpty, "a lower score is never submitted")

print("Catalogue matches GameCenter/catalog.json (what App Store Connect is created from)")
if CommandLine.arguments.count > 1,
   let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
   let prefixes = json["prefix"] as? [String: String],
   let boards = json["leaderboards"] as? [[String: Any]],
   let achievements = json["achievements"] as? [[String: Any]] {

    check(prefixes["leaderboard"] == GameCenterCatalog.leaderboardPrefix, "leaderboard prefix agrees")
    check(prefixes["achievement"] == GameCenterCatalog.achievementPrefix, "achievement prefix agrees")

    let jsonSorts = boards.compactMap { $0["sort"] as? String }
    check(jsonSorts == GameCenterCatalog.leaderboardSorts, "leaderboards agree, in order: \(jsonSorts)")

    let jsonKeys = achievements.compactMap { $0["key"] as? String }
    check(jsonKeys == GameCenterCatalog.achievementKeys, "all \(jsonKeys.count) achievements agree, in order")

    let points = achievements.compactMap { $0["points"] as? Int }
    check(points.allSatisfy { $0 >= 1 && $0 <= 100 }, "every achievement is worth 1-100 points (Game Center's limit)")
    check(points.reduce(0, +) <= 1000, "total points \(points.reduce(0, +)) is within Game Center's 1000")

    let names = (boards + achievements).compactMap { $0["name"] as? String }
    check(names.count == Set(names).count, "no two items share a display name")
    check(names.allSatisfy { $0.count <= 30 }, "every display name fits Game Center's 30 characters")
    check(achievements.allSatisfy { ($0["before"] as? String).map { $0.count <= 200 } ?? false }, "every description fits 200 characters")
} else {
    check(false, "GameCenter/catalog.json could not be read (pass its path as the first argument)")
}

print(failures == 0 ? "\nALL GAME CENTER CHECKS PASSED" : "\n\(failures) GAME CENTER CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
