import Foundation

// MARK: - Model Structures

struct FileUploadResponse: Codable {
    let correlationId: String
    let hostName: String
    let containerName: String
    let blobName: String
    let sasToken: String
}

struct FileUploadNotification: Codable {
    let correlationId: String
    let isSuccess: Bool
    let statusCode: Int
    let statusDescription: String
}

// MARK: - Azure IoT Data Uploader

class AzureIoTDataUploader {
    private let host: String
    private var deviceId: String
    private var sasToken: String
    private let apiVersion: String = "2021-04-12"
    
    init(host: String) {
        self.host = host
        self.deviceId = IoTDeviceManager.shared.deviceId!.trimmingCharacters(in: .init(charactersIn: "\""))
        self.sasToken = IoTDeviceManager.shared.deviceSasToken!.trimmingCharacters(in: .init(charactersIn: "\""))
    }
    
    func uploadData(_ data: Data, blobName: String, completion: @escaping (Error?) -> Void) {
        requestFileUpload(blobName: blobName, retryOn401: true) { result in
            switch result {
            case .success(let uploadInfo):
                self.uploadToBlob(data: data, uploadResponse: uploadInfo) { result in
                    switch result {
                    case .success:
                        self.notifyFileUpload(correlationId: uploadInfo.correlationId, isSuccess: true) { notifyError in
                            completion(notifyError)
                        }
                    case .failure(let uploadError):
                        self.notifyFileUpload(correlationId: uploadInfo.correlationId, isSuccess: false) { _ in
                            completion(uploadError)
                        }
                    }
                }
            case .failure(let error):
                completion(error)
            }
        }
    }
    
    private func requestFileUpload(blobName: String,
                                   retryOn401: Bool = true,
                                   completion: @escaping (Result<FileUploadResponse, Error>) -> Void) {
        guard let url = URL(string: "https://\(host)/devices/\(deviceId)/files?api-version=\(apiVersion)") else {
            completion(.failure(NSError(domain: "AzureIoTDataUploader",
                                        code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL for file upload request."])))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(sasToken, forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["blobName": blobName]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.failure(error))
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResp = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "AzureIoTDataUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response received."])))
                return
            }
            
            if httpResp.statusCode == 401 && retryOn401 {
                print("Received 401 - refreshing credentials and retrying...")
                self.refreshCredentials()
                self.requestFileUpload(blobName: blobName, retryOn401: false, completion: completion)
                return
            }
            
            guard (200...299).contains(httpResp.statusCode), let data = data else {
                let statusCode = httpResp.statusCode
                completion(.failure(NSError(domain: "AzureIoTDataUploader",
                                            code: statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "File upload request failed with status code \(statusCode)."])))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let uploadResponse = try decoder.decode(FileUploadResponse.self, from: data)
                completion(.success(uploadResponse))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func refreshCredentials() {
        IoTDeviceManager.shared.setupDeviceCredentials()
        self.deviceId = IoTDeviceManager.shared.deviceId!.trimmingCharacters(in: .init(charactersIn: "\""))
        self.sasToken = IoTDeviceManager.shared.deviceSasToken!.trimmingCharacters(in: .init(charactersIn: "\""))
        print("Refreshed deviceId: \(deviceId)")
        print("Refreshed sasToken: \(sasToken)")
    }
    
    private func uploadToBlob(data: Data,
                              uploadResponse: FileUploadResponse,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        let blobUrlString = "https://\(uploadResponse.hostName)/\(uploadResponse.containerName)/\(uploadResponse.blobName)\(uploadResponse.sasToken)"
        guard let url = URL(string: blobUrlString) else {
            completion(.failure(NSError(domain: "AzureIoTDataUploader",
                                        code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid blob URL."])))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.addValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.addValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        
        URLSession.shared.uploadTask(with: request, from: data) { _, response, error in
            if let error = error {
                print("Upload task error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let err = NSError(domain: "AzureIoTDataUploader",
                                  code: statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Blob upload failed with status code \(statusCode)."])
                print("Blob upload failed: \(err.localizedDescription)")
                completion(.failure(err))
                return
            }
            completion(.success(()))
        }.resume()
    }
    
    private func notifyFileUpload(correlationId: String,
                                  isSuccess: Bool,
                                  completion: @escaping (Error?) -> Void) {
        guard let url = URL(string: "https://\(host)/devices/\(deviceId)/files/notifications?api-version=\(apiVersion)") else {
            completion(NSError(domain: "AzureIoTDataUploader",
                               code: 0,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid URL for file upload notification."]))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(sasToken, forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "correlationId": correlationId,
            "isSuccess": isSuccess,
            "statusCode": isSuccess ? 200 : 500,
            "statusDescription": isSuccess ? "Success" : "Failure"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(error)
            return
        }
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(error)
                return
            }
            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(NSError(domain: "AzureIoTDataUploader",
                                   code: statusCode,
                                   userInfo: [NSLocalizedDescriptionKey: "Notification failed with status code \(statusCode)."]))
                return
            }
            completion(nil)
        }.resume()
    }
}
