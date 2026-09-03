import SwiftUI
import MapKit

/// Lets the host tap out the play-area polygon directly on the map.
/// Wrapped in UIViewRepresentable (rather than SwiftUI's Map) so it works
/// back to iOS 16 and gives precise tap-to-coordinate conversion.
struct BoundaryMapView: UIViewRepresentable {
    @Binding var points: [Coordinate]
    var centerCoordinate: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(MKCoordinateRegion(center: centerCoordinate, latitudinalMeters: 800, longitudinalMeters: 800), animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        for (index, point) in points.enumerated() {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
            annotation.title = "\(index + 1)"
            mapView.addAnnotation(annotation)
        }

        if points.count >= 2 {
            var coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            if points.count >= 3 { coords.append(coords[0]) }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(polyline)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: BoundaryMapView

        init(_ parent: BoundaryMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.points.append(Coordinate(lat: coordinate.latitude, lng: coordinate.longitude))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemGreen
            renderer.lineWidth = 3
            return renderer
        }
    }
}
