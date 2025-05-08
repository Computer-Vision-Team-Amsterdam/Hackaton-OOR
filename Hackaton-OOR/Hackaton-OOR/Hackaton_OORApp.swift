import SwiftUI

@main
struct Hackaton_OORApp: App {
    @StateObject private var iotManager = IoTDeviceManager()

    init() {
        UserDefaults.standard.register(defaults: [
            "detectContainers": true,
            "detectMobileToilets": true,
            "detectScaffoldings": true,
        ])
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(iotManager)
                .onAppear {
                    iotManager.setupDeviceCredentials()
                }
        }
    }
}
