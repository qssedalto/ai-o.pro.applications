import SwiftUI
import Security
import AppKit
import Charts
import WebKit
import MallCore
import UserNotifications

enum Vault {
    static let service = "pro.ai-o.studio"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ account: String, _ value: String) throws {
        let q = query(account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = q
            new[kSecValueData as String] = data
            let added = SecItemAdd(new as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct Snapshot: Codable, Identifiable {
    var id = UUID()
    let time: Date
    let code: String
    let race: String
    let quantity: Int
    let price: Decimal
    let stock: Int
}

@MainActor final class Store: ObservableObject {
    @Published var products: [Product] = []
    @Published var shop = "未连接"
    @Published var balance = "—"
    @Published var busy = false
    @Published var error = ""
    @Published var updated: Date?
    @Published var history: [Snapshot] = []
    @Published var merchant = Vault.load("id")
    @Published private(set) var inventoryChanges: [String] = []
    @Published private(set) var noticePermission = "未授权"
    @Published var refreshMinutes: Int = UserDefaults.standard.integer(forKey: "refreshMinutes") { didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleRefresh() } }
    @Published var noticesEnabled: Bool = UserDefaults.standard.bool(forKey: "noticesEnabled") { didSet { UserDefaults.standard.set(noticesEnabled, forKey: "noticesEnabled") } }
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var key = Vault.load("key")
    private var storage: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        guard !merchant.isEmpty, merchant.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return base.appendingPathComponent("AI-O Studio/Accounts/" + merchant + "/history.json")
    }
    init() {
        loadHistory()
        scheduleRefresh()
        Task { await updateNoticePermission() }
    }
    func scheduleRefresh() {
        refreshTask?.cancel()
        guard [5, 15, 30, 60].contains(refreshMinutes) else { return }
        let seconds = UInt64(refreshMinutes) * 60 * 1_000_000_000
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: seconds) } catch { return }
                guard let self, !self.merchant.isEmpty else { continue }
                await self.refresh()
            }
        }
    }
    func updateNoticePermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: noticePermission = "已授权"
        case .denied: noticePermission = "系统已拒绝"
        default: noticePermission = "未授权"
        }
    }
    func requestNotices() async {
        do {
            noticesEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await updateNoticePermission()
        } catch { noticesEnabled = false; self.error = error.localizedDescription }
    }
    private func compareInventory(old: [Product], new: [Product]) async {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let changes = new.compactMap { product -> String? in
            guard let before = previous[product.id], let a = Int(before.stock), let b = Int(product.stock),
                  a >= 0, b >= 0, a < 1_000_000, b < 1_000_000 else { return nil }
            if a > 0 && b == 0 { return product.name + "：目录库存降为 0" }
            if a == 0 && b > 0 { return product.name + "：目录恢复有货" }
            if a > 10 && b > 0 && b <= 10 { return product.name + "：目录库存降至 " + String(b) }
            return nil
        }
        inventoryChanges = Array((changes + inventoryChanges).prefix(20))
        guard noticesEnabled, !changes.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI-O Studio · 库存变化"
        content.body = changes.count == 1 ? changes[0] : "有 " + String(changes.count) + " 项目录库存状态变化，打开应用查看。"
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch { await updateNoticePermission() }
    }
    private func loadHistory() {
        history = []
        if let url = storage, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Snapshot].self, from: data) { history = saved }
    }
    var api: MallAPI { MallAPI(id: merchant, key: key) }
    func configure(id: String, secret: String) throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }), !secret.isEmpty else { throw MallError.invalidCredentials }
        try Vault.save("id", id)
        try Vault.save("key", secret)
        generation = UUID()
        merchant = id; key = secret
        inventoryChanges = []
        products = []; balance = "—"; shop = "未连接"; updated = nil; error = ""
        loadHistory()
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; error = ""
        let client = api, accountGeneration = generation
        defer { busy = false }
        do {
            guard let connection = try await client.call(.connect) as? [String: Any] else { throw MallError.invalidResponse }
            let catalogData = try await client.call(.items)
            let catalog = try Product.catalog(catalogData)
            guard !Task.isCancelled, generation == accountGeneration else { return }
            let old = products
            shop = stringValue(connection["shopName"]) ?? "已连接"
            balance = stringValue(connection["balance"]) ?? "—"
            products = catalog
            updated = Date()
            await compareInventory(old: old, new: catalog)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func record(_ sample: Snapshot, merchantID: String) {
        guard merchant == merchantID else { return }
        history.append(sample)
        if history.count > 10000 { history.removeFirst(history.count - 10000) }
        do {
            guard let url = storage else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: url, options: .atomic)
        } catch { self.error = "历史记录保存失败：" + error.localizedDescription }
    }
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI-O-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func cell(_ s: String) -> String {
            let safe = s.first.map { "=+-@".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let rows = history.map { item in
            [formatter.string(from: item.time), item.code, item.race, String(item.quantity), NSDecimalNumber(decimal: item.price).stringValue, String(item.stock)].map(cell).joined(separator: ",")
        }
        do { try (["time,code,race,quantity,total_price,stock"] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

struct SafeHTML: NSViewRepresentable {
    let html: String
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.scheme == "about" ? .allow : .cancel)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let header = "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><meta charset='utf-8'><style>body{font:14px -apple-system;overflow-wrap:anywhere}table{max-width:100%}</style>"
        view.loadHTMLString(header + html, baseURL: nil)
    }
}

struct ProductDetail: View {
    @EnvironmentObject var store: Store
    let product: Product
    var mode: StudioSection = .catalog
    @State private var pane = "quote"
    @State private var detail: [String: Any] = [:]
    @State private var race = ""
    @State private var quantity = 1
    @State private var quote: Decimal?
    @State private var stock: Int?
    @State private var retail = ""
    @State private var busy = false
    @State private var error = ""
    @State private var status = ""
    @State private var lastQuote: Date?
    var options: [Variant] { variants(detail["config"]) }
    var matrix: [[String: Any]] { detail["level_price_compare_matrix"] as? [[String: Any]] ?? [] }
    var hasUnsupportedSKU: Bool {
        if let config = detail["config"] as? [String: Any] {
            for (key, value) in config where key.lowercased().contains("sku") {
                if let dict = value as? [String: Any], !dict.isEmpty { return true }
                if let array = value as? [Any], !array.isEmpty { return true }
                if let text = value as? String, !text.isEmpty { return true }
            }
        }
        if let selection = detail["price_selection"] as? [String: Any] {
            if let sku = selection["sku"] as? [String: Any], !sku.isEmpty { return true }
            if let sku = selection["sku"] as? [Any], !sku.isEmpty { return true }
        }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ProductCover(product: product, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(product.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(product.category + "  ·  " + product.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("重新读取商品详情").disabled(busy)
            }.padding(20)
            Picker("详情", selection: $pane) { Text("报价与库存").tag("quote"); Text("价格对比").tag("prices"); Text("商品说明").tag("info") }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if pane == "quote" {
                if hasUnsupportedSKU { Label("该商品包含多维 SKU，当前版本暂不支持精确查询，避免返回错误报价。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !options.isEmpty {
                    Picker("类别规格", selection: $race) {
                        ForEach(options) { Text($0.race + " · ¥" + $0.price).tag($0.race) }
                    }.disabled(busy)
                }
                Stepper("数量：\(quantity)", value: $quantity, in: 1...1000).disabled(busy)
                HStack {
                    Button("查询报价与库存") { Task { await lookup() } }.disabled(busy || detail.isEmpty || hasUnsupportedSKU)
                    Button("库存可用性校验") { Task { await validate() } }.disabled(busy || detail.isEmpty || hasUnsupportedSKU)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty { Label(status, systemImage: "info.circle").foregroundStyle(.secondary) }
                if let lastQuote { Text("查询时间：" + lastQuote.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                GroupBox("实时数据") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("总报价").foregroundStyle(.secondary)
                            Text(quote.map { "¥" + NSDecimalNumber(decimal: $0).stringValue } ?? "—").font(.title)
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("规格库存").foregroundStyle(.secondary)
                            Text(stock.map { $0 >= 1_000_000 ? "待确认" : String($0) } ?? "—").font(.title)
                        }
                    }.padding(8)
                }
                GroupBox("参考利润（不含手续费）") {
                    VStack(alignment: .leading) {
                        TextField("单件零售价（元）", text: $retail)
                        Text("默认取对应规格的分站零售价，可手动调整。").font(.caption).foregroundStyle(.secondary)
                        if let quote, let selling = decimalValue(retail), selling >= 0 {
                            let revenue = selling * Decimal(quantity)
                            let difference = revenue - quote
                            Text("参考总毛利：¥" + NSDecimalNumber(decimal: difference).stringValue).font(.title3.weight(.semibold))
                            if revenue > 0 { Text("参考毛利率：" + (NSDecimalNumber(decimal: difference / revenue).doubleValue).formatted(.percent.precision(.fractionLength(2)))) }
                        }
                    }.padding(5)
                }
                }
                if pane == "prices" {
                    if matrix.isEmpty { ContentUnavailableView("暂无会员价格表", systemImage: "tablecells") }
                    else { PriceMatrix(detail: detail) }
                    Text("配置价格与实际报价可能不同，请以实时总报价为准。").font(.caption).foregroundStyle(.secondary)
                }
                if pane == "info" {
                    if let html = detail["description"] as? String {
                        Text("供应商说明 · 外部资源与脚本已禁用").font(.caption).foregroundStyle(.secondary)
                        SafeHTML(html: html).frame(minHeight: 520)
                    } else { ContentUnavailableView("暂无商品说明", systemImage: "doc.text") }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: product.id) { pane = mode == .prices ? "prices" : "quote"; await load() }
        .onChange(of: race) { _, _ in quote = nil; stock = nil; status = ""; lastQuote = nil; applyRetail() }
        .onChange(of: quantity) { _, _ in quote = nil; status = ""; lastQuote = nil }
    }
    func applyRetail() {
        let heads = detail["level_price_compare_heads"] as? [[String: Any]] ?? []
        guard let index = heads.firstIndex(where: { ($0["key"] as? String) == "station_retail" }) else { retail = ""; return }
        let row = matrix.first { (stringValue($0["spec"]) ?? "") == "类型：" + race } ?? (race.isEmpty && matrix.count == 1 ? matrix.first : nil)
        let cells = row?["cells"] as? [[String: Any]] ?? []
        retail = cells.indices.contains(index) ? (stringValue(cells[index]["price"]) ?? "") : ""
    }
    func fields() -> [String: String] { ["code": product.id, "race": race] }
    @MainActor func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        error = ""; detail = [:]; quote = nil; stock = nil; status = ""; lastQuote = nil
        do {
            guard let d = try await store.api.call(.item, ["code": product.id]) as? [String: Any] else { throw MallError.invalidResponse }
            detail = d
            let preferred = (d["price_selection"] as? [String: Any])?["race"] as? String ?? ""
            race = options.contains(where: { $0.race == preferred }) ? preferred : (options.first?.race ?? "")
            applyRetail()
        } catch { self.error = error.localizedDescription }
    }
    @MainActor func lookup() async {
        guard !busy, !hasUnsupportedSKU else { return }
        busy = true; error = ""; status = ""; quote = nil; stock = nil; lastQuote = nil
        defer { busy = false }
        let selected = race, count = quantity, account = store.merchant
        let api = store.api
        do {
            var f = fields(); f["num"] = String(count); f["card_id"] = "0"
            let q = try await api.call(.valuation, f) as? [String: Any]
            let s = try await api.call(.stock, ["code": product.id, "race": selected]) as? [String: Any]
            let inventory = try await api.call(.inventory, ["sharedCode": product.id, "race": selected]) as? [String: Any]
            guard let p = decimalValue(q?["price"]), let n = Int(stringValue(s?["stock"]) ?? "") else { throw MallError.invalidResponse }
            guard !Task.isCancelled, selected == race, count == quantity, account == store.merchant else { return }
            quote = p; stock = n; lastQuote = Date()
            if let inventoryCount = stringValue(inventory?["count"]), inventoryCount != String(n) { status = "库存查询结果存在差异，请刷新确认。" }
            store.record(Snapshot(time: Date(), code: product.id, race: selected, quantity: count, price: p, stock: n), merchantID: account)
        } catch { self.error = error.localizedDescription }
    }
    @MainActor func validate() async {
        guard !busy, !hasUnsupportedSKU else { return }
        busy = true; error = ""; status = ""
        defer { busy = false }
        do {
            _ = try await store.api.call(.inventoryState, ["shared_code": product.id, "race": race, "num": String(quantity), "card_id": "0"])
            status = "库存校验通过（不锁库存、不扣款）"
        } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var id = ""
    @State private var secret = ""
    @State private var error = ""
    var body: some View {
        Form {
            Text("https://ai-o.pro").foregroundStyle(.secondary)
            TextField("商户 ID", text: $id)
            SecureField("商户密钥", text: $secret)
            Button("保存并连接") {
                do {
                    try store.configure(id: id, secret: secret)
                    secret = ""; error = ""
                    Task { await store.refresh() }
                } catch { self.error = error.localizedDescription }
            }.disabled(id.isEmpty || secret.isEmpty || store.busy)
            if store.updated != nil { Button("返回经营概览") { NotificationCenter.default.post(name: .init("StudioShowOverview"), object: nil) } }
            if store.busy { ProgressView("正在连接…") }
            if let updated = store.updated { Label("连接成功 · " + updated.formatted(), systemImage: "checkmark.circle").foregroundStyle(.green) }
            Section("同步与通知") {
                Picker("自动同步", selection: $store.refreshMinutes) {
                    Text("关闭").tag(0); Text("每 5 分钟").tag(5); Text("每 15 分钟").tag(15); Text("每 30 分钟").tag(30); Text("每小时").tag(60)
                }
                Toggle("目录库存变化通知", isOn: Binding(get: { store.noticesEnabled }, set: { enabled in
                    if enabled { Task { await store.requestNotices() } } else { store.noticesEnabled = false }
                }))
                Text("通知权限：" + store.noticePermission).font(.caption).foregroundStyle(.secondary)
                Text("仅在应用运行时同步目录，不轮询全部规格，不进行采购。").font(.caption).foregroundStyle(.secondary)
            }
            Text("密钥仅保存在本机钥匙串。此版本不执行任何采购或扣款。").foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
        }.formStyle(.grouped).padding().onAppear { id = store.merchant }
    }
}

@main @MainActor struct AIOStudioApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("AI-O Studio") { Root().environmentObject(store) }
        Settings { SettingsView().environmentObject(store).frame(width: 520, height: 480) }
    }
}
