//
//  SocketManager.swift
//  CardLink
//
//  Socket.IO v4 Compliant Client for iOS.
//  Handles Engine.IO handshake (packet 0 -> 40 -> 40 ack), automatic room joining,
//  real-time live_frame streaming, and card_detected event emissions.
//

import Foundation
import UIKit

final class iOSSocketManager: ObservableObject {
    static let shared = iOSSocketManager()
    
    @Published var isConnected = false
    private var webSocketTask: URLSessionWebSocketTask?
    var serverIP: String {
        return DeviceUtils.getServerIP()
    }
    private var pendingSessionId: String?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var currentToken: String = ""
    private var isIntentionallyDisconnected = false
    
    private init() {}
    
    func setServerIP(_ ip: String) {
        DeviceUtils.saveServerIP(ip)
    }
    
    func connect(token: String = "") {
        if !token.isEmpty {
            self.currentToken = token
        }
        isIntentionallyDisconnected = false
        reconnectTimer?.invalidate()
        
        guard let url = buildWebSocketURL(token: self.currentToken) else { return }
        
        // Clean previous task
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        print("🔌 [iOS Socket] Connecting to server: \(url.absoluteString)")
        
        listenForMessages()
        startPingTimer()
    }
    
    private func buildWebSocketURL(token: String) -> URL? {
        let ip = serverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        var wsUrlString = "ws://\(ip):3000/socket.io/?EIO=4&transport=websocket"
        if !token.isEmpty {
            wsUrlString += "&token=\(token)"
        }
        return URL(string: wsUrlString)
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
                let nsErr = error as NSError
                if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                    // Ignore planned cancellation error (-999)
                    return
                }
                print("❌ [iOS Socket] Receive error: \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                }
                self.scheduleAutoReconnect()
            }
        }
    }
    
    private func handleIncomingPacket(_ text: String) {
        if text.hasPrefix("0") {
            // 1. Engine.IO Open Packet -> Mark connected & respond with Socket.IO Connect ("40")
            print("📩 [iOS Socket] Received Engine.IO Open -> Connection Active!")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            sendRaw("40")
            if let session = self.pendingSessionId {
                self.joinRoom(sessionId: session)
            }
        } else if text.hasPrefix("2") {
            // 2. Engine.IO Ping -> Respond with Pong ("3")
            sendRaw("3")
        } else if text.hasPrefix("40") {
            // 3. Socket.IO Connect ACK
            print("✅ [iOS Socket] Socket.IO Handshake Complete & Connected!")
            DispatchQueue.main.async {
                self.isConnected = true
            }
            if let session = self.pendingSessionId {
                self.joinRoom(sessionId: session)
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
        guard isConnected else { return }
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
    
    private func scheduleAutoReconnect() {
        guard !isIntentionallyDisconnected else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            print("🔄 [iOS Socket] Attempting auto-reconnect...")
            self?.connect()
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
        isIntentionallyDisconnected = true
        pingTimer?.invalidate()
        reconnectTimer?.invalidate()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
        print("🔴 [iOS Socket] Disconnected")
    }
}
