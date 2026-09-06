import SwiftUI
import MapKit

/// The live match map: player/decoy blips, and the fixed outer play-area boundary and (if
/// enabled) the jail polygon. Built on `MKMapView` (like `BoundaryMapView`) rather than
/// SwiftUI's older `Map` API, which on our iOS 16.2 target has no polygon-overlay support.
struct GameMapView: UIViewRepresentable {
    struct Blip: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let kind: PlayerRole
        /// Shown as a small label under the pin — nil for your own blip (no need to label
        /// yourself) and always set for everyone else's.
        var username: String? = nil
    }

    let players: [Blip]
    /// The fixed outer play-area boundary — leaving it triggers the containment warning and
    /// heart drain (see checkContainment server-side). Unlike the shrinking zone below, this
    /// polygon never changes during a match, so it's only ever added once.
    var boundsPolygon: [Coordinate] = []
    /// Jail area, only present when the host enabled jail mode at setup.
    var jailPolygon: [Coordinate]? = nil
    /// The shrinking zone's current circle. Unlike the polygons this contracts continuously,
    /// so its overlay is replaced whenever the radius meaningfully changes.
    var zone: ZoneUpdate? = nil
    /// Live safe-zone flares — a runner standing inside one can't be caught.
    var safeZones: [ActiveSafeZone] = []
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
        var usernames: [String: String] = [:]
        for player in players {
            let key = "player:\(player.id)"
            desired[key] = (player.coordinate, .player(player.kind))
            if let username = player.username { usernames[key] = username }
        }
        for decoy in decoys where decoy.isDecoy {
            desired["decoy:\(decoy.id)"] = (CLLocationCoordinate2D(latitude: decoy.lat, longitude: decoy.lng), .decoy)
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
                    replacement.username = usernames[id]
                    toAdd.append(replacement)
                } else {
                    annotation.coordinate = coordinate
                }
            } else {
                let annotation = BlipAnnotation()
                annotation.blipId = id
                annotation.coordinate = coordinate
                annotation.kind = kind
                annotation.username = usernames[id]
                toAdd.append(annotation)
            }
        }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }

        // Both polygons come from immutable GameSettings — set once at game creation and
        // never touched again during a match — so unlike the shrinking zone circle below,
        // there's no per-tick reshaping to diff; just add them once.
        if !context.coordinator.polygonsAdded {
            context.coordinator.polygonsAdded = true
            if boundsPolygon.count >= 3 {
                let boundary = TaggedPolygon(
                    coordinates: boundsPolygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
                    count: boundsPolygon.count
                )
                boundary.kind = .boundary
                mapView.addOverlay(boundary)
            }
            if let jailPolygon, jailPolygon.count >= 3 {
                let jail = TaggedPolygon(
                    coordinates: jailPolygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
                    count: jailPolygon.count
                )
                jail.kind = .jail
                mapView.addOverlay(jail)
            }
        }

        // The zone circle is the one overlay that genuinely changes shape during a match, so
        // it's diffed on radius/center rather than added once — but only redrawn past a 1m
        // threshold, since it contracts continuously and MapKit would otherwise be handed a
        // brand-new overlay on every single push.
        if let zone {
            let previous = context.coordinator.zoneOverlay
            let moved = previous.map { existing in
                abs(existing.radius - zone.radiusMeters) > 1
                    || abs(existing.coordinate.latitude - zone.center.lat) > 0.000_01
                    || abs(existing.coordinate.longitude - zone.center.lng) > 0.000_01
            } ?? true
            if moved {
                if let previous { mapView.removeOverlay(previous) }
                let circle = TaggedCircle(
                    center: CLLocationCoordinate2D(latitude: zone.center.lat, longitude: zone.center.lng),
                    radius: zone.radiusMeters
                )
                circle.kind = .zone
                context.coordinator.zoneOverlay = circle
                mapView.addOverlay(circle)
            }
        }

        // Flares come and go, so the whole set is replaced whenever it changes rather than
        // tracked individually — there are only ever a handful live at once.
        let safeZoneKeys = safeZones.map { "\($0.lat),\($0.lng),\($0.radiusMeters)" }.sorted()
        if safeZoneKeys != context.coordinator.safeZoneKeys {
            context.coordinator.safeZoneKeys = safeZoneKeys
            mapView.removeOverlays(context.coordinator.safeZoneOverlays)
            let circles = safeZones.map { zone -> TaggedCircle in
                let circle = TaggedCircle(
                    center: CLLocationCoordinate2D(latitude: zone.lat, longitude: zone.lng),
                    radius: zone.radiusMeters
                )
                circle.kind = .safeZone
                return circle
            }
            context.coordinator.safeZoneOverlays = circles
            mapView.addOverlays(circles)
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
        var polygonsAdded = false
        var zoneOverlay: TaggedCircle?
        var safeZoneOverlays: [TaggedCircle] = []
        var safeZoneKeys: [String] = []
        var onSelectSpawn: ((String) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? TaggedCircle {
                let renderer = MKCircleRenderer(circle: circle)
                switch circle.kind {
                case .zone:
                    renderer.strokeColor = UIColor(ADATheme.spatialCyan)
                    renderer.fillColor = UIColor(ADATheme.spatialCyan).withAlphaComponent(0.06)
                    renderer.lineWidth = 2
                case .safeZone:
                    renderer.strokeColor = UIColor(ADATheme.runnerGreen)
                    renderer.fillColor = UIColor(ADATheme.runnerGreen).withAlphaComponent(0.18)
                    renderer.lineWidth = 2
                }
                return renderer
            }

            guard let polygon = overlay as? TaggedPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon)
            switch polygon.kind {
            case .boundary:
                renderer.strokeColor = UIColor(ADATheme.tacticalAmber)
                renderer.fillColor = UIColor(ADATheme.tacticalAmber).withAlphaComponent(0.05)
            case .jail:
                renderer.strokeColor = UIColor(ADATheme.stealthPurple)
                renderer.fillColor = UIColor(ADATheme.stealthPurple).withAlphaComponent(0.12)
            }
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
            // MKMarkerAnnotationView's default collision behavior (.circle) hides pins
            // that overlap at the current zoom level — that's the "pins vanish zoomed out,
            // pop back in zoomed in" bug. Every blip here is meaningful game state (a
            // player, a decoy, a power-up), never decorative, so nothing should ever be
            // silently dropped for visual tidiness.
            view.collisionMode = .none
            view.displayPriority = .required
            switch blip.kind {
            case .player(let role):
                view.markerTintColor = UIColor(ADATheme.accent(for: role))
                view.glyphImage = UIImage(systemName: role == .hunter ? "figure.run" : "figure.walk")
                view.canShowCallout = false
                Self.applyNameLabel(blip.username, to: view)
            case .decoy:
                view.markerTintColor = UIColor(ADATheme.spatialCyan)
                view.glyphImage = UIImage(systemName: "person.fill.questionmark")
                view.canShowCallout = false
                Self.applyNameLabel(nil, to: view)
            case .powerUpSpawn(_, let type):
                view.markerTintColor = UIColor(ADATheme.accent(for: type))
                view.glyphImage = UIImage(systemName: type.iconName)
                view.canShowCallout = true
                view.detailCalloutAccessoryView = nil
                Self.applyNameLabel(nil, to: view)
            }
            return view
        }

        /// A small always-visible name pill under the marker — unlike a callout, it doesn't
        /// need a tap to show. Same reused `MKMarkerAnnotationView` the pin already is, so
        /// this only ever adds/updates/removes one tagged subview rather than changing the
        /// marker itself.
        private static let nameLabelTag = 9001

        private static func applyNameLabel(_ username: String?, to view: MKMarkerAnnotationView) {
            view.subviews.filter { $0.tag == nameLabelTag }.forEach { $0.removeFromSuperview() }
            guard let username, !username.isEmpty else { return }

            let label = UILabel()
            label.tag = nameLabelTag
            label.text = username.uppercased()
            label.font = .systemFont(ofSize: 10, weight: .bold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.textAlignment = .center
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.sizeToFit()
            label.frame = label.frame.insetBy(dx: -6, dy: -3)

            // Fixed offset rather than derived from `view.bounds`: at this point in
            // `viewFor annotation`, before MapKit has added the view to its hierarchy and
            // run layout, a freshly-created marker's bounds can still read as zero — a
            // constant matching the standard marker balloon's own size is more reliable
            // than a fraction of a size that might not be resolved yet.
            label.center = CGPoint(x: 15, y: 42)
            view.addSubview(label)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let blip = view.annotation as? BlipAnnotation, case .powerUpSpawn(let spawnId, _) = blip.kind else { return }
            onSelectSpawn?(spawnId)
            mapView.deselectAnnotation(view.annotation, animated: true)
        }
    }
}

/// A boundary/jail overlay tagged with which one it is, so the renderer can color them
/// distinctly (boundary in the same amber the old shrinking zone used, jail in a purple
/// otherwise unused on this map).
private final class TaggedPolygon: MKPolygon {
    enum Kind { case boundary, jail }
    var kind: Kind = .boundary
}

/// The two circular overlays — the contracting play zone and any live safe-zone flares —
/// tagged the same way the polygons are so one renderer can color both.
final class TaggedCircle: MKCircle {
    enum Kind { case zone, safeZone }
    var kind: Kind = .zone
}

private final class BlipAnnotation: NSObject, MKAnnotation {
    enum Kind: Equatable {
        case player(PlayerRole)
        case decoy
        case powerUpSpawn(String, PowerUpType)
    }

    var blipId: String = ""
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var kind: Kind = .decoy
    var username: String?
    var title: String? { if case .powerUpSpawn(_, let type) = kind { return type.displayName } else { return nil } }
}
