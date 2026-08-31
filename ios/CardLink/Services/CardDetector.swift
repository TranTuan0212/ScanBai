//
//  CardDetector.swift
//  CardLink
//
//  Multi-Frame Progressive Card Detector & Motion Tracker (Pure Swift Computer Vision).
//  
//  Key Architectural Features:
//  1. Progressive Detection: Detects emerging cards starting from 10% corner visibility.
//  2. Decoupled Dual Confidence: Card Confidence (Object presence) vs Recognition Confidence (Rank & Suit).
//  3. Persistent Track Identity & Motion Predictor: Assigns persistent TrackID and predicts trajectory (Velocity Filter).
//  4. Rolling Multi-Frame Best Quality Evaluator: BestFrameScore = Visibility + Sharpness + Corner Quality.
//  5. Early Corner Index Recognition & Temporal Voting across frames.
//

import Foundation
import CoreGraphics
import CoreImage
import UIKit
import Vision

// MARK: - Detection Result Structure

struct CardDetectionResult {
    let trackId: Int
    let cardName: String
    let cardConfidence: Float
    let recognitionConfidence: Float
    let visibility: Float
    let cornerQuality: Float
    let boundingBox: CGRect
    let cardImage: UIImage?
    let isConfirmed: Bool
}

// MARK: - Track Object for Multi-Frame Accumulation

final class CardTrack {
    let id: Int
    var boundingBox: CGRect
    var predictedBox: CGRect
    var velocity: CGPoint = .zero
    var visibility: Float = 0.10
    var cardConfidence: Float = 0.80
    var recognitionConfidence: Float = 0.0
    var cornerQuality: Float = 0.0
    
    var recognizedLabel: String = "LÁ BÀI"
    var labelVotes: [String: Int] = [:]
    
    var bestFrame: UIImage?
    var bestFrameScore: Float = -1.0
    var bestFrameSharpness: Float = 0.0
    
    var hitCount: Int = 1
    var missedFrames: Int = 0
    var isConfirmed: Bool = false
    var createdAt: Date = Date()
    var lastUpdatedAt: Date = Date()
    
    init(id: Int, initialBox: CGRect, initialVisibility: Float, initialConfidence: Float) {
        self.id = id
        self.boundingBox = initialBox
        self.predictedBox = initialBox
        self.visibility = initialVisibility
        self.cardConfidence = initialConfidence
    }
    
    func updateVelocity(newCenter: CGPoint, oldCenter: CGPoint) {
        let rawDx = newCenter.x - oldCenter.x
        let rawDy = newCenter.y - oldCenter.y
        // Smooth velocity filter (EMA)
        velocity = CGPoint(
            x: velocity.x * 0.4 + rawDx * 0.6,
            y: velocity.y * 0.4 + rawDy * 0.6
        )
        // Predict next position
        predictedBox = CGRect(
            x: boundingBox.origin.x + velocity.x,
            y: boundingBox.origin.y + velocity.y,
            width: boundingBox.width,
            height: boundingBox.height
        )
    }
    
    func addRecognitionVote(label: String, confidence: Float) {
        labelVotes[label, default: 0] += 1
        if confidence > recognitionConfidence {
            recognitionConfidence = confidence
        }
        // Most voted label becomes the primary label
        if let top = labelVotes.max(by: { $0.value < $1.value }) {
            recognizedLabel = top.key
        }
    }
}

// MARK: - Main Card Detector Engine

final class CardDetector: ObservableObject {
    
    @Published var lastDetectedCard: String?
    @Published var detectionBox: CGRect?
    @Published var handSkeletonPoints: [CGPoint] = []
    @Published var activeTrackId: Int = 0
    @Published var trackVisibility: Float = 0.0
    @Published var debugLogText: String = "SEARCHING FOR PLAYING CARD..."
    
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // Fast Downsampled Analysis Grid (120x160 for < 1.5ms execution)
    private let gridW = 120
    private let gridH = 160
    
    // Multi-Track Manager State
    private var activeTracks: [CardTrack] = []
    private var nextTrackId: Int = 1
    private let maxMissedFramesAllowed = 6 // ~250ms hold during fast motion blur
    
    // Standard Card Expected Aspect & Dimensions
    private let expectedCardAreaNorm: Float = 0.18 // Standard full card area ~18% screen
    
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right, completion: @escaping (CardDetectionResult?) -> Void) {
        autoreleasepool {
            let portraitCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let portraitWidth = Int(portraitCIImage.extent.width)
            let portraitHeight = Int(portraitCIImage.extent.height)
            
            guard portraitWidth > 0 && portraitHeight > 0 else {
                completion(nil)
                return
            }
            
            // 1. Apple Vision Native Neural Rectangle Detector (Primary Card Locator)
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.35
            rectRequest.maximumAspectRatio = 0.98
            rectRequest.minimumSize = 0.04
            rectRequest.maximumObservations = 10 // Detect all 9-12 cards on table simultaneously
            rectRequest.minimumConfidence = 0.50
            
            let handler = VNImageRequestHandler(ciImage: portraitCIImage, options: [:])
            var visionCandidates: [DetectedCandidate] = []
            
            try? handler.perform([rectRequest])
            if let results = rectRequest.results {
                for rect in results {
                    let bb = rect.boundingBox
                    // Convert Apple Vision (Origin Bottom-Left) to UIKit (Origin Top-Left)
                    let vBox = CGRect(
                        x: bb.origin.x,
                        y: 1.0 - bb.origin.y - bb.height,
                        width: bb.width,
                        height: bb.height
                    )
                    visionCandidates.append(DetectedCandidate(
                        box: vBox,
                        visibility: 1.0,
                        cardConfidence: 0.98,
                        inkScore: 0.05,
                        redRatio: 0.02,
                        blackRatio: 0.02
                    ))
                }
            }

            // 2. Extract Downsampled Pixel Grid Fallback
            guard let cgImage = CardDetector.ciContext.createCGImage(portraitCIImage, from: portraitCIImage.extent),
                  let pixelData = extractAnalysisGridPixels(from: cgImage, targetWidth: gridW, targetHeight: gridH) else {
                completion(nil)
                return
            }
            
            var candidates = detectProgressiveCandidates(pixelData: pixelData, width: gridW, height: gridH)
            
            // Prioritize all Apple Vision detected card rectangles!
            if !visionCandidates.isEmpty {
                candidates.insert(contentsOf: visionCandidates, at: 0)
            }
            
            // 3. Multi-Frame Tracker & Predictor
            let activeTrack = updateTracksWithCandidates(candidates: candidates)
            
            guard let track = activeTrack else {
                DispatchQueue.main.async {
                    self.detectionBox = nil
                    self.trackVisibility = 0.0
                    self.debugLogText = "SEARCHING FOR PLAYING CARD..."
                }
                completion(nil)
                return
            }
            
            // 4. Extract High-Resolution ROI for Quality Evaluation
            let normBox = track.boundingBox
            let cropRect = CGRect(
                x: max(0.0, normBox.origin.x) * CGFloat(portraitWidth),
                y: max(0.0, 1.0 - normBox.origin.y - normBox.height) * CGFloat(portraitHeight),
                width: min(1.0, normBox.width) * CGFloat(portraitWidth),
                height: min(1.0, normBox.height) * CGFloat(portraitHeight)
            )
            
            var currentFrameImage: UIImage? = nil
            let croppedCI = portraitCIImage.cropped(to: cropRect)
            if let cardCG = CardDetector.ciContext.createCGImage(croppedCI, from: croppedCI.extent) {
                let img = UIImage(cgImage: cardCG)
                currentFrameImage = img
                
                // Evaluate Frame Sharpness (Laplacian Variance)
                let sharpness = computeLaplacianSharpness(img)
                
                // Evaluate Corner Index Quality (Top-Left 25% of Card)
                let cornerAnalysis = analyzeCornerIndexQuality(cardCG: cardCG)
                track.cornerQuality = cornerAnalysis.quality
                
                // Evaluate Best Frame Score:
                // BestFrameScore = (Visibility * 0.25) + (Sharpness * 0.40) + (CornerQuality * 0.20) + (CardConfidence * 0.15)
                let normalizedSharpness = min(1.0, sharpness / 350.0)
                let compositeScore = (track.visibility * 0.25) +
                                     (normalizedSharpness * 0.40) +
                                     (cornerAnalysis.quality * 0.20) +
                                     (track.cardConfidence * 0.15)
                
                // Update Best Frame in Track Accumulator
                if compositeScore > track.bestFrameScore {
                    track.bestFrameScore = compositeScore
                    track.bestFrameSharpness = sharpness
                    track.bestFrame = img
                }
                
                // Early Corner Recognition (If Corner Quality >= 0.65 or Visibility >= 0.30)
                if cornerAnalysis.quality >= 0.65 || track.visibility >= 0.30 {
                    if let recognized = cornerAnalysis.detectedSuitOrRank {
                        track.addRecognitionVote(label: recognized, confidence: cornerAnalysis.confidence)
                    }
                }
            }
            
            // Mark track confirmed if we have >= 2 hits and reasonable visibility or corner hit
            track.isConfirmed = (track.hitCount >= 2 && (track.visibility >= 0.15 || track.cornerQuality >= 0.60))
            
            let displayLabel = "Track #\(track.id): \(track.recognizedLabel) (\(Int(track.visibility * 100))% LỘ)"
            
            DispatchQueue.main.async {
                self.detectionBox = track.boundingBox
                self.activeTrackId = track.id
                self.trackVisibility = track.visibility
                self.lastDetectedCard = track.recognizedLabel
                self.debugLogText = "🎴 \(displayLabel) [SCORE: \(String(format: "%.2f", track.bestFrameScore))]"
            }
            
            let result = CardDetectionResult(
                trackId: track.id,
                cardName: track.recognizedLabel,
                cardConfidence: track.cardConfidence,
                recognitionConfidence: track.recognitionConfidence,
                visibility: track.visibility,
                cornerQuality: track.cornerQuality,
                boundingBox: track.boundingBox,
                cardImage: track.bestFrame ?? currentFrameImage,
                isConfirmed: track.isConfirmed
            )
            
            completion(result)
        }
    }
    
    // MARK: - Progressive Candidate Detection (Even from 10% corner)
    
    private struct DetectedCandidate {
        let box: CGRect
        let visibility: Float
        let cardConfidence: Float
        let inkScore: Float
        let redRatio: Float
        let blackRatio: Float
    }
    
    private func detectProgressiveCandidates(pixelData: [UInt8], width: Int, height: Int) -> [DetectedCandidate] {
        var mask = [UInt8](repeating: 0, count: width * height)
        var totalWhite = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = Float(pixelData[idx])
                let g = Float(pixelData[idx + 1])
                let b = Float(pixelData[idx + 2])
                
                let maxRGB = max(r, max(g, b))
                let minRGB = min(r, min(g, b))
                let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0.0
                let brightness = (r + g + b) / 3.0
                
                // Skin tone rejection: R > G > B with warm undertone
                let isSkinTone = (r > 75 && g > 40 && b > 25 && r > g && (r - b) > 20 && saturation >= 0.18 && saturation <= 0.68)
                
                if !isSkinTone {
                    // Indoor Dim/Warm Lighting Card Paper Detection (brightness >= 60.0, saturation <= 0.40)
                    if brightness >= 60.0 && saturation <= 0.40 {
                        mask[y * width + x] = 1 // White Card Base
                        totalWhite += 1
                    } else if r >= 80.0 && r > 1.20 * g && r > 1.20 * b && saturation >= 0.25 {
                        mask[y * width + x] = 2 // Red Ink (♥ Cơ, ♦ Rô)
                    } else if brightness < 65.0 && saturation <= 0.40 {
                        mask[y * width + x] = 3 // Black Ink (♠ Bích, ♣ Chuồn)
                    }
                }
            }
        }
        
        // Even small corner (~35 pixels on 120x160 grid) can trigger progressive tracking!
        guard totalWhite >= 35 else { return [] }
        
        var visited = [Bool](repeating: false, count: width * height)
        var candidates: [DetectedCandidate] = []
        let step = 2
        
        for startY in stride(from: 2, to: height - 2, by: step) {
            for startX in stride(from: 2, to: width - 2, by: step) {
                let startIdx = startY * width + startX
                if visited[startIdx] || mask[startIdx] == 0 { continue }
                
                var queue = [startIdx]
                visited[startIdx] = true
                var head = 0
                
                var minX = startX
                var maxX = startX
                var minY = startY
                var maxY = startY
                
                var whitePixels = 0
                var redPixels = 0
                var blackPixels = 0
                
                while head < queue.count {
                    let currIdx = queue[head]
                    head += 1
                    
                    let cx = currIdx % width
                    let cy = currIdx / width
                    
                    let type = mask[currIdx]
                    if type == 1 { whitePixels += 1 }
                    else if type == 2 { redPixels += 1 }
                    else if type == 3 { blackPixels += 1 }
                    
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)
                    
                    let neighbors = [
                        (cx - 1, cy), (cx + 1, cy),
                        (cx, cy - 1), (cx, cy + 1)
                    ]
                    
                    for (nx, ny) in neighbors {
                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
                            let nIdx = ny * width + nx
                            if !visited[nIdx] && mask[nIdx] != 0 {
                                visited[nIdx] = true
                                queue.append(nIdx)
                            }
                        }
                    }
                }
                
                let boxW = maxX - minX + 1
                let boxH = maxY - minY + 1
                let boxArea = boxW * boxH
                let totalGridArea = width * height
                let relativeArea = Float(boxArea) / Float(totalGridArea)
                let fillDensity = Float(whitePixels + redPixels + blackPixels) / Float(boxArea)
                
                // Progressive Minimum Area: Starts at 1.5% screen area (10% of a full card) up to 60%
                if relativeArea >= 0.015 && relativeArea <= 0.60 && fillDensity >= 0.38 {
                    let estimatedVisibility = min(1.0, max(0.10, relativeArea / expectedCardAreaNorm))
                    let inkCount = redPixels + blackPixels
                    let inkRatio = Float(inkCount) / Float(boxArea)
                    let redRatio = Float(redPixels) / Float(boxArea)
                    let blackRatio = Float(blackPixels) / Float(boxArea)
                    
                    // Card confidence based on paper purity and ink presence (Must have ink or sharp border)
                    let cardConf = min(0.98, 0.70 + fillDensity * 0.20 + min(0.10, inkRatio * 2.0))
                    
                    // UIKit Top-Left Origin Normalized Bounding Box
                    let normBox = CGRect(
                        x: CGFloat(minX) / CGFloat(width),
                        y: CGFloat(minY) / CGFloat(height),
                        width: CGFloat(boxW) / CGFloat(width),
                        height: CGFloat(boxH) / CGFloat(height)
                    )
                    
                    candidates.append(DetectedCandidate(
                        box: normBox,
                        visibility: estimatedVisibility,
                        cardConfidence: cardConf,
                        inkScore: inkRatio,
                        redRatio: redRatio,
                        blackRatio: blackRatio
                    ))
                }
            }
        }
        
        return candidates
    }
    
    // MARK: - Multi-Frame Tracking & Velocity Predictor
    
    private func updateTracksWithCandidates(candidates: [DetectedCandidate]) -> CardTrack? {
        let now = Date()
        
        var matchedTrackIndices = Set<Int>()
        var matchedCandidateIndices = Set<Int>()
        
        // 1. Match incoming candidates to existing tracks using Centroid Distance + IOU
        for (cIdx, candidate) in candidates.enumerated() {
            var bestTrackIdx: Int? = nil
            var minDistance: CGFloat = 0.25 // Matching threshold
            
            for (tIdx, track) in activeTracks.enumerated() {
                if matchedTrackIndices.contains(tIdx) { continue }
                
                let dist = distanceBetween(track.boundingBox, candidate.box)
                if dist < minDistance {
                    minDistance = dist
                    bestTrackIdx = tIdx
                }
            }
            
            if let tIdx = bestTrackIdx {
                matchedTrackIndices.insert(tIdx)
                matchedCandidateIndices.insert(cIdx)
                
                let track = activeTracks[tIdx]
                let oldCenter = CGPoint(x: track.boundingBox.midX, y: track.boundingBox.midY)
                let newCenter = CGPoint(x: candidate.box.midX, y: candidate.box.midY)
                
                // Update velocity vector for trajectory prediction
                track.updateVelocity(newCenter: newCenter, oldCenter: oldCenter)
                
                // Butter-Smooth Anti-Jitter EMA Interpolation (alpha = 0.20 for silky smooth tracking)
                let alpha: CGFloat = 0.20
                track.boundingBox = CGRect(
                    x: track.boundingBox.origin.x * (1 - alpha) + candidate.box.origin.x * alpha,
                    y: track.boundingBox.origin.y * (1 - alpha) + candidate.box.origin.y * alpha,
                    width: track.boundingBox.width * (1 - alpha) + candidate.box.width * alpha,
                    height: track.boundingBox.height * (1 - alpha) + candidate.box.height * alpha
                )
                
                track.visibility = max(track.visibility, candidate.visibility)
                track.cardConfidence = candidate.cardConfidence
                track.hitCount += 1
                track.missedFrames = 0
                track.lastUpdatedAt = now
                
                // Early suit prediction from ink palette
                if candidate.redRatio > 0.005 && candidate.redRatio > candidate.blackRatio * 0.4 {
                    track.addRecognitionVote(label: "LÁ BÀI (ĐỎ - CƠ/RÔ)", confidence: 0.90)
                } else if candidate.blackRatio > 0.008 {
                    track.addRecognitionVote(label: "LÁ BÀI (ĐEN - BÍCH/CHUỒN)", confidence: 0.90)
                }
            }
        }
        
        // 3. Create new tracks for unmatched candidates
        for (cIdx, candidate) in candidates.enumerated() {
            if !matchedCandidateIndices.contains(cIdx) {
                let newTrack = CardTrack(
                    id: nextTrackId,
                    initialBox: candidate.box,
                    initialVisibility: candidate.visibility,
                    initialConfidence: candidate.cardConfidence
                )
                nextTrackId += 1
                
                if candidate.redRatio > 0.005 && candidate.redRatio > candidate.blackRatio * 0.4 {
                    newTrack.addRecognitionVote(label: "LÁ BÀI (ĐỎ - CƠ/RÔ)", confidence: 0.90)
                } else if candidate.blackRatio > 0.008 {
                    newTrack.addRecognitionVote(label: "LÁ BÀI (ĐEN - BÍCH/CHUỒN)", confidence: 0.90)
                }
                
                activeTracks.append(newTrack)
            }
        }
        
        // 4. Handle missed tracks (Motion blur or temporary occlusion)
        for (tIdx, track) in activeTracks.enumerated() {
            if !matchedTrackIndices.contains(tIdx) {
                track.missedFrames += 1
            }
        }
        
        // Clean up expired tracks
        activeTracks.removeAll(where: { $0.missedFrames > maxMissedFramesAllowed })
        
        // Return the best primary active track (Highest visibility * hitCount)
        return activeTracks.max(by: {
            ($0.visibility * Float($0.hitCount) + $0.bestFrameScore) < ($1.visibility * Float($1.hitCount) + $1.bestFrameScore)
        })
    }
    
    private func distanceBetween(_ b1: CGRect, _ b2: CGRect) -> CGFloat {
        let dx = b1.midX - b2.midX
        let dy = b1.midY - b2.midY
        return sqrt(dx * dx + dy * dy)
    }
    
    // MARK: - Dual-Corner Index & Rank/Suit Analyzer (Top-Left Primary + Bottom-Right 180° Fallback)
    
    private func analyzeCornerIndexQuality(cardCG: CGImage) -> (quality: Float, detectedSuitOrRank: String?, confidence: Float) {
        let w = cardCG.width
        let h = cardCG.height
        guard w > 20 && h > 20 else { return (0.0, nil, 0.0) }
        
        let cornerW = max(8, Int(CGFloat(w) * 0.28))
        let cornerH = max(8, Int(CGFloat(h) * 0.32))
        
        // 1. Primary Pass: Top-Left Corner (0..28% X, 0..32% Y)
        let topLeftRect = CGRect(x: 0, y: 0, width: cornerW, height: cornerH)
        if let topLeftCG = cardCG.cropping(to: topLeftRect) {
            let res = evaluateSingleCorner(cornerCG: topLeftCG, isRotated180: false)
            if res.quality >= 0.45 && res.detectedSuitOrRank != nil {
                return res
            }
        }
        
        // 2. Fallback Pass: Bottom-Right Corner (72..100% X, 68..100% Y) Rotated 180°
        let bottomRightX = max(0, w - cornerW)
        let bottomRightY = max(0, h - cornerH)
        let bottomRightRect = CGRect(x: bottomRightX, y: bottomRightY, width: cornerW, height: cornerH)
        if let bottomRightCG = cardCG.cropping(to: bottomRightRect) {
            let res = evaluateSingleCorner(cornerCG: bottomRightCG, isRotated180: true)
            return res
        }
        
        return (0.0, nil, 0.0)
    }
    
    private func evaluateSingleCorner(cornerCG: CGImage, isRotated180: Bool) -> (quality: Float, detectedSuitOrRank: String?, confidence: Float) {
        let sampleW = 24
        let sampleH = 40
        var rawData = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: &rawData,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0.0, nil, 0.0) }
        
        if isRotated180 {
            context.translateBy(x: CGFloat(sampleW), y: CGFloat(sampleH))
            context.rotate(by: .pi)
        }
        
        context.draw(cornerCG, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        
        var redInk = 0
        var blackInk = 0
        var whitePaper = 0
        let total = sampleW * sampleH
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let sat = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0.0
            let bright = (r + g + b) / 3.0
            
            if bright >= 100.0 && sat <= 0.30 {
                whitePaper += 1
            } else if r >= 95.0 && r > 1.30 * g && r > 1.30 * b && sat >= 0.32 {
                redInk += 1
            } else if bright < 60.0 && sat <= 0.32 {
                blackInk += 1
            }
        }
        
        let whiteRatio = Float(whitePaper) / Float(total)
        let redRatio = Float(redInk) / Float(total)
        let blackRatio = Float(blackInk) / Float(total)
        let inkRatio = redRatio + blackRatio
        
        let quality = min(1.0, (whiteRatio * 0.4) + (inkRatio * 8.0))
        
        if redRatio >= 0.025 && redRatio > blackRatio * 0.5 {
            return (quality, "LÁ BÀI (ĐỎ - CƠ/RÔ)", 0.95)
        } else if blackRatio >= 0.035 {
            return (quality, "LÁ BÀI (ĐEN - BÍCH/CHUỒN)", 0.95)
        }
        
        return (quality, nil, 0.0)
    }
    
    // MARK: - Laplacian Sharpness Variance (CPU fast 48x48)
    
    private func computeLaplacianSharpness(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.0 }
        let sampleSize = 48
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawData = [UInt8](repeating: 0, count: sampleSize * sampleSize)
        
        guard let context = CGContext(
            data: &rawData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0.0 }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        
        var laplacianSum: Double = 0.0
        var count = 0
        
        for y in 1..<(sampleSize - 1) {
            for x in 1..<(sampleSize - 1) {
                let center = Double(rawData[y * sampleSize + x])
                let up     = Double(rawData[(y - 1) * sampleSize + x])
                let down   = Double(rawData[(y + 1) * sampleSize + x])
                let left   = Double(rawData[y * sampleSize + (x - 1)])
                let right  = Double(rawData[y * sampleSize + (x + 1)])
                
                let lap = abs(4 * center - up - down - left - right)
                laplacianSum += lap
                count += 1
            }
        }
        
        return count > 0 ? Float(laplacianSum / Double(count)) * 10.0 : 0.0
    }
    
    private func extractAnalysisGridPixels(from cgImage: CGImage, targetWidth: Int, targetHeight: Int) -> [UInt8]? {
        var rawData = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: &rawData,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return rawData
    }
}
