//
//  DeviceUtils.swift
//  CardLink
//
//  Persistent Device Identifier (UUIDv4) and Server IP management via UserDefaults.
//

import Foundation

struct DeviceUtils {
    private static let deviceIdKey = "cardlink_persistent_device_id"
    private static let serverIPKey = "cardlink_persistent_server_ip"
    private static let defaultIP = "192.168.1.3"
    
    /// Returns persistent UUIDv4 deviceId stored in UserDefaults. Generates once upon install.
    static func getDeviceId() -> String {
        if let savedId = UserDefaults.standard.string(forKey: deviceIdKey), !savedId.isEmpty {
            return savedId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        print("📱 [iOS DeviceUtils] Generated new persistent deviceId: \(newId)")
        return newId
    }
    
    /// Gets saved Server IP or default fallback IP.
    static func getServerIP() -> String {
        if let savedIP = UserDefaults.standard.string(forKey: serverIPKey), !savedIP.isEmpty {
            return savedIP
        }
        return defaultIP
    }
    
    /// Saves updated Server IP to UserDefaults.
    static func saveServerIP(_ ip: String) {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIP.isEmpty else { return }
        UserDefaults.standard.set(cleanIP, forKey: serverIPKey)
        print("💾 [iOS DeviceUtils] Saved Server IP: \(cleanIP)")
    }
}
