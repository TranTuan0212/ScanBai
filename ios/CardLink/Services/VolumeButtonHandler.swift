//
//  VolumeButtonHandler.swift
//  CardLink
//
//  Physical Volume Button Listener for iOS.
//  Intercepts Volume Up (+) presses to start/stop 240 FPS 1080p 1x Slow-Mo Deal Round recording,
//  triggers offline card slicing, sends round analytics to server, and resets for next round.
//

import Foundation
import MediaPlayer
import AVFoundation
import UIKit

final class VolumeButtonHandler: NSObject, ObservableObject {
    static let shared = VolumeButtonHandler()
    
    @Published var isListening: Bool = false
    @Published var isRecordingRound: Bool = false
    
    var onVolumeButtonPressed: (() -> Void)?
    
    private var volumeView: MPVolumeView?
    private var audioSession = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var lastPressTime: Date = Date.distantPast
    
    override init() {
        super.init()
    }
    
    func startListening(onPress: @escaping () -> Void) {
        self.onVolumeButtonPressed = onPress
        
        do {
            try audioSession.setCategory(.ambient, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("⚠️ [VolumeButtonHandler] AudioSession setup failed: \(error)")
        }
        
        // Hide standard iOS volume slider overlay HUD
        DispatchQueue.main.async {
            if self.volumeView == nil {
                let v = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
                v.alpha = 0.01
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first {
                    window.addSubview(v)
                }
                self.volumeView = v
            }
        }
        
        // Observe outputVolume property changes
        observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            guard let self = self else { return }
            let now = Date()
            // Debounce double presses within 0.35s
            guard now.timeIntervalSince(self.lastPressTime) >= 0.35 else { return }
            self.lastPressTime = now
            
            DispatchQueue.main.async {
                print("🔊 [Physical Button] Volume (+) Pressed! Toggling 240FPS Slow-Mo Deal Recording...")
                // Trigger Haptic Feedback Vibration
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                self.isRecordingRound.toggle()
                self.onVolumeButtonPressed?()
            }
        }
        
        isListening = true
        print("✅ [VolumeButtonHandler] Physical Volume Button listener activated!")
    }
    
    func stopListening() {
        observation?.invalidate()
        observation = nil
        isListening = false
        print("🛑 [VolumeButtonHandler] Physical Volume Button listener stopped.")
    }
}
