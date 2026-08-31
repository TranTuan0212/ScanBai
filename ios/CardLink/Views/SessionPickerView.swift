//
//  SessionPickerView.swift
//  CardLink
//
//  Select / Start Live Session Screen matching Android version 100%.
//

import SwiftUI

struct SessionPickerView: View {
    @Binding var navigationState: NavigationState
    @Binding var activeSessionId: String
    
    @State private var sessionTitle = "Phiên Bàn Live #1"
    @State private var totalRounds = 3
    @State private var showVideoTestModal = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 8) {
                    Image(systemName: "video.fill.badge.plus")
                        .font(.system(size: 56))
                        .foregroundColor(.yellow)
                    
                    Text("KHỞI TẠO LUỒNG PHÁT SÓNG")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    Text("Cấu hình thiết bị camera & luồng phân tích")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tên phiên làm việc")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        
                        TextField("Tên phiên", text: $sessionTitle)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Số nhóm phân tích (Default: 3 nhóm)")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        
                        Picker("Số nhóm", selection: $totalRounds) {
                            Text("2 Nhóm").tag(2)
                            Text("3 Nhóm (Chuẩn)").tag(3)
                            Text("4 Nhóm").tag(4)
                            Text("5 Nhóm").tag(5)
                        }
                        .pickerStyle(.segmented)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 32)
                
                Button(action: startBroadcast) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                        Text("BẮT ĐẦU LIVE BROADCAST")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.yellow)
                    .cornerRadius(12)
                    .shadow(color: .yellow.opacity(0.4), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal, 32)
                
                // Offline Video Test Button
                Button(action: { showVideoTestModal = true }) {
                    HStack {
                        Image(systemName: "film.stack.fill")
                            .font(.title3)
                        Text("🧪 TEST VIDEO THỰC TẾ (TỪ THƯ VIỆN)")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow, lineWidth: 1))
                }
                .padding(.horizontal, 32)
                .sheet(isPresented: $showVideoTestModal) {
                    VideoTestView()
                }
                
                Spacer()
            }
        }
    }
    
    private func startBroadcast() {
        let generatedId = "LIVE_\(Int(Date().timeIntervalSince1970))"
        self.activeSessionId = generatedId
        self.navigationState = .live
    }
}
