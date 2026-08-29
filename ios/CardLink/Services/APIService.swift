//
//  APIService.swift
//  CardLink
//
//  REST API Client for authentication, starting live session, and sending 5s heartbeat.
//

import Foundation

struct LoginResponse: Codable {
    let token: String
    let user: UserInfo
}

struct UserInfo: Codable {
    let id: String
    let username: String
    let role: String
}

struct StartSessionResponse: Codable {
    let sessionId: String
    let streamUrl: String?
}

final class APIService {
    static let shared = APIService()
    private var serverIP: String {
        return DeviceUtils.getServerIP()
    }
    private var baseURL: String {
        return "http://\(serverIP):3000/api"
    }
    private var authToken: String?
    
    private init() {}
    
    func setServerIP(_ ip: String) {
        DeviceUtils.saveServerIP(ip)
    }
    
    func getServerIP() -> String {
        return DeviceUtils.getServerIP()
    }
    
    func setAuthToken(_ token: String) {
        self.authToken = token
    }
    
    func getAuthToken() -> String? {
        return authToken
    }
    
    func login(username: String, password: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/login") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["username": username, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "NoData", code: -1)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
                self.authToken = decoded.token
                completion(.success(decoded.token))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    func startLiveSession(completion: @escaping (Result<StartSessionResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/sessions/start") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body = ["deviceId": DeviceUtils.getDeviceId()]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(StartSessionResponse.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    func sendHeartbeat(sessionId: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/sessions/heartbeat") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let body = ["sessionId": sessionId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }
}
