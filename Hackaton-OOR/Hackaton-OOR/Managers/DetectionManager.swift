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
    
    /// Handles video capture from the device's camera.
    private var videoCapture: VideoCapture?
    
    /// The Vision request for performing object detection using the CoreML model.
    private var visionRequest: VNCoreMLRequest?
    
    /// The CoreML model used for object detection.
    private var mlModel: MLModel?
    
    /// The Vision model wrapper for the CoreML model.
    private var detector: VNCoreMLModel?
    
    /// Stores the last captured pixel buffer for saving or processing.
    private var lastPixelBufferForSaving: CVPixelBuffer?
    
    /// Timestamp of the last captured pixel buffer.
    private var lastPixelBufferTimestamp: TimeInterval?
    
    /// The current pixel buffer being processed.
    private var currentBuffer: CVPixelBuffer?
    
    /// Handles data uploads to Azure IoT Hub.
    private var uploader: AzureIoTDataUploader?
    
    /// The Azure IoT Hub host URL.
    private let iotHubHost: String
    
    /// Indicates whether the video capture has been successfully configured.
    private(set) var isConfigured: Bool = false
    
    // MARK: - Published properties
    
    /// The number of objects detected.
    @Published var objectsDetected = 0
    
    /// The total number of images processed.
    @Published var totalImages = 0
    
    /// The total number of images successfully delivered to Azure.
    @Published var imagesDelivered = 0
    
    /// The total number of minutes the detection has been running.
    @Published var minutesRunning = 0
    
    private var detectionTimer: Timer?
    
    // MARK: - Initialization
    
    /// Initializes the DetectionManager, loading the YOLO model and setting up video capture.
    override init() {
        // Use centralized configuration from AppConfiguration.
        let config = AppConfiguration.shared
        self.iotHubHost = config.iothubHost
        
        super.init()
        self.uploader = AzureIoTDataUploader(host: self.iotHubHost)
        
        // 1. Load the YOLO model.
        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = .all
        
        do {
            // Replace `yolov8m` with the actual name of your generated model class.
            let loadedModel = try yolov8m(configuration: modelConfig).model
            self.mlModel = loadedModel
            let vnModel = try VNCoreMLModel(for: loadedModel)
            vnModel.featureProvider = config.staticThresholdProvider
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
    
    /// Starts the object detection process.
    /// Ensures the video capture is configured before starting.
    func startDetection() {
        guard isConfigured else {
            print("Video capture not configured yet. Delaying startDetection()...")
            // Optionally, schedule a retry after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startDetection()
            }
            return
        }
        videoCapture?.start()
        print("Detection started.")
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.minutesRunning += 1
            }
        }
    }
    
    /// Stops the object detection process and invalidates the detection timer.
    func stopDetection() {
        videoCapture?.stop()
        print("Detection stopped.")
        detectionTimer?.invalidate()
        detectionTimer = nil
    }
    
    // MARK: - VideoCaptureDelegate
    
    /// Processes each captured video frame for object detection.
    /// - Parameters:
    ///   - capture: The video capture instance.
    ///   - sampleBuffer: The captured video frame.
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
    
    /// Processes the results of the Vision request.
    /// - Parameters:
    ///   - request: The Vision request containing detection results.
    ///   - error: An optional error if the request failed.
    func processObservations(for request: VNRequest, error: Error?) {
        DispatchQueue.main.async(execute: {
            if let results = request.results as? [VNRecognizedObjectObservation] {

                let targetClasses: [(name: String, enabled: Bool)] = [
                    ("container", UserDefaults.standard.bool(forKey: "detectContainers")),
                    ("mobile toilet", UserDefaults.standard.bool(forKey: "detectMobileToilets")),
                    ("scaffolding", UserDefaults.standard.bool(forKey: "detectScaffoldings"))
                ]

                // Check if at least one enabled target is detected in the observations.
                let shouldProcess = targetClasses.contains { (objectName, isEnabled) in
                    return isEnabled && results.contains { observation in
                        if let label = observation.labels.first?.identifier.lowercased() {
                            return label == objectName
                        }
                        return false
                    }
                }
                if shouldProcess {
                    // --- Step 2: Identify sensitive objects and collect their bounding boxes.
                    // Define your sensitive classes.
                    let sensitiveClasses: Set<String> = ["person", "license plate"]
                    var sensitiveBoxes = [CGRect]()
                    var detectedBoxes: [String: [CGRect]] = [:]
                    var detectionCounts: [String: Int] = [:]
                    
                    // For each observation that is sensitive, convert its normalized bounding box to image coordinates.
                    // (Assume 'image' is created from your saved pixel buffer.)
                    if let pixelBuffer = self.lastPixelBufferForSaving,
                       var image = self.imageFromPixelBuffer(pixelBuffer: pixelBuffer) {
                        
                        let imageSize = image.size
                        for observation in results {
                            if let label = observation.labels.first?.identifier.lowercased() {
                                let normRect = observation.boundingBox
                                let rectInImage = VNImageRectForNormalizedRect(normRect, Int(imageSize.width), Int(imageSize.height))

                                if targetClasses.contains(where: { $0.enabled && $0.name == label }) {
                                    detectedBoxes[label, default: []].append(rectInImage)
                                    detectionCounts[label, default: 0] += 1
                                } else if sensitiveClasses.contains(label) {
                                    sensitiveBoxes.append(rectInImage)
                                }
                            }
                        }

                        let totalDetected = detectionCounts.values.reduce(0, +)
                        DispatchQueue.main.async {
                            self.objectsDetected += totalDetected
                        }
                        
                        if !sensitiveBoxes.isEmpty,
                           let imageWithBlackBoxes = self.coverSensitiveAreasWithBlackBox(in: image, boxes: sensitiveBoxes) {
                            image = imageWithBlackBoxes
                        }

                        // If drawing bounding boxes is enabled, draw them on the image.
                        if UserDefaults.standard.bool(forKey: "drawBoundingBoxes") {
                            let colors: [String: UIColor] = [
                                "container": .red,
                                "mobile toilet": .blue,
                                "scaffolding": .green
                            ]
                            image = self.drawSquaresAroundDetectedAreas(in: image, boxesPerObject: detectedBoxes, colors: colors)
                        }
                        self.deliverDetectionToAzure(image: image, predictions: results)
                        self.lastPixelBufferForSaving = nil
                    }
                }
            }
        })
    }
    
    /// Converts a pixel buffer to a UIImage.
    /// - Parameter pixelBuffer: The pixel buffer to convert.
    /// - Returns: A UIImage representation of the pixel buffer, or `nil` if conversion fails.
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
    
    /// Retrieves the "Detections" folder in the app's Documents directory.
    /// - Throws: An error if the folder cannot be located or created.
    /// - Returns: The URL of the "Detections" folder.
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
    
    /// Delivers the detection results to Azure IoT Hub.
    /// - Parameters:
    ///   - image: The image containing the detection results.
    ///   - predictions: The list of detected objects.
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
    
    /// Uploads any remaining files in the "Detections" folder to Azure IoT Hub.
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
    
    /// Covers sensitive areas in an image with black boxes.
    /// - Parameters:
    ///   - image: The image to process.
    ///   - boxes: The bounding boxes of sensitive areas.
    /// - Returns: A new image with sensitive areas covered, or `nil` if processing fails.
    func coverSensitiveAreasWithBlackBox(in image: UIImage, boxes: [CGRect]) -> UIImage? {
        // Convert the UIImage to a CIImage.
        guard let ciImage = CIImage(image: image) else { return nil }
        var outputImage = ciImage
        let context = CIContext(options: nil)
        
        for box in boxes {
            // Create a black color image using CIConstantColorGenerator.
            guard let colorFilter = CIFilter(name: "CIConstantColorGenerator") else { continue }
            // Create a CIColor for black.
            let blackColor = CIColor(color: .black)
            colorFilter.setValue(blackColor, forKey: kCIInputColorKey)
            
            // Generate the black image and crop it to the box.
            guard let fullBlackImage = colorFilter.outputImage?.cropped(to: box) else { continue }
            
            // Composite the black box over the current output image.
            if let compositeFilter = CIFilter(name: "CISourceOverCompositing") {
                compositeFilter.setValue(fullBlackImage, forKey: kCIInputImageKey)
                compositeFilter.setValue(outputImage, forKey: kCIInputBackgroundImageKey)
                if let composited = compositeFilter.outputImage {
                    outputImage = composited
                }
            }
        }
        
        // Render the final output image.
        if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
            return UIImage(cgImage: cgImage)
        }
        
        return nil
    }

    /// Draws rectangles around container areas in an image.
    /// - Parameters:
    ///   - image: The image to process.
    ///   - boxes: The bounding boxes of container areas.
    ///   - color: The color of the rectangles (default is red).
    ///   - lineWidth: The width of the rectangle lines (default is 3.0).
    /// - Returns: A new image with rectangles drawn around container areas.
    func drawSquaresAroundDetectedAreas(
        in image: UIImage,
        boxesPerObject: [String: [CGRect]],
        colors: [String: UIColor],
        lineWidth: CGFloat = 3.0
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            // Draw the image (assumed to be drawn in the top-left origin space)
            image.draw(at: .zero)
            
            for (label, boxes) in boxesPerObject {
                let color = colors[label] ?? .yellow // Default if label not found.
                context.cgContext.setStrokeColor(color.cgColor)
                context.cgContext.setLineWidth(3.0)
                
                for box in boxes {
                    // Adjust for coordinate system conversion.
                    let adjustedBox = CGRect(
                        x: box.origin.x,
                        y: image.size.height - box.origin.y - box.size.height,
                        width: box.size.width,
                        height: box.size.height
                    )
                    context.cgContext.stroke(adjustedBox)
                    // Optionally add text labels here.
                }
            }
        }
    }
    
    /// Blurs sensitive areas in an image.
    /// - Parameters:
    ///   - image: The image to process.
    ///   - boxes: The bounding boxes of sensitive areas.
    ///   - blurRadius: The radius of the blur effect (default is 20).
    /// - Returns: A new image with sensitive areas blurred, or `nil` if processing fails.
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
