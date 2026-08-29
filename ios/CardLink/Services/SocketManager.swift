//
//  SocketManager.swift
//  CardLink
//
//  Socket.IO v4 Compliant Client for iOS.
//  Handles Engine.IO handshake (packet 0 -> 40), automatic room joining,
//  real-time live_frame streaming, and card_detected event emissions.
//

import Foundation
import UIKit

final class iOSSocketManager: ObservableObject {
    static let shared = iOSSocketManager()
    
    @Published var isConnected = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var serverIP: String = "192.168.1.3"
    private var pendingSessionId: String?
    private var pingTimer: Timer?
    
    private init() {}
    
    func setServerIP(_ ip: String) {
        let cleanIp = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIp.isEmpty {
            self.serverIP = cleanIp
        }
    }
    
    func connect(token: String = "") {
        disconnect()
        
        var wsUrlString = "ws://\(serverIP):3000/socket.io/?EIO=4&transport=websocket"
        if !token.isEmpty {
            wsUrlString += "&token=\(token)"
        }
        guard let url = URL(string: wsUrlString) else { return }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        print("🔌 [iOS Socket] Connecting to server: \(wsUrlString)")
        
        // Send Socket.IO v4 Connect Packet
        sendRaw("40")
        listenForMessages()
        startPingTimer()
        
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }
    
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingPacket(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingPacket(text)
                    }
                @unknown default:
                    break
                }
                self.listenForMessages()
            case .failure(let error):
                print("❌ [iOS Socket] Receive error: \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                }
            }
        }
    }
    
    private func handleIncomingPacket(_ text: String) {
        if text.startsWith("0") {
            // Engine.IO Open Packet -> Send Socket.IO Connect
            sendRaw("40")
            if let session = pendingSessionId {
                joinRoom(sessionId: session)
            }
        } else if text.startsWith("2") {
            // Engine.IO Ping -> Send Pong
            sendRaw("3")
        } else if text.startsWith("40") {
            print("✅ [iOS Socket] Handshake complete!")
            if let session = pendingSessionId {
                joinRoom(sessionId: session)
            }
        }
    }
    
    func joinRoom(sessionId: String) {
        self.pendingSessionId = sessionId
        let payload = "42[\"join_room\",{\"sessionId\":\"\(sessionId)\"}]"
        sendRaw(payload)
        print("🚪 [iOS Socket] Joined Room: \(sessionId)")
    }
    
    func sendCardDetected(sessionId: String, label: String, imageBase64: String) {
        let jsonPayload = """
        42["card_detected",{"sessionId":"\(sessionId)","label":"\(label)","imageBase64":"\(imageBase64)"}]
        """
        sendRaw(jsonPayload)
        print("📤 [iOS Socket] Sent card_detected: \(label)")
    }
    
    func sendLiveFrame(sessionId: String, dataUri: String) {
        let jsonPayload = """
        42["live_frame",{"sessionId":"\(sessionId)","frame":"\(dataUri)"}]
        """
        sendRaw(jsonPayload)
    }
    
    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.sendRaw("2") // Engine.IO Ping
        }
    }
    
    private func sendRaw(_ message: String) {
        webSocketTask?.send(.string(message)) { error in
            if let error = error {
                print("❌ [iOS Socket] Send error: \(error)")
            }
        }
    }
    
    func disconnect() {
        pingTimer?.invalidate()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
        print("🔴 [iOS Socket] Disconnected")
    }
}

private extension String {
    func startsWith(_ prefix: String) -> Bool {
        return self.hasPrefix(prefix)
    }
}
