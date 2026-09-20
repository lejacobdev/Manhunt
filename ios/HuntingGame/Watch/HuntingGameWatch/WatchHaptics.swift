import WatchKit

/// watchOS has no CoreHaptics — haptic feedback goes through
/// `WKInterfaceDevice.play(_:)` and its fixed system haptic types instead. Each moment in a match
/// gets its own pattern, so the wrist alone says what happened.
enum WatchHaptics {
    /// A hunter is close (runner side).
    static func proximityAlert() {
        WKInterfaceDevice.current().play(.directionUp)
    }

    /// A hunter is right on top of you — a firmer pattern than the ordinary proximity tick.
    static func dangerClose() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// A runner is within catch range (hunter side).
    static func inRange() {
        WKInterfaceDevice.current().play(.click)
    }

    /// Someone says they caught you and wants an answer.
    static func catchRequest() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// You lost a heart, whatever took it.
    static func heartLost() {
        WKInterfaceDevice.current().play(.failure)
    }

    static func caught() {
        WKInterfaceDevice.current().play(.failure)
    }

    /// Outside the zone or play area, and it's costing hearts.
    static func warning() {
        WKInterfaceDevice.current().play(.retry)
    }

    static func catchConfirmed() {
        WKInterfaceDevice.current().play(.success)
    }

    static func powerUpActivated() {
        WKInterfaceDevice.current().play(.success)
    }

    /// An action couldn't be delivered.
    static func failure() {
        WKInterfaceDevice.current().play(.failure)
    }

    static func lightTap() {
        WKInterfaceDevice.current().play(.click)
    }
}
