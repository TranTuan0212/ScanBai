//
//  FakeLockScreenView.swift
//  CardLink
//
//  STEALTH FAKE LOCK SCREEN (Màn Hình Khóa Giả & Tối Màn Hóa Trang)
//  1. Dims screen brightness to 0.0 (dark black screen).
//  2. Renders realistic iOS Lock Screen standby UI with digital clock & status.
//  3. Keeps Camera capture, AI card vision analysis, and Socket streaming 100% ACTIVE in the background!
//  4. Double-Tap or Swipe-Up gesture to unlock and restore brightness.
//

import SwiftUI
import UIKit

struct FakeLockScreenView: View {
    @Binding var isLocked: Bool
    
    @State private var currentTime = Date()
    @State private var originalBrightness: CGFloat = 0.5
    @State private var timer: Timer?
    @State private var unlockPasscodeCode = ""
    @State private var showPasscodePrompt = false
    
    var body: some View {
        ZStack {
            // Ultra-dark stealth background
            Color.black
                .ignoresSafeArea()
            
            VStack {
                // Top Status Header (Lock Icon & Security Notice)
                HStack {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("Đã Khóa Bảo Vệ")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.top, 40)
                
                Spacer()
                    .frame(height: 30)
                
                // Big iOS Digital Clock
                Text(timeString(from: currentTime))
                    .font(.system(size: 82, weight: .thin, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                
                // Date Subtitle
                Text(dateString(from: currentTime))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                
                Spacer()
                
                // Stealth Status Indicator (Confirms AI & Camera are running background live!)
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    Text("LIVE & AI CAMERA ACTIVE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.green.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.6)))

                Spacer()
                
                // Bottom Quick Action Buttons & Unlock Instruction
                VStack(spacing: 16) {
                    Text("Vuốt lên hoặc chạm 2 lần để mở khóa")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                    
                    HStack {
                        // Flashlight Icon
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Image(systemName: "flashlight.off.fill")
                                    .foregroundColor(.white.opacity(0.7))
                            )
                        
                        Spacer()
                        
                        // Camera Icon
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 50, height: 50)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .foregroundColor(.white.opacity(0.7))
                            )
                    }
                    .padding(.horizontal, 46)
                    
                    // Home Bar Line
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 134, height: 5)
                        .padding(.bottom, 8)
                }
            }
        }
        .onAppear {
            // 1. Store original brightness & dim screen to 0.01 (ultra stealth & zero battery drain)
            originalBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.01
            UIApplication.shared.isIdleTimerDisabled = true
            
            // 2. Start clock timer
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                currentTime = Date()
            }
        }
        .onDisappear {
            // Restore original screen brightness and re-enable idle timer
            UIScreen.main.brightness = originalBrightness
            UIApplication.shared.isIdleTimerDisabled = false
            timer?.invalidate()
        }
        // Double-Tap Gesture to Unlock
        .onTapGesture(count: 2) {
            unlockScreen()
        }
        // Swipe Up Gesture to Unlock
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height < -50 {
                        unlockScreen()
                    }
                }
        )
    }
    
    private func unlockScreen() {
        UIScreen.main.brightness = originalBrightness
        withAnimation(.easeOut(duration: 0.25)) {
            isLocked = false
        }
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date).capitalized
    }
}
