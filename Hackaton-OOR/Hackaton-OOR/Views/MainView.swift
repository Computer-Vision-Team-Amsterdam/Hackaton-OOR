import SwiftUI
import CoreLocation
import Network
import AVFoundation

func getAvailableDiskSpace() -> Int {
    let fileURL = URL(fileURLWithPath: NSHomeDirectory())
    do {
        let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage {
            // Convert bytes to GB
            return Int(available / (1024 * 1024 * 1024))
        }
    } catch {
        print("Error retrieving available disk space: \(error)")
    }
    return 0
}

/// A struct to create a UI row entry with a label and a value.
struct infoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .gray

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(valueColor)
        }
    }
}

/// A struct for the status information column that is shown in portrait and landscape.
struct StatusRows: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var networkMonitor: NetworkMonitor
    let storageAvailable: Int
    let detectContainers: Bool
    let detectMobileToilets: Bool
    let detectScaffoldings: Bool

    var body: some View {
        Group {
            infoRow(label: "GPS",
                    value: locationManager.isReceivingLocationUpdates ? "ON" : "OFF",
                    valueColor: locationManager.isReceivingLocationUpdates ? .green : .red)
            Divider()
            
            infoRow(label: "GPS accuracy (m)",
                    value: locationManager.lastAccuracy.map { String(format: "%.2f", $0) } ?? "N/A",
                    valueColor: locationManager.lastAccuracy != nil ? .green : .red)
            Divider()
            
            infoRow(label: "Internet connection",
                    value: networkMonitor.internetAvailable ? "ON" : "OFF",
                    valueColor: networkMonitor.internetAvailable ? .green : .red)
            Divider()
            
            infoRow(label: "Storage available",
                    value: "\(storageAvailable) GB",
                    valueColor: .green)
            Divider()
            
            HStack {
                Text("Detect:")
                Spacer()
                Group {
                    detectLabel(text: "containers", enabled: detectContainers)
                    Text(",")
                    detectLabel(text: "mobile toilets", enabled: detectMobileToilets)
                    Text(",")
                    detectLabel(text: "scaffoldings", enabled: detectScaffoldings)
                  }
            }
        }
    }
    /// Renders one of the object labels in green/red.
    private func detectLabel(text: String, enabled: Bool) -> some View {
        Text(text)
            .foregroundColor(enabled ? .green : .red)
    }
}

/// A struct for the detection-related information column that is shown in portrait and landscape mode.
struct DetectionStatsRows: View {
    @ObservedObject var detectionManager: DetectionManager
    let formattedTime: String

    var body: some View {
        Group {
            infoRow(label: "Recorded hours",
                    value: formattedTime)
            Divider()

            infoRow(label: "Total images",
                    value: "\(detectionManager.totalImages)")
            Divider()

            infoRow(label: "Objects detected",
                    value: "\(detectionManager.objectsDetected)")
            Divider()

            infoRow(label: "Images delivered",
                    value: "\(detectionManager.imagesDelivered)")
            Divider()

            HStack {
                Text("Delivery progress")
                Spacer()
                ProgressView(value: Double(detectionManager.imagesDelivered),
                             total: Double(max(detectionManager.totalImages, 1)))
                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                    .frame(width: 100)
            }
        }
    }
}

struct MainView: View {
    @AppStorage("detectContainers") private var detectContainers: Bool = true
    @AppStorage("detectMobileToilets") private var detectMobileToilets: Bool = true
    @AppStorage("detectScaffoldings") private var detectScaffoldings: Bool = true
    
    @EnvironmentObject var iotManager: IoTDeviceManager
    @StateObject private var locationManager = LocationManager()
    @StateObject private var networkMonitor = NetworkMonitor()
    @ObservedObject private var detectionManager = DetectionManager.shared
    
    @State private var storageAvailable: Int = 0
    
    // States for bottom section (static/recording info)
    @State private var recordedHours: String = "0:00"
    @State private var totalImages: Int = 0
    
    // Detection-related states
    @State private var isDetecting: Bool = false
    @State private var showingStopConfirmation = false
    @State private var showCameraView: Bool = false
    @State private var isCameraAuthorized: Bool = false
    @State private var showCameraAccessDeniedAlert: Bool = false
    
    private var isLocationAuthorized: Bool {
        // Accesses the authorizationStatus published by the locationManager instance
        locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways
    }
    
    private var enabledObjects: String {
        let objects = [
            detectContainers ? "containers" : nil,
            detectMobileToilets ? "mobile toilets" : nil,
            detectScaffoldings ? "scaffoldings" : nil
        ].compactMap { $0 }
        return objects.isEmpty ? "none" : objects.joined(separator: ", ")
    }

    private var areAnyObjectsEnabled: Bool {
        detectContainers || detectMobileToilets || detectScaffoldings
    }
    
    // Timer to check storage periodically
    let storageTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    // Timer to attempt uploading stored files periodically (e.g., every 5 minutes)
    let deliverToAzureTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    
    var formattedTime: String {
        let totalSeconds = detectionManager.minutesRunning * 60
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: TimeInterval(totalSeconds)) ?? "00:00"
    }
    
    /// UI main body.
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width <= geometry.size.height {
                portraitLayout
            } else {
                landscapeLayout
            }
        }
        .onAppear {
            storageAvailable = getAvailableDiskSpace()
            detectionManager.deliverFilesFromDocuments()
            CameraManager.checkAndRequestCameraAccess { authorized in
                isCameraAuthorized = authorized
            }
            if !isLocationAuthorized {
                locationManager.requestAuthorization()
            }
        }
        .onReceive(storageTimer) { _ in
            storageAvailable = getAvailableDiskSpace()
        }
        .onReceive(deliverToAzureTimer) { _ in
            if !isDetecting {
                detectionManager.deliverFilesFromDocuments()
            }
        }
        .alert("Credential Error", isPresented: $iotManager.showingCredentialAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(iotManager.credentialAlertMessage)
        }
        .fullScreenCover(isPresented: $showCameraView) {
            CameraViewContainer(isCameraPresented: $showCameraView)
        }
        .alert(isPresented: $showCameraAccessDeniedAlert) {
            CameraManager.showCameraAccessDeniedAlert()
        }
    }
    
    /// UI portrait mode layout.
    private var portraitLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            detectingBanner
            cameraPreviewRow
            Divider()
            StatusRows(locationManager: locationManager,
                       networkMonitor: networkMonitor,
                       storageAvailable: storageAvailable,
                       detectContainers: detectContainers,
                       detectMobileToilets: detectMobileToilets,
                       detectScaffoldings: detectScaffoldings)
            Spacer()
            DetectionStatsRows(detectionManager: detectionManager,
                                formattedTime: formattedTime)
            Divider()
            detectionButtons
        }
        .padding()
    }
    
    /// UI landscape mode layout.
    private var landscapeLayout: some View {
        HStack(spacing: 20) {
            // Left column
            VStack(alignment: .leading, spacing: 16) {
                cameraPreviewRow
                Divider()
                StatusRows(locationManager: locationManager,
                           networkMonitor: networkMonitor,
                           storageAvailable: storageAvailable,
                           detectContainers: detectContainers,
                           detectMobileToilets: detectMobileToilets,
                           detectScaffoldings: detectScaffoldings)
                stopButton
            }
            .padding()

            // Right column
            VStack(alignment: .leading, spacing: 16) {
                DetectionStatsRows(detectionManager: detectionManager,
                                    formattedTime: formattedTime)
                Divider()
                infoRow(label: " ", value: " ") // spacer row for alignment
                detectButton
            }
        }
        .padding()
    }
    
    /// Top screen banner that appears in portrait mode when detecting.
    private var detectingBanner: some View {
        ZStack {
            Color.clear.frame(height: 30)
            if isDetecting {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                            .scaleEffect(1.5)
                        Text("Detecting…")
                            .font(.title3).bold().foregroundColor(.blue)
                    }
                    Spacer()
                }
            }
        }
    }
    
    /// Row for camera preview button.
    private var cameraPreviewRow: some View {
        HStack {
            Text("Camera Preview")
            Spacer()
            Button(action: authorizeAndShowCameraPreview) {
                Image(systemName: "camera.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(isDetecting ? .gray : .blue)
            }
            .disabled(isDetecting)
        }
    }
    
    /// Button to stop detecting.
    private var stopButton: some View {
        Button("Stop") { showingStopConfirmation = true }
            .buttonStyle(StopButtonStyle())
            .disabled(!isDetecting)
            .alert("Confirm Stop", isPresented: $showingStopConfirmation) {
                Button("Stop", role: .destructive) { stopDetection() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to stop? This will interrupt detection.")
            }
    }
    
    /// Button to start detecting.
    private var detectButton: some View {
        Button(action: startDetectionIfPossible) {
            if isDetecting {
                HStack(spacing: 8) {
                    Text("Detecting")
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            } else {
                Text("Detect")
            }
        }
        .buttonStyle(DetectButtonStyle())
        .disabled(isDetecting || !locationManager.isReceivingLocationUpdates || !areAnyObjectsEnabled)
    }
    
    /// Variable to align stop and start detection buttons next to eachother in portrait mode.
    private var detectionButtons: some View {
        HStack(spacing: 20) {
            stopButton
            detectButton
        }
        .frame(maxWidth: .infinity)
    }
    
    /// Function to check and request camera access when camera preview is tapped.
    private func authorizeAndShowCameraPreview() {
        CameraManager.checkAndRequestCameraAccess { authorized in
            isCameraAuthorized = authorized
            if authorized {
                showCameraView = true
            } else {
                showCameraAccessDeniedAlert = true
            }
        }
    }
    
    /// Function to start detection if camera is accessible, and otherwise asks for access.
    private func startDetectionIfPossible() {
        guard !isDetecting else { return }
        CameraManager.checkAndRequestCameraAccess { authorized in
            isCameraAuthorized = authorized
            if authorized {
                DispatchQueue.main.async {
                    isDetecting = true
                    detectionManager.startDetection()
                }
            } else {
                showCameraAccessDeniedAlert = true
            }
        }
    }
    
    /// Function to stop the detection.
    private func stopDetection() {
        isDetecting = false
        detectionManager.stopDetection()
    }
    
}

/// Detect button style.
struct DetectButtonStyle : ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity)
            .background(isEnabled
                        ? (configuration.isPressed ? Color.green.opacity(0.7) : Color.green.opacity(0.9))
                        : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
    }
}

/// Stop button style.
struct StopButtonStyle : ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .frame(maxWidth: .infinity)
            .background(isEnabled
                        ? (configuration.isPressed ? Color.red.opacity(0.7) : Color.red.opacity(0.9))
                        : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(10)
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
