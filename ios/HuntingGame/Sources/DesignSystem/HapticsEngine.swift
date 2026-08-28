import CoreHaptics
import UIKit

/// Central haptics coordinator. Simple, momentary feedback (button taps, catch
/// confirmation) goes through UIKit's feedback generators, which are cheap and
/// always available. The escalating proximity pulse — used when a runner's
/// nearest-hunter distance drops under the CRITICAL threshold — needs custom
/// intensity/sharpness curves, so it drives CoreHaptics directly.
final class HapticsEngine {
    static let shared = HapticsEngine()

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()

    private var lastProximityPulseAt: Date = .distantPast
    private let proximityPulseCooldown: TimeInterval = 1.2

    private init() {
        prepareEngine()
    }

    func prepareEngine() {
        guard supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine?.stoppedHandler = { [weak self] _ in
                self?.engine = nil
            }
            try engine?.start()
        } catch {
            print("[HapticsEngine] failed to start: \(error.localizedDescription)")
        }
    }

    // MARK: - Simple feedback

    func powerUpActivated() {
        impactRigid.prepare()
        impactRigid.impactOccurred(intensity: 1.0)
    }

    func powerUpCollected() {
        impactSoft.prepare()
        impactSoft.impactOccurred(intensity: 0.7)
    }

    func catchSucceeded() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    func catchFailed() {
        notification.prepare()
        notification.notificationOccurred(.error)
    }

    func lightTap() {
        impactSoft.prepare()
        impactSoft.impactOccurred(intensity: 0.5)
    }

    // MARK: - Proximity pulse

    /// Plays a single sharp/intense haptic scaled to how close the nearest
    /// hunter is. Throttled so a stream of location updates under 25m doesn't
    /// turn into a continuous buzz.
    func playProximityPulse(distanceMeters: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastProximityPulseAt) >= proximityPulseCooldown else { return }
        lastProximityPulseAt = now

        // Normalize: 25m -> low intensity, 0m -> maximum intensity/sharpness.
        let clamped = max(0, min(25, distanceMeters))
        let proximity = 1.0 - (Float(clamped) / 25.0)
        let intensity = 0.35 + proximity * 0.65
        let sharpness = 0.3 + proximity * 0.7

        guard supportsHaptics, let engine else {
            impactRigid.prepare()
            impactRigid.impactOccurred(intensity: CGFloat(intensity))
            return
        }

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            impactRigid.prepare()
            impactRigid.impactOccurred(intensity: CGFloat(intensity))
        }
    }
}
