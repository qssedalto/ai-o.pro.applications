import Foundation
import CryptoKit

public enum MallError: LocalizedError {
    case invalidCredentials, invalidResponse, http(Int), business(String)
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "请配置有效商户 ID 与密钥。"
        case .invalidResponse: return "接口返回的数据格式不正确。"
        case .http(let status): return "HTTP 错误：\(status)"
        case .business(let message): return message
        }
    }
}

public enum Endpoint: String, CaseIterable {
    case connect = "authentication/connect"
    case items = "commodity/items"
    case item = "commodity/item"
    case inventory = "commodity/inventory"
    case stock = "commodity/stock"
    case inventoryState = "commodity/inventoryState"
    case valuation = "commodity/valuation"
}

public enum FormSigner {
    public static func encode(_ value: String) -> String {
        value.utf8.map { b in
            if (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || [45,46,95].contains(b) {
                return String(UnicodeScalar(b))
            }
            if b == 32 { return "+" }
            return String(format: "%%%02X", Int(b))
        }.joined()
    }
    public static func canonical(_ fields: [String: String], key: String) -> String {
        let body = fields.filter { $0.key != "sign" && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
        let raw = (body + "&key=" + key).replacingOccurrences(of: "+", with: " ")
        return raw.removingPercentEncoding ?? raw
    }
    public static func signature(_ fields: [String: String], key: String) -> String {
        Insecure.MD5.hash(data: Data(canonical(fields, key: key).utf8)).map { String(format: "%02x", Int($0)) }.joined()
    }
    public static func body(_ fields: [String: String], key: String) -> Data {
        var signed = fields.filter { $0.key != "sign" && !$0.value.isEmpty }
        signed["sign"] = signature(signed, key: key)
        return Data(signed.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct MallAPI {
    public static let base = URL(string: "https://ai-o.pro")!
    public let id: String
    private let key: String
    public init(id: String, key: String) { self.id = id; self.key = key }
    public func call(_ endpoint: Endpoint, _ parameters: [String: String] = [:]) async throws -> Any {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }), !key.isEmpty else { throw MallError.invalidCredentials }
        var fields = parameters
        fields["app_id"] = id
        var request = URLRequest(url: Self.base.appendingPathComponent("shared/" + endpoint.rawValue))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormSigner.body(fields, key: key)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MallError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MallError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MallError.invalidResponse }
        guard (json["code"] as? Int) == 200 else { throw MallError.business(json["msg"] as? String ?? "业务请求失败") }
        guard let result = json["data"] else { throw MallError.invalidResponse }
        return result
    }
}

public func stringValue(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}
public func decimalValue(_ value: Any?) -> Decimal? {
    guard let s = stringValue(value) else { return nil }
    return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
}
public struct Product: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: String
    public let price: String
    public let stock: String
    public let cover: URL?
    public let deliveryWay: Int?
    public init?(_ object: [String: Any], category: String) {
        guard let code = object["code"] as? String, !code.isEmpty, let name = object["name"] as? String else { return nil }
        id = code; self.name = name; self.category = category
        price = stringValue(object["user_price"]) ?? stringValue(object["price"]) ?? "—"
        stock = stringValue(object["stock"]) ?? "—"
        let url = (object["cover"] as? String).flatMap(URL.init(string:))
        cover = url?.scheme == "https" && url?.host == "imgurloss.xqd.cn" ? url : nil
        deliveryWay = Int(stringValue(object["delivery_way"]) ?? "")
    }
    public static func catalog(_ data: Any) throws -> [Product] {
        guard let categories = data as? [[String: Any]] else { throw MallError.invalidResponse }
        var seen = Set<String>()
        return categories.flatMap { category in
            (category["children"] as? [[String: Any]] ?? []).compactMap { Product($0, category: category["name"] as? String ?? "未分类") }
        }.filter { seen.insert($0.id).inserted }
    }
}
public struct Variant: Identifiable, Hashable {
    public var id: String { race }
    public let race: String
    public let price: String
}
public func variants(_ config: Any?) -> [Variant] {
    if let object = config as? [String: Any], let category = object["category"] as? [String: Any] {
        return category.keys.sorted().map { Variant(race: $0, price: stringValue(category[$0]) ?? "—") }
    }
    if let ini = config as? String {
        var active = false
        return ini.components(separatedBy: .newlines).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("[") { active = s == "[category]"; return nil }
            guard active, let eq = s.firstIndex(of: "=") else { return nil }
            return Variant(race: String(s[..<eq]), price: String(s[s.index(after: eq)...]))
        }
    }
    return []
}
