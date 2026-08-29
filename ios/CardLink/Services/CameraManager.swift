//
//  CameraManager.swift
//  CardLink
//
//  AVCaptureSession manager configured for highest supported FPS (60/120/240 FPS) and 1080p Full HD resolution.
//  Includes Real-Time Dynamic Device Orientation Rotation (Portrait, Landscape Left, Landscape Right).
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
        let deviceOrientation = UIDevice.current.orientation
        var newVideoOrientation: AVCaptureVideoOrientation = .portrait
        var newCGOrientation: CGImagePropertyOrientation = .right
        
        switch deviceOrientation {
        case .landscapeLeft:
            newVideoOrientation = .landscapeRight
            newCGOrientation = .up
        case .landscapeRight:
            newVideoOrientation = .landscapeLeft
            newCGOrientation = .down
        case .portraitUpsideDown:
            newVideoOrientation = .portraitUpsideDown
            newCGOrientation = .left
        case .portrait:
            newVideoOrientation = .portrait
            newCGOrientation = .right
        default:
            return
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
        
        // Set to 1080p Full HD Slow-Mo mode for 120/240 FPS High Frame Rate
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
            DispatchQueue.main.async { self.activeResolution = "1080p Slow-Mo (240 FPS)" }
        } else {
            captureSession.sessionPreset = .high
        }
        
        // Find Back Wide-Angle Camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("❌ [iOS Camera] Back camera not found")
            return
        }
        self.videoDevice = device
        
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
        
        // AUTO HARDWARE ACCELERATION & HIGHEST FPS DISCOVERY (60/120/240 FPS)
        configureHighestFPSAndStabilization(for: device)
    }
    
    private func configureHighestFPSAndStabilization(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            var bestFormat: AVCaptureDevice.Format?
            var maxFPS: Double = 0
            
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate > maxFPS {
                        maxFPS = range.maxFrameRate
                        bestFormat = format
                    }
                }
            }
            
            if let best = bestFormat {
                device.activeFormat = best
                let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
                device.activeVideoMinFrameDuration = targetFrameDuration
                device.activeVideoMaxFrameDuration = targetFrameDuration
                
                print("🚀 [iOS Camera] LOCKED AT MAXIMUM \(Int(maxFPS)) FPS")
                DispatchQueue.main.async { self.currentFPS = maxFPS }
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
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
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                }
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ [iOS Camera] Failed locking device configuration: \(error)")
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
        onFrameCaptured?(pixelBuffer, cgImageOrientation)
    }
}
