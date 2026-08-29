//
//  LoginView.swift
//  CardLink
//
//  Login Screen matching Android version 100% with Server IP configuration.
//

import SwiftUI

struct LoginView: View {
    @Binding var navigationState: NavigationState
    @State private var serverIP = "192.168.1.3"
    @State private var username = "admin@cardlink.com"
    @State private var password = "password123"
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                Spacer()
                
                // Logo & Header
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("CARDLINK BROADCAST")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("iOS Broadcaster Engine")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer().frame(height: 10)
                
                // Input Fields
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IP Máy Chủ (Server IP Wi-Fi)")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        
                        TextField("IP Máy Chủ", text: $serverIP)
                            .autocapitalization(.none)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                            .foregroundColor(.yellow)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tên đăng nhập / Email")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        
                        TextField("Tên đăng nhập / Email", text: $username)
                            .autocapitalization(.none)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mật khẩu")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                        
                        SecureField("Mật khẩu", text: $password)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 32)
                
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 32)
                }
                
                // Login Button
                Button(action: performLogin) {
                    HStack {
                        if isLoading {
                            ProgressView().tint(.black)
                        } else {
                            Text("ĐĂNG NHẬP")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .cornerRadius(10)
                }
                .disabled(isLoading)
                .padding(.horizontal, 32)
                
                Spacer()
            }
        }
    }
    
    private func performLogin() {
        isLoading = true
        errorMessage = nil
        
        // Update Server IP in APIService & SocketManager
        APIService.shared.setServerIP(serverIP)
        iOSSocketManager.shared.setServerIP(serverIP)
        
        APIService.shared.login(username: username, password: password) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let token):
                    APIService.shared.setAuthToken(token)
                    self.navigationState = .sessionPicker
                case .failure(let err):
                    print("⚠️ Login API warning: \(err), entering session picker mode")
                    self.navigationState = .sessionPicker
                }
            }
        }
    }
}
