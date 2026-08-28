import ActivityKit
import Foundation

/// Compiled into both the HuntingGame app target and the HuntingGameWidgets
/// extension target (see project.yml) so both sides agree on the Live
/// Activity's shape without a shared framework.
public struct HuntingGameAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var distanceMeters: Int
        public var nearestHunterBearing: Double
        public var isRadarActive: Bool
        public var dangerLevel: String // "SAFE", "WARNING", "CRITICAL"

        public init(distanceMeters: Int, nearestHunterBearing: Double, isRadarActive: Bool, dangerLevel: String) {
            self.distanceMeters = distanceMeters
            self.nearestHunterBearing = nearestHunterBearing
            self.isRadarActive = isRadarActive
            self.dangerLevel = dangerLevel
        }
    }

    public var gameCode: String
    public var userRole: String

    public init(gameCode: String, userRole: String) {
        self.gameCode = gameCode
        self.userRole = userRole
    }
}
