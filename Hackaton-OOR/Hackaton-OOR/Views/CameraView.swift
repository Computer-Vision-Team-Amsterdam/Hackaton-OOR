import SwiftUI
import UIKit
import AVFoundation

// MARK: - SwiftUI Container with Exit Button

struct CameraViewContainer: View {
    @AppStorage("debugView") var debugView: Bool = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            CameraView()
                .edgesIgnoringSafeArea(.all)
            
            Button(action: {
                // When the exit button is tapped, set debugView to false.
                debugView = false
            }) {
                // Customize your button appearance.
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.white)
                    .padding()
            }
        }
    }
}

// MARK: - UIViewControllerRepresentable for the Camera Preview

struct CameraView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CameraPreviewViewController {
        return CameraPreviewViewController()
    }
    
    func updateUIViewController(_ uiViewController: CameraPreviewViewController, context: Context) {
        // No dynamic updates needed.
    }
}

// MARK: - UIKit Camera Preview View Controller

class CameraPreviewViewController: UIViewController {
    // MARK: - Properties
    var captureSession: AVCaptureSession!
    var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // 1. Set up the capture session.
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        
        // 2. Get the default video device (typically the back camera).
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            print("No video device found")
            return
        }
        
        do {
            // 3. Create an input from the video device.
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            // 4. Add the input to the capture session.
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                print("Could not add video input to the session")
                return
            }
        } catch {
            print("Error setting up video input: \(error)")
            return
        }
        
        // 5. Set up the video preview layer.
        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(videoPreviewLayer)
        
        // 6. Start the capture session on a background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ensure the preview layer fills the view.
        videoPreviewLayer.frame = view.bounds
        updateVideoOrientation()
    }
    
    // Update the preview layer’s frame and orientation when the device rotates.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.videoPreviewLayer.frame = self.view.bounds
            self.updateVideoOrientation()
        }, completion: nil)
    }
    
    // Updates the video orientation to match the interface orientation.
    private func updateVideoOrientation() {
        guard let connection = videoPreviewLayer.connection,
              connection.isVideoOrientationSupported else {
            return
        }
        
        // Retrieve the current interface orientation.
        let interfaceOrientation: UIInterfaceOrientation
        if let windowScene = view.window?.windowScene {
            interfaceOrientation = windowScene.interfaceOrientation
        } else {
            interfaceOrientation = .portrait
        }
        
        // Map the interface orientation to the video orientation.
        switch interfaceOrientation {
        case .portrait:
            connection.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            connection.videoOrientation = .landscapeLeft
        case .landscapeRight:
            connection.videoOrientation = .landscapeRight
        default:
            connection.videoOrientation = .portrait
        }
    }
}
