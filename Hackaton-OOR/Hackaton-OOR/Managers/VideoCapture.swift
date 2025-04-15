//  Ultralytics YOLO 🚀 - AGPL-3.0 License
//
//  Video Capture for Ultralytics YOLOv8 Preview on iOS
//  Part of the Ultralytics YOLO app, this file defines the VideoCapture class to interface with the device's camera,
//  facilitating real-time video capture and frame processing for YOLOv8 model previews.
//  Licensed under AGPL-3.0. For commercial use, refer to Ultralytics licensing: https://ultralytics.com/license
//  Access the source code: https://github.com/ultralytics/yolo-ios-app
//
//  This class encapsulates camera initialization, session management, and frame capture delegate callbacks.
//  It dynamically selects the best available camera device, configures video input and output, and manages
//  the capture session. It also provides methods to start and stop video capture and delivers captured frames
//  to a delegate implementing the VideoCaptureDelegate protocol.

import AVFoundation
import CoreVideo
import UIKit

// Defines the protocol for handling video frame capture events.
public protocol VideoCaptureDelegate: AnyObject {
  func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame: CMSampleBuffer)
}

// Identifies the best available camera device based on user preferences and device capabilities.
func bestCaptureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice {
  if position == .back {
    // バックカメラの場合
    if UserDefaults.standard.bool(forKey: "use_telephoto"),
      let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
    {
      return device
    } else if let device = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
    {
      return device
    } else if let device = AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .back)
    {
      return device
    } else {
      fatalError("Expected back camera device is not available.")
    }
  } else if position == .front {
    // フロントカメラの場合
    if let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
    {
      return device
    } else if let device = AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .front)
    {
      return device
    } else {
      fatalError("Expected front camera device is not available.")
    }
  } else {
    fatalError("Unsupported camera position: \(position)")
  }
}

public class VideoCapture: NSObject {
  public var previewLayer: AVCaptureVideoPreviewLayer?
  public weak var delegate: VideoCaptureDelegate?
 
  #if targetEnvironment(simulator)
  // No real capture device in the simulator.
  lazy var captureDevice: AVCaptureDevice? = nil
  #else
  // On a real device, select the best available back camera.
  let captureDevice = bestCaptureDevice(for: .back)
  #endif
  let captureSession = AVCaptureSession()
  let videoOutput = AVCaptureVideoDataOutput()
  var cameraOutput = AVCapturePhotoOutput()
  let queue = DispatchQueue(label: "camera-queue")

  // Configures the camera and capture session with optional session presets.
  public func setUp(
    sessionPreset: AVCaptureSession.Preset = .hd1280x720, completion: @escaping (Bool) -> Void
  ) {
    #if targetEnvironment(simulator)
    print("Simulator mode: Bypassing camera hardware setup.")
    // Create a dummy preview layer using an empty session.
    let dummySession = AVCaptureSession()
    self.previewLayer = AVCaptureVideoPreviewLayer(session: dummySession)
    self.previewLayer?.videoGravity = .resizeAspectFill
    DispatchQueue.main.async {
        completion(true)
    }
    return
    #else
    // On a real device, run the usual setup code on the background queue.
    queue.async {
      let success = self.setUpCamera(sessionPreset: sessionPreset)
      DispatchQueue.main.async {
        completion(success)
      }
    }
    #endif
  }

  // Internal method to configure camera inputs, outputs, and session properties.
  private func setUpCamera(sessionPreset: AVCaptureSession.Preset) -> Bool {
    #if targetEnvironment(simulator)
    // In the simulator, bypass camera hardware configuration.
    print("Simulator mode: Skipping camera hardware configuration.")
    return true
    #else
    captureSession.beginConfiguration()
    captureSession.sessionPreset = sessionPreset

    guard let device = captureDevice,
          let videoInput = try? AVCaptureDeviceInput(device: device) else {
        return false
    }

    if captureSession.canAddInput(videoInput) {
      captureSession.addInput(videoInput)
    }

    let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.connection?.videoOrientation = .portrait
    self.previewLayer = previewLayer

    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
    ]

    videoOutput.videoSettings = settings
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    if captureSession.canAddOutput(cameraOutput) {
      captureSession.addOutput(cameraOutput)
    }
    switch UIDevice.current.orientation {
    case .portrait:
      videoOutput.connection(with: .video)?.videoOrientation = .portrait
    case .portraitUpsideDown:
      videoOutput.connection(with: .video)?.videoOrientation = .portraitUpsideDown
    case .landscapeRight:
      videoOutput.connection(with: .video)?.videoOrientation = .landscapeLeft
    case .landscapeLeft:
      videoOutput.connection(with: .video)?.videoOrientation = .landscapeRight
    default:
      videoOutput.connection(with: .video)?.videoOrientation = .portrait
    }

    if let connection = videoOutput.connection(with: .video) {
      self.previewLayer?.connection?.videoOrientation = connection.videoOrientation
    }
    do {
      try captureDevice.lockForConfiguration()
        
      // Set frame rate to 2 fps (1 frame every 0.5 seconds)
      let desiredFrameDuration = CMTime(value: 1, timescale: 2)
      captureDevice.activeVideoMaxFrameDuration = desiredFrameDuration
      captureDevice.activeVideoMinFrameDuration = desiredFrameDuration
        
      captureDevice.focusMode = .continuousAutoFocus
      captureDevice.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      captureDevice.exposureMode = .continuousAutoExposure
      captureDevice.unlockForConfiguration()
    } catch {
      print("Unable to configure the capture device.")
      return false
    }

    captureSession.commitConfiguration()
    return true
    #endif
  }

  // Starts the video capture session.
  public func start() {
    if !captureSession.isRunning {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.captureSession.startRunning()
      }
    }
  }

  // Stops the video capture session.
  public func stop() {
    if captureSession.isRunning {
      captureSession.stopRunning()
    }
  }

  func updateVideoOrientation() {
    guard let connection = videoOutput.connection(with: .video) else { return }
    switch UIDevice.current.orientation {
    case .portrait:
      connection.videoOrientation = .portrait
    case .portraitUpsideDown:
      connection.videoOrientation = .portraitUpsideDown
    case .landscapeRight:
      connection.videoOrientation = .landscapeLeft
    case .landscapeLeft:
      connection.videoOrientation = .landscapeRight
    default:
      return
    }

    let currentInput = self.captureSession.inputs.first as? AVCaptureDeviceInput
    if currentInput?.device.position == .front {
      connection.isVideoMirrored = true
    } else {
      connection.isVideoMirrored = false
    }

    self.previewLayer?.connection?.videoOrientation = connection.videoOrientation
  }

}

// Extension to handle AVCaptureVideoDataOutputSampleBufferDelegate events.
extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    delegate?.videoCapture(self, didCaptureVideoFrame: sampleBuffer)
  }

  public func captureOutput(
    _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // Optionally handle dropped frames, e.g., due to full buffer.
  }
}