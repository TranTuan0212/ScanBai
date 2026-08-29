//
//  CardLinkApp.swift
//  CardLink
//
//  Main Entry Point for CardLink Broadcast iOS SwiftUI Application.
//

import SwiftUI
import AVFoundation

enum NavigationState {
    case login
    case sessionPicker
    case live
}

@main
struct CardLinkApp: App {
    @State private var navigationState: NavigationState = .login
    @State private var activeSessionId: String = ""
    
    var body: some Scene {
        WindowGroup {
            Group {
                switch navigationState {
                case .login:
                    LoginView(navigationState: $navigationState)
                case .sessionPicker:
                    SessionPickerView(navigationState: $navigationState, activeSessionId: $activeSessionId)
                case .live:
                    LiveView()
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                requestCameraPermission()
            }
        }
    }
    
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                print("✅ Camera permission granted")
            } else {
                print("❌ Camera permission denied")
            }
        }
    }
}
