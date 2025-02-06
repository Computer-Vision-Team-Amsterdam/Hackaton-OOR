import Foundation
import AVFoundation
import CoreML
import Vision
import UIKit

/// A singleton manager that encapsulates video capture and YOLO-based object detection.
class DetectionManager: NSObject, ObservableObject, VideoCaptureDelegate {
    static let shared = DetectionManager()
    private var locationManager = LocationManager()
    
    // MARK: - Private properties
    
    private var videoCapture: VideoCapture?
    private var visionRequest: VNCoreMLRequest?
    private var mlModel: MLModel?
    private var detector: VNCoreMLModel?
    private var lastPixelBufferForSaving: CVPixelBuffer?
    private var lastPixelBufferTimestamp: TimeInterval?
    private var currentBuffer: CVPixelBuffer?
    private var uploader: AzureIoTDataUploader?
    
    // Keep track of the last known user default values
    private var lastConfidenceThreshold: Double = 0.25
    private var lastIoUThreshold: Double = 0.45
    
    // Track whether the video capture has finished configuration.
    private(set) var isConfigured: Bool = false
    
    // Create an instance of the data uploader.
    private let iotHubHost = "iothub-oor-ont-weu-itr-01.azure-devices.net"
    private let deviceId = "test-Sebastian"
    private let deviceSasToken = ""
    
    @Published var objectsDetected = 0
    @Published var totalImages = 0
    @Published var imagesDelivered = 0
    
    private var detectionTimer: Timer?
    @Published var minutesRunning = 0
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        self.uploader = AzureIoTDataUploader(host: self.iotHubHost, deviceId: self.deviceId, sasToken: self.deviceSasToken)
        
        // 1. Load the YOLO model.
        let modelConfig = MLModelConfiguration()
        // (Optional) Enable new experimental options for iOS 17+
        if #available(iOS 17.0, *) {
            modelConfig.setValue(1, forKey: "experimentalMLE5EngineUsage")
        }
        
        do {
            // Replace `yolov8m` with the actual name of your generated model class.
            let loadedModel = try yolov8m(configuration: modelConfig).model
            self.mlModel = loadedModel
            let vnModel = try VNCoreMLModel(for: loadedModel)
            vnModel.featureProvider = ThresholdManager.shared.getThresholdProvider()
            self.detector = vnModel
        } catch {
            print("Error loading model: \(error)")
        }
        
        // 2. Create the Vision request.
        if let detector = detector {
            visionRequest = VNCoreMLRequest(model: detector, completionHandler: { [weak self] request, error in
                self?.processObservations(for: request, error: error)
            })
            // Set the option for cropping/scaling (adjust as needed).
            visionRequest?.imageCropAndScaleOption = .scaleFill
        }
        
        // 3. Set up video capture.
        videoCapture = VideoCapture()
        videoCapture?.delegate = self
        // You can change the sessionPreset if needed.
        videoCapture?.setUp(sessionPreset: .hd1280x720) { success in
            if success {
                print("Video capture setup successful.")
                self.isConfigured = true
            } else {
                print("Video capture setup failed.")
            }
        }
    }
    
    // MARK: - Public Methods
    
    // Start detection only if configured.
    func startDetection() {
        guard isConfigured else {
            print("Video capture not configured yet. Delaying startDetection()...")
            // Optionally, schedule a retry after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startDetection()
            }
            return
        }
        updateThresholdsIfNeeded()
        videoCapture?.start()
        print("Detection started.")
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.minutesRunning += 1
            }
        }
    }
    
    /// Stops the video capture (and detection).
    func stopDetection() {
        videoCapture?.stop()
        print("Detection stopped.")
        detectionTimer?.invalidate()
        detectionTimer = nil
    }
  
    /// Updates Thresholds if adjusted.
    private func updateThresholdsIfNeeded() {
        let tempProvider = ThresholdManager.shared.getThresholdProvider()
        let finalConf = tempProvider.confidenceThreshold
        let finalIoU = tempProvider.iouThreshold
        
        if finalConf != lastConfidenceThreshold || finalIoU != lastIoUThreshold {
            print("Updating thresholds: Confidence=\(finalConf), IoU=\(finalIoU)")
            detector?.featureProvider = tempProvider
            lastConfidenceThreshold = finalConf
            lastIoUThreshold = finalIoU
        }
    }
    
    // MARK: - VideoCaptureDelegate
    
    func videoCapture(_ capture: VideoCapture, didCaptureVideoFrame sampleBuffer: CMSampleBuffer) {
        // Only process if no other frame is currently being processed.
        if currentBuffer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let request = visionRequest {
            
            // Store the pixel buffer for later use (e.g., to convert to UIImage)
            currentBuffer = pixelBuffer
            self.lastPixelBufferForSaving = pixelBuffer
            self.lastPixelBufferTimestamp = NSDate().timeIntervalSince1970
            
            // Optionally, set the image orientation based on your needs.
            // Here we use .up for simplicity.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("Error performing Vision request: \(error)")
            }
            // Reset the currentBuffer so that you can process the next frame.
            currentBuffer = nil
        }
    }
    
    // MARK: - Process Detection Results
    
    func processObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async(execute: {
            if let results = request.results as? [VNRecognizedObjectObservation] {
                // --- Step 1: Check if at least one "container" is detected.
                let containerDetected = results.contains { observation in
                    if let label = observation.labels.first?.identifier.lowercased() {
                        return label == "container"
                    }
                    return false
                }
                
                // Only proceed if a container is detected.
                if containerDetected {
                    // --- Step 2: Identify sensitive objects and collect their bounding boxes.
                    // Define your sensitive classes.
                    let sensitiveClasses: Set<String> = ["person", "license plate"]
                    var sensitiveBoxes = [CGRect]()
                    
                    // For each observation that is sensitive, convert its normalized bounding box to image coordinates.
                    // (Assume 'image' is created from your saved pixel buffer.)
                    if let pixelBuffer = self.lastPixelBufferForSaving,
                       let image = self.imageFromPixelBuffer(pixelBuffer: pixelBuffer) {
                        
                        let imageSize = image.size
                        for observation in results {
                            if let label = observation.labels.first?.identifier.lowercased(),
                               label == "container" {
                                DispatchQueue.main.async {
                                    self.objectsDetected += 1
                                }
                            }
                            if let label = observation.labels.first?.identifier.lowercased(),
                               sensitiveClasses.contains(label) {
                                let normRect = observation.boundingBox
                                // VNImageRectForNormalizedRect converts a normalized rect (origin bottom-left)
                                // into pixel coordinates (origin top-left) given the image width and height.
                                let rectInImage = VNImageRectForNormalizedRect(normRect, Int(imageSize.width), Int(imageSize.height))
                                sensitiveBoxes.append(rectInImage)
                            }
                        }
                        
                        // --- Step 3: Blur the sensitive regions.
                        if !sensitiveBoxes.isEmpty, let blurredImage = self.blurSensitiveAreas(in: image, boxes: sensitiveBoxes, blurRadius: 10) {
                            // Save the blurred image (using your custom saveDetetction(_:) method).
                            self.deliverDetectionToAzure(image: blurredImage, predictions: results)
                            //                      // Optionally clear the pixel buffer so this frame isn’t saved again.
                            //                      self.lastPixelBufferForSaving = nil
                        }
                        else {
                            self.deliverDetectionToAzure(image: image, predictions: results)
                        }
                        // Optionally clear the pixel buffer so this frame isn’t saved again.
                        self.lastPixelBufferForSaving = nil
                    }
                }
            }
        })
    }
    
    func imageFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
    
    enum FileError: Error {
        case documentsFolderNotFound(String)
    }
    
    func getDetectionsFolder() throws -> URL {
        // Locate the "Detections" folder in the app’s Documents directory.
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Could not locate Documents folder.")
            throw FileError.documentsFolderNotFound("Could not locate Documents folder.")
        }
        let detectionsFolderURL = documentsURL.appendingPathComponent("Detections")
        
        // Ensure the "Detections" folder exists.
        if !FileManager.default.fileExists(atPath: detectionsFolderURL.path) {
            do {
                try FileManager.default.createDirectory(at: detectionsFolderURL, withIntermediateDirectories: true, attributes: nil)
                print("Created Detections folder at: \(detectionsFolderURL.path)")
            } catch {
                print("Error creating folder: \(error.localizedDescription)")
                throw FileError.documentsFolderNotFound("Error creating folder: \(error.localizedDescription)")
            }
        }
        return detectionsFolderURL
    }
    
    func deliverDetectionToAzure(image: UIImage, predictions: [VNRecognizedObjectObservation]){
        print("deliverDetectionToAzure")
        DispatchQueue.main.async {
            self.totalImages += 1
        }
        // Generate a filename using the current date/time.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmssSSS"
        let dateString = dateFormatter.string(from: Date())
        let fileNameBase = "detection_\(dateString)"
        print(fileNameBase)
        
        // Upload image
        if let imageData = image.jpegData(compressionQuality: 0.5) {
            uploader?.uploadData(imageData, blobName: "\(fileNameBase).jpg") { error in
                if let error = error {
                    print("Data upload failed: \(error.localizedDescription)")
                    do {
                        let detectionsFolderURL = try self.getDetectionsFolder()
                        let imageURL = detectionsFolderURL.appendingPathComponent("\(fileNameBase).jpg")
                        try imageData.write(to: imageURL)
                        print("Saved image at \(imageURL)")
                    } catch {
                        print("Error saving image: \(error)")
                    }
                } else {
                    DispatchQueue.main.async {
                        self.imagesDelivered += 1
                    }
                    print("Data uploaded successfully!")
                }
            }
        }
        
        // Build the metadata for each prediction.
        var predictionsMetadata = [[String: Any]]()
        for prediction in predictions {
            if let bestLabel = prediction.labels.first?.identifier {
                let meta: [String: Any] = [
                    "label": bestLabel,
                    "confidence": prediction.labels.first?.confidence ?? 0,
                    "boundingBox": [
                        "x": prediction.boundingBox.origin.x,
                        "y": prediction.boundingBox.origin.y,
                        "width": prediction.boundingBox.size.width,
                        "height": prediction.boundingBox.size.height
                    ]
                ]
                predictionsMetadata.append(meta)
            }
        }
        
        // Create the metadata dictionary.
        var metadata: [String: Any] = [
            "date": dateString,
            "predictions": predictionsMetadata
        ]
        if let coordinate = locationManager.lastKnownLocation {
            metadata["latitude"] = coordinate.latitude
            metadata["longitude"] = coordinate.longitude
        } else {
            metadata["latitude"] = ""
            metadata["longitude"] = ""
        }
        if self.lastPixelBufferTimestamp != nil {
            metadata["image_timestamp"] = self.lastPixelBufferTimestamp
        } else {
            metadata["image_timestamp"] = ""
        }
        if let timestamp = locationManager.lastTimestamp {
            metadata["gps_timestamp"] = timestamp
        } else {
            metadata["gps_timestamp"] = ""
        }
        if let gps_accuracy = locationManager.lastAccuracy {
            metadata["gps_accuracy"] = gps_accuracy
        } else {
            metadata["gps_accuracy"] = ""
        }
        // Deliver to Azure the metadata as a JSON file.
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            uploader?.uploadData(jsonData, blobName: "\(fileNameBase).json") { error in
                if let error = error {
                    print("Data upload failed: \(error.localizedDescription)")
                    do {
                        let detectionsFolderURL = try self.getDetectionsFolder()
                        let metadataURL = detectionsFolderURL.appendingPathComponent("\(fileNameBase).json")
                        try jsonData.write(to: metadataURL)
                        print("Saved metadata at \(metadataURL)")
                    } catch {
                        print("Error saving metadata: \(error)")
                    }
                } else {
                    print("Data uploaded successfully!")
                }
            }
        } catch {
            print("Error saving metadata: \(error)")
        }
    }
    
    func deliverFilesFromDocuments() {
        do {
            let detectionsFolderURL = try self.getDetectionsFolder()
            let fileURLs = try FileManager.default.contentsOfDirectory(at: detectionsFolderURL,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [])
            DispatchQueue.main.async {
                self.totalImages += fileURLs.count
            }
            for fileURL in fileURLs {
                do {
                    let fileData = try Data(contentsOf: fileURL)
                    let blobName = fileURL.lastPathComponent
                    
                    uploader?.uploadData(fileData, blobName: blobName) { error in
                        if let error = error {
                            print("Error uploading file \(blobName): \(error)")
                        } else {
                            print("Successfully uploaded file \(blobName). Now deleting it.")
                            do {
                                // Delete the file after successful upload.
                                try FileManager.default.removeItem(at: fileURL)
                                print("Deleted file \(blobName)")
                                DispatchQueue.main.async {
                                    self.imagesDelivered += 1
                                }
                            } catch {
                                print("Error deleting file \(blobName): \(error)")
                            }
                        }
                    }
                } catch {
                    print("Error reading data from file \(fileURL): \(error)")
                }
            }
        } catch {
            print("Error retrieving detections folder: \(error)")
        }
    }
    
    func blurSensitiveAreas(in image: UIImage, boxes: [CGRect], blurRadius: Double = 20) -> UIImage? {
        // Convert the UIImage to a CIImage.
        guard let ciImage = CIImage(image: image) else { return nil }
        var outputImage = ciImage
        let context = CIContext(options: nil)
        
        for box in boxes {
            // Crop the region to blur.
            let cropped = outputImage.cropped(to: box)
            
            // Apply a Gaussian blur filter to the cropped area.
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(cropped, forKey: kCIInputImageKey)
                blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
                guard let blurredCropped = blurFilter.outputImage else { continue }
                // The blur filter may expand the image extent; crop back to the original box.
                let blurredRegion = blurredCropped.cropped(to: box)
                
                // Composite the blurred region over the current output image.
                if let compositeFilter = CIFilter(name: "CISourceOverCompositing") {
                    compositeFilter.setValue(blurredRegion, forKey: kCIInputImageKey)
                    compositeFilter.setValue(outputImage, forKey: kCIInputBackgroundImageKey)
                    if let composited = compositeFilter.outputImage {
                        outputImage = composited
                    }
                }
            }
        }
        
        // Render the final composited image.
        if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}
