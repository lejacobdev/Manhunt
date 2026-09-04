import SwiftUI
import MapKit

/// The live match map: player/decoy blips, the shrinking Standard-mode safe
/// zone (an `MKCircle` overlay), and the extraction point marker. Built on
/// `MKMapView` (like `BoundaryMapView`) rather than SwiftUI's older `Map`
/// API, which on our iOS 16.2 target has no circle-overlay support.
struct GameMapView: UIViewRepresentable {
    struct Blip: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let kind: PlayerRole
    }

    let players: [Blip]
    let zone: ZoneUpdate?
    let extractionPoint: Coordinate?
    let decoys: [DecoyBlip]
    var powerUpSpawns: [PowerUpSpawn] = []
    /// Fires with the tapped spawn's id when its map pin is selected.
    var onSelectSpawn: ((String) -> Void)? = nil
    /// The real point to center on once known — nil until it's available (e.g. before the
    /// first GPS fix, or before replay data has loaded). Passing an already-defaulted
    /// fallback here instead of nil would defeat `hasCentered`: the one-shot recenter below
    /// would latch onto that fallback on the very first pass and never fire again once the
    /// real value showed up.
    var initialCenter: CLLocationCoordinate2D?
    /// Spectator "follow" — when set to a player id present in `players`,
    /// the map re-centers on that player once (not continuously; the viewer can still
    /// pan freely afterward). Changing it to a different id re-centers again.
    var focusPlayerId: String? = nil
    /// "Recenter on me" (Google Maps-style): bump this counter to re-center on
    /// `recenterTargetId` even if that id hasn't changed since the last request — unlike
    /// `focusPlayerId`, which only fires on an id *change*, this fires on every tap.
    var recenterRequest: Int = 0
    var recenterTargetId: String? = nil

    /// Used only for the very first camera position, before `initialCenter` is known.
    private static let defaultFallbackCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.setRegion(MKCoordinateRegion(center: initialCenter ?? Self.defaultFallbackCenter, latitudinalMeters: 600, longitudinalMeters: 600), animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if !context.coordinator.hasCentered, let initialCenter {
            mapView.setRegion(MKCoordinateRegion(center: initialCenter, latitudinalMeters: 600, longitudinalMeters: 600), animated: true)
            context.coordinator.hasCentered = true
        }

        // This view re-renders on every GPS fix and HUD timer tick, so blindly
        // remove-all/add-all every pass would replay the marker drop animation
        // and flicker constantly. Instead diff by stable id: move existing pins
        // in place (their @objc dynamic coordinate is KVO-observed by MapKit),
        // and only actually add/remove annotations that entered or left.
        var desired: [String: (CLLocationCoordinate2D, BlipAnnotation.Kind)] = [:]
        for player in players {
            desired["player:\(player.id)"] = (player.coordinate, .player(player.kind))
        }
        for decoy in decoys where decoy.isDecoy {
            desired["decoy:\(decoy.id)"] = (CLLocationCoordinate2D(latitude: decoy.lat, longitude: decoy.lng), .decoy)
        }
        if let extractionPoint {
            desired["extraction"] = (CLLocationCoordinate2D(latitude: extractionPoint.lat, longitude: extractionPoint.lng), .extraction)
        }
        for spawn in powerUpSpawns {
            desired["spawn:\(spawn.id)"] = (CLLocationCoordinate2D(latitude: spawn.latitude, longitude: spawn.longitude), .powerUpSpawn(spawn.id, spawn.type))
        }

        let existing = mapView.annotations.compactMap { $0 as? BlipAnnotation }
        var existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.blipId, $0) })

        let staleIds = Set(existingById.keys).subtracting(desired.keys)
        if !staleIds.isEmpty {
            mapView.removeAnnotations(staleIds.compactMap { existingById[$0] })
            staleIds.forEach { existingById.removeValue(forKey: $0) }
        }

        var toAdd: [BlipAnnotation] = []
        for (id, value) in desired {
            let (coordinate, kind) = value
            if let annotation = existingById[id] {
                if annotation.kind != kind {
                    // Kind changes (e.g. Infection converting a runner into a
                    // hunter) need a fresh MKMarkerAnnotationView — an in-place
                    // mutation wouldn't trigger `viewFor annotation` again since
                    // MapKit already has a cached view for this identity.
                    mapView.removeAnnotation(annotation)
                    let replacement = BlipAnnotation()
                    replacement.blipId = id
                    replacement.coordinate = coordinate
                    replacement.kind = kind
                    toAdd.append(replacement)
                } else {
                    annotation.coordinate = coordinate
                }
            } else {
                let annotation = BlipAnnotation()
                annotation.blipId = id
                annotation.coordinate = coordinate
                annotation.kind = kind
                toAdd.append(annotation)
            }
        }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }

        if let zone {
            let existingCircle = mapView.overlays.first as? MKCircle
            if existingCircle == nil || existingCircle!.coordinate.latitude != zone.center.lat
                || existingCircle!.coordinate.longitude != zone.center.lng || existingCircle!.radius != zone.radiusMeters {
                mapView.removeOverlays(mapView.overlays)
                let circle = MKCircle(
                    center: CLLocationCoordinate2D(latitude: zone.center.lat, longitude: zone.center.lng),
                    radius: zone.radiusMeters
                )
                mapView.addOverlay(circle)
            }
        } else if !mapView.overlays.isEmpty {
            mapView.removeOverlays(mapView.overlays)
        }

        if let focusPlayerId, focusPlayerId != context.coordinator.lastFocusedId,
           let target = players.first(where: { $0.id == focusPlayerId }) {
            mapView.setRegion(MKCoordinateRegion(center: target.coordinate, latitudinalMeters: 400, longitudinalMeters: 400), animated: true)
            context.coordinator.lastFocusedId = focusPlayerId
        } else if focusPlayerId == nil {
            context.coordinator.lastFocusedId = nil
        }

        // "Recenter on me": distinct from the focus mechanism above because it must fire
        // on every tap, not just when the target id changes — tapping the button twice in a
        // row with nothing else changing should still snap the camera back both times.
        if recenterRequest != context.coordinator.lastRecenterRequest {
            context.coordinator.lastRecenterRequest = recenterRequest
            if let recenterTargetId, let target = players.first(where: { $0.id == recenterTargetId }) {
                mapView.setRegion(MKCoordinateRegion(center: target.coordinate, latitudinalMeters: 400, longitudinalMeters: 400), animated: true)
            }
        }

        context.coordinator.onSelectSpawn = onSelectSpawn
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasCentered = false
        var lastFocusedId: String?
        var lastRecenterRequest = 0
        var onSelectSpawn: ((String) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = UIColor(ADATheme.tacticalAmber)
            renderer.fillColor = UIColor(ADATheme.tacticalAmber).withAlphaComponent(0.08)
            renderer.lineWidth = 2
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let blip = annotation as? BlipAnnotation else { return nil }
            let identifier = "blip"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.animatesWhenAdded = true
            switch blip.kind {
            case .player(let role):
                view.markerTintColor = UIColor(ADATheme.accent(for: role))
                view.glyphImage = UIImage(systemName: role == .hunter ? "figure.run" : "figure.walk")
                view.canShowCallout = false
            case .decoy:
                view.markerTintColor = UIColor(ADATheme.spatialCyan)
                view.glyphImage = UIImage(systemName: "person.fill.questionmark")
                view.canShowCallout = false
            case .extraction:
                view.markerTintColor = UIColor(ADATheme.runnerGreen)
                view.glyphImage = UIImage(systemName: "flag.checkered")
                view.canShowCallout = false
            case .powerUpSpawn(_, let type):
                view.markerTintColor = UIColor(ADATheme.accent(for: type))
                view.glyphImage = UIImage(systemName: type.iconName)
                view.canShowCallout = true
                view.detailCalloutAccessoryView = nil
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let blip = view.annotation as? BlipAnnotation, case .powerUpSpawn(let spawnId, _) = blip.kind else { return }
            onSelectSpawn?(spawnId)
            mapView.deselectAnnotation(view.annotation, animated: true)
        }
    }
}

private final class BlipAnnotation: NSObject, MKAnnotation {
    enum Kind: Equatable {
        case player(PlayerRole)
        case decoy
        case extraction
        case powerUpSpawn(String, PowerUpType)
    }

    var blipId: String = ""
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var kind: Kind = .decoy
    var title: String? { if case .powerUpSpawn(_, let type) = kind { return type.displayName } else { return nil } }
}
