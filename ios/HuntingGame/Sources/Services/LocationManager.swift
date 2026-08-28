import Foundation
import CoreLocation
import CoreMotion
import Combine

/// Wraps CoreLocation + CoreMotion to provide continuous, background-capable
/// positioning and heading for the live match, plus a foot-vs-vehicle signal
/// that feeds the client-side half of anti-cheat (the server independently
/// re-validates every fix, so this is a UX hint, not a trust boundary).
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()

    @Published var currentLocation: CLLocation?
    @Published var currentHeading: CLHeading?
    @Published var userSpeed: Double = 0.0
    @Published var isMovingOnFoot: Bool = true
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Fires on every accepted fix so callers (e.g. SocketService) can stream updates upstream.
    var onLocationUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorizationAndStart() {
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        startMotionTracking()
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        motionManager.stopActivityUpdates()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        // Reject fixes with unusably poor horizontal accuracy (GPS noise/indoor bounce).
        guard latest.horizontalAccuracy >= 0 && latest.horizontalAccuracy <= 30 else { return }
        currentLocation = latest
        userSpeed = max(0, latest.speed)
        onLocationUpdate?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        currentHeading = newHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] error: \(error.localizedDescription)")
    }

    private func startMotionTracking() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity = activity else { return }
            self?.isMovingOnFoot = activity.walking || activity.running || activity.stationary || (!activity.automotive && !activity.cycling)
        }
    }
}
