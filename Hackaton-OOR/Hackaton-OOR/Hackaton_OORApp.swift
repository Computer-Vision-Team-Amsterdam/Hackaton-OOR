//
//  Hackaton_OORApp.swift
//  Hackaton-OOR
//
//  Created by Sebastian Davrieux on 31/01/2025.
//

import SwiftUI

@main
struct Hackaton_OORApp: App {
    init() {
        UserDefaults.standard.register(defaults: ["detectContainers": true,
                                                  "iouThreshold": 0.45,
                                                  "confidenceThreshold": 0.25])
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
