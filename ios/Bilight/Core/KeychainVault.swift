import Foundation
import Security

/// App-owned credentials never enter UserDefaults, logs, the browser profile or iCloud.
enum KeychainVault {
    static let service = "app.bilight.ios"
    static func load<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
                kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw BiliFailure(code: "KEYCHAIN", message: "安全存储暂不可用（\(status)），请检查 App 签名或解锁设备。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func save<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable] = false
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw BiliFailure(code: "KEYCHAIN", message: "无法安全保存账号，请解锁设备后重试。")
            }
        } else if status != errSecSuccess {
            throw BiliFailure(code: "KEYCHAIN", message: "无法更新安全存储。")
        }
    }
    static func delete(_ name: String) {
        SecItemDelete(
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary)
    }
}
struct StoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
    }
    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
    func matches(_ url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host, url.scheme == "https", expires == nil || expires! > now else { return false }
        let root = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return (host == root || (domain.hasPrefix(".") && host.hasSuffix(".\(root)")))
            && (url.path == path
                || (url.path.hasPrefix(path) && (path.hasSuffix("/") || url.path.dropFirst(path.count).hasPrefix("/"))))
    }
}

protocol SessionVault {
    func load() throws -> [StoredCookie]
    func save(_ cookies: [StoredCookie]) throws
    func remove()
}
struct DeviceSessionVault: SessionVault {
    func load() throws -> [StoredCookie] { try KeychainVault.load("session") ?? [] }
    func save(_ cookies: [StoredCookie]) throws { try KeychainVault.save(cookies, name: "session") }
    func remove() { KeychainVault.delete("session") }
}
