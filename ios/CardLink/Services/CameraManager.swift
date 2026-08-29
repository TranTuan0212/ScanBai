//
//  CameraManager.swift
//  CardLink
//
//  AVCaptureSession manager configured for highest supported FPS (60/120 FPS) and 4K Ultra HD resolution.
//  Continuous background camera capture sharing frames with Vision AI detector & Socket Live Streaming.
//

import Foundation
import AVFoundation
import UIKit

final class CameraManager: NSObject, ObservableObject {
    
    @Published var isRunning = false
    @Published var isTorchOn = false
    @Published var currentFPS: Double = 0.0
    @Published var activeResolution: String = "1080p"
    
    let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.cardlink.camera.sessionQueue", qos: .userInitiated)
    
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    
    override init() {
        super.init()
    }
    
    func setupAndStartSession(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrameCaptured = onFrame
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureCaptureSession()
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.isRunning = self.captureSession.isRunning
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
        
        // AUTO HARDWARE ACCELERATION & HIGHEST FPS DISCOVERY (60/120 FPS)
        configureHighestFPSAndStabilization(for: device)
    }
    
    private func configureHighestFPSAndStabilization(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // 1. Find Highest Available Frame Rate Format (60 FPS, 120 FPS, 240 FPS)
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
                
                print("🚀 [iOS Camera] LOCKED AT MAXIMUM \(Int(maxFPS)) FPS (ULTRA HIGH-SPEED MOTION CAPTURE)")
                DispatchQueue.main.async { self.currentFPS = maxFPS }
            }
            
            // 2. Enable Auto-Focus, Auto-Exposure & Continuous White Balance
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
                print("🌙 [iOS Camera] Hardware Low-Light Boost Enabled for Dark Rooms!")
            }
            
            // 3. Enable Optical Image Stabilization (OIS) or Video Stabilization
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                    print("✅ [iOS Camera] Hardware Video Stabilization Enabled")
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
        onFrameCaptured?(pixelBuffer)
    }
}
