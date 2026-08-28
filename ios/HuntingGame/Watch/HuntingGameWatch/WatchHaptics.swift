import WatchKit

/// watchOS has no CoreHaptics — haptic feedback goes through
/// `WKInterfaceDevice.play(_:)` and its fixed system haptic types instead.
enum WatchHaptics {
    static func proximityAlert() {
        WKInterfaceDevice.current().play(.directionUp)
    }

    static func caught() {
        WKInterfaceDevice.current().play(.failure)
    }

    static func catchConfirmed() {
        WKInterfaceDevice.current().play(.success)
    }

    static func powerUpActivated() {
        WKInterfaceDevice.current().play(.click)
    }

    static func lightTap() {
        WKInterfaceDevice.current().play(.click)
    }
}
