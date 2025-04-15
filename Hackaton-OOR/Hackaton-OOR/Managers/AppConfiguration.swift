import CoreML

/// Provides static threshold values from the app’s Info.plist.
class StaticThresholdProvider: MLFeatureProvider {
    let thresholds: [String: (iou: Double, confidence: Double)]
    
    /// The feature names available in this provider.
    var featureNames: Set<String> {
        var names = Set<String>()
        for key in thresholds.keys {
            names.insert("\(key)_iouThreshold")
            names.insert("\(key)_confidenceThreshold")
        }
        return names
    }
    
    /// Retrieves the feature value for a given feature name.
    /// - Parameter featureName: The name of the feature.
    /// - Returns: The feature value, or nil if the feature name is not recognized.
    func featureValue(for featureName: String) -> MLFeatureValue? {
        let components = featureName.split(separator: "_")
        guard components.count == 2,
              let values = thresholds[String(components[0])] else {
            return nil
        }
        
        if components[1] == "iouThreshold" {
            return MLFeatureValue(double: values.iou)
        } else if components[1] == "confidenceThreshold" {
            return MLFeatureValue(double: values.confidence)
        }
        return nil
    }
    
    /// Initializes the StaticThresholdProvider with a dictionary of thresholds.
    /// - Parameter thresholds: A dictionary where the key is the name of the object and the value is a tuple containing IoU and confidence thresholds.
    /// - Example: `["container": (iou: 0.45, confidence: 0.25)]`
    init(thresholds: [String: (iou: Double, confidence: Double)]) {
        self.thresholds = thresholds
    }
}

/// Central configuration struct that reads values from Info.plist.
struct AppConfiguration {
    static let shared = AppConfiguration()
    
    let iothubHost: String
    let staticThresholdProvider: StaticThresholdProvider
    
    private init() {
        let infoDict = Bundle.main.infoDictionary ?? [:]
        
        // Read thresholds from Info.plist
        let containerIoU = Double(infoDict["ContainerIoUThreshold"] as? String ?? "0.45") ?? 0.45
        let containerConfidence = Double(infoDict["ContainerConfidenceThreshold"] as? String ?? "0.25") ?? 0.25
        
        let mobileToiletIoU = Double(infoDict["MobileToiletIoUThreshold"] as? String ?? "0.45") ?? 0.45
        let mobileToiletConfidence = Double(infoDict["MobileToiletConfidenceThreshold"] as? String ?? "0.25") ?? 0.25
        
        let scaffoldingIoU = Double(infoDict["ScaffoldingIoUThreshold"] as? String ?? "0.45") ?? 0.45
        let scaffoldingConfidence = Double(infoDict["ScaffoldingConfidenceThreshold"] as? String ?? "0.25") ?? 0.25
        
        let thresholds = [
            "container": (iou: containerIoU, confidence: containerConfidence),
            "mobile toilet": (iou: mobileToiletIoU, confidence: mobileToiletConfidence),
            "scaffolding": (iou: scaffoldingIoU, confidence: scaffoldingConfidence)
        ]
        
        // Create the static threshold provider.
        self.staticThresholdProvider = StaticThresholdProvider(thresholds: thresholds)
        
        // Read other config values
        self.iothubHost = infoDict["IoTHubHost"] as? String ?? "iothub-oor-ont-weu-itr-01.azure-devices.net"
    }
}