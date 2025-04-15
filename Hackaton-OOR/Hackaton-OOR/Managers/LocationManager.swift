import Foundation
import CoreLocation

/// A manager for handling location updates and managing location-related permissions.
final class LocationManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    
    /// Indicates whether GPS is available.
    @Published var gpsAvailable: Bool = false
    
    /// The last known location coordinates.
    @Published var lastKnownLocation: CLLocationCoordinate2D?
    
    /// The accuracy of the last known location.
    @Published var lastAccuracy: CLLocationAccuracy?
    
    /// The heading direction of the last known location.
    @Published var lastHeading: CLLocationDirection?
    
    /// The timestamp of the last known location.
    @Published var lastTimestamp: TimeInterval?
    
    /// The underlying `CLLocationManager` instance.
    private var locationManager = CLLocationManager()
    
    /// Initializes the `LocationManager` and starts location updates.
    override init() {
        super.init()
        locationManager.delegate = self
        checkLocationAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = CLActivityType.otherNavigation
        locationManager.startUpdatingLocation()
    }
    
    /// Updates the published properties with the latest location data.
    /// - Parameter location: The latest location data.
    func update(_ location: CLLocation?) {
        DispatchQueue.main.async {
            self.lastKnownLocation = location?.coordinate
            self.lastAccuracy = location?.horizontalAccuracy
            self.lastHeading = location?.course
            self.lastTimestamp = location?.timestamp.timeIntervalSince1970
            self.gpsAvailable = true
        }
    }
    
    /// Checks the current location authorization status and requests permission if needed.
    func checkLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // The user has not yet chosen to allow or deny location access.
            locationManager.requestWhenInUseAuthorization()
            
        case .restricted:
            // The user cannot change this app’s status due to restrictions (e.g., parental controls).
            print("Location restricted")
            
        case .denied:
            // The user denied location access or location services are disabled.
            print("Location denied")
            
        case .authorizedAlways:
            // The app is authorized to use location services at all times.
            print("Location authorizedAlways")
            
        case .authorizedWhenInUse:
            // The app is authorized to use location services only when in use.
            print("Location authorized when in use")

        @unknown default:
            // Handle any future cases.
            print("Location service disabled")
        }
    }
    
    /// Called when the location manager updates the location.
    /// - Parameters:
    ///   - manager: The location manager instance.
    ///   - locations: An array of updated locations.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let latestLocation = locations.last {
            update(latestLocation)
        }
    }
    
    /// Called when the authorization status changes.
    /// Updates `gpsAvailable` based on the new status.
    /// - Parameters:
    ///   - manager: The location manager instance.
    ///   - status: The new authorization status.
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        checkLocationAuthorization()
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            DispatchQueue.main.async {
                self.gpsAvailable = true
            }
        } else {
            DispatchQueue.main.async {
                self.gpsAvailable = false
            }
        }
    }
    
    /// Called when the location manager fails to retrieve a location.
    /// - Parameters:
    ///   - manager: The location manager instance.
    ///   - error: The error that occurred.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.gpsAvailable = false
            self.lastAccuracy = nil
        }
    }
}
