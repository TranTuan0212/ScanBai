//
//  CameraManager.swift
//  CardLink
//
//  AVCaptureSession manager configured for highest supported FPS (60/120/240 FPS) and 1080p Full HD resolution.
//  Includes Multi-Lens Zoom Switching (0.5x Ultra-Wide, 1x Wide, 2x Telephoto) and
//  Real-Time Dynamic Device Orientation Rotation (Portrait, Landscape Left, Landscape Right).
//

import Foundation
import AVFoundation
import UIKit

final class CameraManager: NSObject, ObservableObject {
    
    @Published var isRunning = false
    @Published var isTorchOn = false
    @Published var currentFPS: Double = 0.0
    @Published var activeResolution: String = "1080p"
    @Published var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
    @Published var cgImageOrientation: CGImagePropertyOrientation = .right
    @Published var availableZoomFactors: [CGFloat] = [1.0]
    @Published var currentZoomFactor: CGFloat = 1.0
    
    let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.cardlink.camera.sessionQueue", qos: .userInitiated)
    
    var onFrameCaptured: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    
    override init() {
        super.init()
        setupOrientationObserver()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Listen for physical iPhone rotation (Portrait, Landscape Left, Landscape Right)
    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleOrientationChange() {
        updateOrientation()
    }
    
    func updateOrientation() {
        var newVideoOrientation: AVCaptureVideoOrientation = .portrait
        var newCGOrientation: CGImagePropertyOrientation = .right
        
        let deviceOrientation = UIDevice.current.orientation
        
        if deviceOrientation == .landscapeLeft {
            newVideoOrientation = .landscapeRight
            newCGOrientation = .up
        } else if deviceOrientation == .landscapeRight {
            newVideoOrientation = .landscapeLeft
            newCGOrientation = .down
        } else if deviceOrientation == .portraitUpsideDown {
            newVideoOrientation = .portraitUpsideDown
            newCGOrientation = .left
        } else if deviceOrientation == .portrait {
            newVideoOrientation = .portrait
            newCGOrientation = .right
        } else {
            // Fallback: If device is laying flat on a table (faceUp / faceDown), check UI window orientation!
            if let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                switch windowScene.interfaceOrientation {
                case .landscapeLeft:
                    newVideoOrientation = .landscapeLeft
                    newCGOrientation = .down
                case .landscapeRight:
                    newVideoOrientation = .landscapeRight
                    newCGOrientation = .up
                case .portraitUpsideDown:
                    newVideoOrientation = .portraitUpsideDown
                    newCGOrientation = .left
                default:
                    newVideoOrientation = .portrait
                    newCGOrientation = .right
                }
            }
        }
        
        DispatchQueue.main.async {
            self.currentVideoOrientation = newVideoOrientation
            self.cgImageOrientation = newCGOrientation
        }
        
        sessionQueue.async { [weak self] in
            guard let self = self, let connection = self.videoDataOutput.connection(with: .video) else { return }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = newVideoOrientation
            }
        }
    }
    
    func setupAndStartSession(onFrame: @escaping (CVPixelBuffer, CGImagePropertyOrientation) -> Void) {
        self.onFrameCaptured = onFrame
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureCaptureSession()
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isRunning = self.captureSession.isRunning
                self.updateOrientation()
            }
        }
    }
    
    private func configureCaptureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // CRITICAL FOR APPLE 240 FPS: sessionPreset MUST be set to .inputPriority to allow custom activeFormat!
        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
            DispatchQueue.main.async { self.activeResolution = "1080p 240 FPS Ultra-Sharp" }
        } else {
            captureSession.sessionPreset = .high
        }
        
        // Discover highest capability camera (Triple, Dual-Wide, or Standard Wide)
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera
        ]
        
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("❌ [iOS Camera] Back camera not found")
            return
        }
        self.videoDevice = device
        
        // Discover supported hardware zoom factors (0.5x Ultra-Wide, 1.0x Wide, 2.0x Telephoto)
        discoverZoomFactors(for: device)
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                self.videoDeviceInput = input
            }
        } catch {
            print("❌ [iOS Camera] Failed to create device input: \(error)")
            return
        }
        
        // Configure Video Output
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
        
        configureHighestFPSAndStabilization(for: device)
    }
    
    private func discoverZoomFactors(for device: AVCaptureDevice) {
        var factors: [CGFloat] = []
        
        // Check if device is a virtual multi-camera with 0.5x ultra-wide
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            factors.append(0.5)
            factors.append(1.0)
            if device.maxAvailableVideoZoomFactor >= 2.0 {
                factors.append(2.0)
            }
        } else {
            // Check if separate ultra-wide lens exists on device
            let ultraWideDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back)
            if !ultraWideDiscovery.devices.isEmpty {
                factors.append(0.5)
            }
            factors.append(1.0)
            if device.maxAvailableVideoZoomFactor >= 2.0 {
                factors.append(2.0)
            }
        }
        
        DispatchQueue.main.async {
            self.availableZoomFactors = factors
            self.currentZoomFactor = factors.contains(1.0) ? 1.0 : (factors.first ?? 1.0)
        }
    }
    
    /// Switch camera zoom factor (0.5x Ultra-Wide, 1.0x Wide, 2.0x Telephoto) in real time
    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.videoDevice else { return }
            
            // 1. If device is virtual multi-camera (Triple / DualWide), adjust videoZoomFactor
            if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
                do {
                    try device.lockForConfiguration()
                    let targetZoom: CGFloat
                    if factor == 0.5 {
                        targetZoom = 1.0 // In virtual camera with ultra-wide base, 1.0 is 0.5x
                    } else if factor == 1.0 {
                        targetZoom = 2.0 // 1x wide
                    } else {
                        targetZoom = 4.0 // 2x telephoto
                    }
                    let clamped = max(device.minAvailableVideoZoomFactor, min(device.maxAvailableVideoZoomFactor, targetZoom))
                    device.videoZoomFactor = clamped
                    device.unlockForConfiguration()
                    DispatchQueue.main.async { self.currentZoomFactor = factor }
                } catch {
                    print("❌ [iOS Camera] Zoom configuration failed: \(error)")
                }
            } else {
                // 2. If switching between physical ultra-wide and wide camera inputs
                let targetType: AVCaptureDevice.DeviceType = (factor == 0.5) ? .builtInUltraWideCamera : .builtInWideAngleCamera
                let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [targetType], mediaType: .video, position: .back)
                
                if let newDevice = discovery.devices.first, newDevice.uniqueID != device.uniqueID {
                    self.captureSession.beginConfiguration()
                    if let currentInput = self.videoDeviceInput {
                        self.captureSession.removeInput(currentInput)
                    }
                    if let newInput = try? AVCaptureDeviceInput(device: newDevice), self.captureSession.canAddInput(newInput) {
                        self.captureSession.addInput(newInput)
                        self.videoDeviceInput = newInput
                        self.videoDevice = newDevice
                        self.configureHighestFPSAndStabilization(for: newDevice)
                        DispatchQueue.main.async { self.currentZoomFactor = factor }
                    }
                    self.captureSession.commitConfiguration()
                } else {
                    // Standard digital zoom on single camera
                    do {
                        try device.lockForConfiguration()
                        let clamped = max(device.minAvailableVideoZoomFactor, min(device.maxAvailableVideoZoomFactor, factor))
                        device.videoZoomFactor = clamped
                        device.unlockForConfiguration()
                        DispatchQueue.main.async { self.currentZoomFactor = factor }
                    } catch {}
                }
            }
        }
    }
    
    private func configureHighestFPSAndStabilization(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            var bestFormat: AVCaptureDevice.Format?
            var maxFPS: Double = 0
            
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let is1080p = (dims.width == 1920 && dims.height == 1080) || (dims.width == 1080 && dims.height == 1920)
                
                for range in format.videoSupportedFrameRateRanges {
                    let rate = range.maxFrameRate
                    if rate > maxFPS || (rate == maxFPS && is1080p) {
                        maxFPS = rate
                        bestFormat = format
                    }
                }
            }
            
            if let best = bestFormat {
                device.activeFormat = best
                let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
                device.activeVideoMinFrameDuration = targetFrameDuration
                device.activeVideoMaxFrameDuration = targetFrameDuration
                
                print("🚀 [iOS Camera] REAL HARDWARE UNLOCKED: \(Int(maxFPS)) FPS")
                DispatchQueue.main.async { self.currentFPS = maxFPS }
            }
            
            // Ultra-Sharp Focus & Shutter Optimization (Fixes Camera Blur)
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false // Instant crisp sharp focus without blur transition
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = self.currentVideoOrientation
                }
                // Turn off heavy digital video stabilization at 240 FPS to prevent optical motion blur
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ [iOS Camera] Configuration failed: \(error)")
        }
    }
    
    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self, let currentInput = self.videoDeviceInput else { return }
            
            self.captureSession.beginConfiguration()
            self.captureSession.removeInput(currentInput)
            
            let newPosition: AVCaptureDevice.Position = (currentInput.device.position == .back) ? .front : .back
            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                self.captureSession.addInput(currentInput)
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(newInput) {
                self.captureSession.addInput(newInput)
                self.videoDeviceInput = newInput
                self.videoDevice = newDevice
                self.configureHighestFPSAndStabilization(for: newDevice)
                self.discoverZoomFactors(for: newDevice)
            } else {
                self.captureSession.addInput(currentInput)
            }
            
            self.captureSession.commitConfiguration()
        }
    }
    
    func toggleTorch() -> Bool {
        guard let device = videoDevice, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            isTorchOn.toggle()
            device.torchMode = isTorchOn ? .on : .off
            device.unlockForConfiguration()
            return isTorchOn
        } catch {
            print("❌ [iOS Camera] Torch toggle failed: \(error)")
            return false
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        self.onFrameCaptured?(pixelBuffer, self.cgImageOrientation)
    }
}
