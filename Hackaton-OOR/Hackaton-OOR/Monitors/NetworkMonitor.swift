import CoreLocation
import Network

/// A monitor for tracking the availability of an internet connection.
class NetworkMonitor: ObservableObject {
    /// The `NWPathMonitor` instance used to monitor network changes.
    private let monitor = NWPathMonitor()
    
    /// The dispatch queue on which the network monitor operates.
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    /// Indicates whether the internet is currently available.
    @Published var internetAvailable: Bool = false
    
    /// Initializes the `NetworkMonitor` and starts monitoring network changes.
    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.internetAvailable = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }
    
    /// Stops the network monitor when the instance is deallocated.
    deinit {
        monitor.cancel()
    }
}
