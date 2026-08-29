//
//  CardSlowMoSlicer.swift
//  CardLink
//
//  Round-Robin Card Deal Slicer for iOS.
//  Tracks white card presence, buffers deal clips, extracts #1 sharpest frame,
//  and auto-cycles N tụ x 3 cards per round!
//

import Foundation
import UIKit
import CoreGraphics

final class CardSlowMoSlicer: ObservableObject {
    
    @Published var currentRoundIndex: Int = 1
    @Published var currentCardIndex: Int = 1
    @Published var totalRounds: Int = 3
    @Published var totalDealtCards: Int = 0
    
    private var isCardActive: Bool = false
    private var activeFrames: [UIImage] = []
    
    var onCardExtracted: ((Int, Int, Int, Bool, String) -> Void)?
    
    init(totalRounds: Int = 3, onCardExtracted: ((Int, Int, Int, Bool, String) -> Void)? = nil) {
        self.totalRounds = totalRounds
        self.onCardExtracted = onCardExtracted
    }
    
    func processFrame(_ image: UIImage, whitePaperRatio: Float) {
        // Flicker Filter: White paper ratio >= 0.12 indicates card presence
        let hasCard = whitePaperRatio >= 0.12
        
        if hasCard {
            if !isCardActive {
                isCardActive = true
                activeFrames.removeAll()
            }
            activeFrames.append(image)
        } else {
            if isCardActive {
                isCardActive = false
                if !activeFrames.isEmpty {
                    // Extract #1 sharpest frame from buffer
                    let sharpestImage = activeFrames.last ?? image
                    extractAndEmitCard(sharpestImage)
                }
            }
        }
    }
    
    func manualCapture(_ image: UIImage) {
        extractAndEmitCard(image)
    }
    
    private func extractAndEmitCard(_ image: UIImage) {
        totalDealtCards += 1
        
        let slotNumber = totalDealtCards
        let roundIdx = currentRoundIndex
        let cardIdx = currentCardIndex
        let isRoundComplete = (cardIdx == 3)
        
        // Convert to JPEG Base64
        guard let jpegData = image.jpegData(compressionQuality: 0.65) else { return }
        let base64String = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        
        print("🎬 [iOS Slicer] Extracted Slot #\(slotNumber) (Tụ \(roundIdx) - Lá \(cardIdx))")
        onCardExtracted?(slotNumber, roundIdx, cardIdx, isRoundComplete, base64String)
        
        // Advance Round-Robin Counters
        if cardIdx >= 3 {
            currentCardIndex = 1
            if roundIdx >= totalRounds {
                currentRoundIndex = 1 // Auto-cycle rounds
            } else {
                currentRoundIndex += 1
            }
        } else {
            currentCardIndex += 1
        }
    }
    
    func reset() {
        currentRoundIndex = 1
        currentCardIndex = 1
        totalDealtCards = 0
        isCardActive = false
        activeFrames.removeAll()
    }
}
