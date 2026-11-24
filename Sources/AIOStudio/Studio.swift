import SwiftUI
import Security
import AppKit
import Charts
import WebKit
import MallCore

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
    private var key = Vault.load("key")
    private var storage: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("AI-O Studio/history.json")
    }
    init() {
        if let url = storage, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Snapshot].self, from: data) { history = saved }
    }
    var api: MallAPI { MallAPI(id: merchant, key: key) }
    func configure(id: String, secret: String) throws {
        guard !id.isEmpty, !secret.isEmpty else { throw MallError.invalidCredentials }
        try Vault.save("id", id)
        try Vault.save("key", secret)
        merchant = id; key = secret
        products = []; balance = "—"; shop = "未连接"; updated = nil
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; error = ""
        defer { busy = false }
        do {
            guard let connection = try await api.call(.connect) as? [String: Any] else { throw MallError.invalidResponse }
            let catalogData = try await api.call(.items)
            let catalog = try Product.catalog(catalogData)
            shop = stringValue(connection["shopName"]) ?? "已连接"
            balance = stringValue(connection["balance"]) ?? "—"
            products = catalog
            updated = Date()
        } catch { self.error = error.localizedDescription }
    }
    func record(_ sample: Snapshot) {
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
        let header = "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><meta charset='utf-8'><style>body{font:14px -apple-system;overflow-wrap:anywhere}table{max-width:100%}</style>"
        view.loadHTMLString(header + html, baseURL: nil)
    }
}

struct ProductDetail: View {
    @EnvironmentObject var store: Store
    let product: Product
    @State private var detail: [String: Any] = [:]
    @State private var race = ""
    @State private var quantity = 1
    @State private var quote: Decimal?
    @State private var stock: Int?
    @State private var retail = ""
    @State private var busy = false
    @State private var error = ""
    @State private var status = ""
    var options: [Variant] { variants(detail["config"]) }
    var matrix: [[String: Any]] { detail["level_price_compare_matrix"] as? [[String: Any]] ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(product.name).font(.title2.bold())
                Text(product.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if !options.isEmpty {
                    Picker("类别规格", selection: $race) {
                        ForEach(options) { Text($0.race + " · ¥" + $0.price).tag($0.race) }
                    }.disabled(busy)
                }
                Stepper("数量：\(quantity)", value: $quantity, in: 1...1000).disabled(busy)
                HStack {
                    Button("查询报价与库存") { Task { await lookup() } }.disabled(busy || detail.isEmpty)
                    Button("库存可用性校验") { Task { await validate() } }.disabled(busy || detail.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(status).foregroundStyle(.secondary)
                GroupBox("实时数据") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("总报价").foregroundStyle(.secondary)
                            Text(quote.map { "¥" + NSDecimalNumber(decimal: $0).stringValue } ?? "—").font(.title)
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("规格库存").foregroundStyle(.secondary)
                            Text(stock.map { String($0) } ?? "—").font(.title)
                        }
                    }.padding(8)
                }
                GroupBox("参考利润（不含手续费）") {
                    VStack(alignment: .leading) {
                        TextField("单件零售价", text: $retail)
                        if let quote, let selling = decimalValue(retail) {
                            let difference = selling * Decimal(quantity) - quote
                            Text("参考总毛利：¥" + NSDecimalNumber(decimal: difference).stringValue)
                        }
                    }.padding(5)
                }
                if !matrix.isEmpty {
                    GroupBox("分站价格对比（接口原始口径）") {
                        VStack(alignment: .leading) {
                            ForEach(Array(matrix.enumerated()), id: \.offset) { entry in
                                let cells = entry.element["cells"] as? [[String: Any]] ?? []
                                Text((stringValue(entry.element["spec"]) ?? "规格") + "：" + cells.compactMap { stringValue($0["price"]) }.joined(separator: " / "))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let html = detail["description"] as? String {
                    GroupBox("供应商商品说明") { SafeHTML(html: html).frame(height: 500) }
                }
            }.padding(24)
        }
        .task(id: product.id) { await load() }
        .onChange(of: race) { _, _ in quote = nil; stock = nil; status = "" }
        .onChange(of: quantity) { _, _ in quote = nil; status = "" }
    }
    func fields() -> [String: String] { ["code": product.id, "race": race] }
    @MainActor func load() async {
        busy = true; defer { busy = false }
        error = ""; detail = [:]; quote = nil; stock = nil; status = ""
        do {
            guard let d = try await store.api.call(.item, ["code": product.id]) as? [String: Any] else { throw MallError.invalidResponse }
            detail = d
            let preferred = (d["price_selection"] as? [String: Any])?["race"] as? String ?? ""
            race = options.contains(where: { $0.race == preferred }) ? preferred : (options.first?.race ?? "")
            retail = ""
        } catch { self.error = error.localizedDescription }
    }
    @MainActor func lookup() async {
        busy = true; error = ""; status = ""; quote = nil; stock = nil
        defer { busy = false }
        let selected = race, count = quantity
        do {
            var f = fields(); f["num"] = String(count); f["card_id"] = "0"
            let q = try await store.api.call(.valuation, f) as? [String: Any]
            let s = try await store.api.call(.stock, ["code": product.id, "race": selected]) as? [String: Any]
            let inventory = try await store.api.call(.inventory, ["sharedCode": product.id, "race": selected]) as? [String: Any]
            guard let p = decimalValue(q?["price"]), let n = Int(stringValue(s?["stock"]) ?? "") else { throw MallError.invalidResponse }
            guard selected == race, count == quantity else { return }
            quote = p; stock = n
            if let inventoryCount = stringValue(inventory?["count"]), inventoryCount != String(n) { status = "库存查询结果存在差异，请刷新确认。" }
            store.record(Snapshot(time: Date(), code: product.id, race: selected, quantity: count, price: p, stock: n))
        } catch { self.error = error.localizedDescription }
    }
    @MainActor func validate() async {
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
            Text("密钥仅保存在本机钥匙串。此版本不执行任何采购或扣款。").foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
        }.formStyle(.grouped).padding().onAppear { id = store.merchant }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("报价历史").font(.title2.bold()); Spacer(); Button("导出 CSV") { store.export() } }
            Text("每次成功查询保存一条快照；不同商品、规格、数量的总报价不可直接比较。").foregroundStyle(.secondary)
            if store.history.isEmpty { ContentUnavailableView("暂无历史", systemImage: "chart.xyaxis.line", description: Text("查询报价后自动记录")) }
            else {
                let latest = store.history.last!
                let group = store.history.filter { $0.code == latest.code && $0.race == latest.race && $0.quantity == latest.quantity }
                Text("最近查询规格 · \(latest.race) · 数量 \(latest.quantity)").font(.caption)
                Chart(group) { sample in
                    LineMark(x: .value("时间", sample.time), y: .value("总报价", NSDecimalNumber(decimal: sample.price).doubleValue))
                    PointMark(x: .value("时间", sample.time), y: .value("总报价", NSDecimalNumber(decimal: sample.price).doubleValue))
                }.frame(height: 200)
                List(store.history.reversed()) { sample in
                    VStack(alignment: .leading) {
                        Text(sample.code + " · " + sample.race)
                        Text("¥\(NSDecimalNumber(decimal: sample.price).stringValue) · 库存 \(sample.stock) · " + sample.time.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(24)
    }
}

struct Root: View {
    @EnvironmentObject var store: Store
    @State private var tab: String? = "catalog"
    @State private var search = ""
    @State private var selected: Product?
    var filtered: [Product] {
        store.products.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                Label("商品目录", systemImage: "shippingbox").tag("catalog")
                Label("历史与分析", systemImage: "chart.xyaxis.line").tag("history")
                Label("账户设置", systemImage: "gear").tag("settings")
            }.navigationSplitViewColumnWidth(180)
        } detail: {
            if tab == "settings" { SettingsView() }
            else if tab == "history" { HistoryView() }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(store.shop).font(.headline)
                            Text("余额 ¥\(store.balance) · 商品 \(store.products.count)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.busy { ProgressView().controlSize(.small) }
                        Button("刷新") { Task { await store.refresh() } }.disabled(store.busy)
                    }.padding([.horizontal, .top])
                    if !store.error.isEmpty { Text(store.error).foregroundStyle(.red).padding(.horizontal) }
                    HSplitView {
                        List(selection: $selected) {
                            ForEach(filtered) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(p.name).lineLimit(2)
                                    Text(p.category + " · ¥" + p.price + " · 目录库存 " + p.stock).font(.caption).foregroundStyle(.secondary)
                                }.tag(p)
                            }
                        }.frame(minWidth: 240, idealWidth: 320).searchable(text: $search)
                        if let selected { ProductDetail(product: selected).id(selected.id) }
                        else { ContentUnavailableView("选择商品", systemImage: "shippingbox", description: Text("查看详情、实时报价及库存")) }
                    }
                }
            }
        }.frame(minWidth: 900, minHeight: 570)
            .task { if store.merchant.isEmpty { tab = "settings" } else { await store.refresh() } }
    }
}

@main @MainActor struct AIOStudioApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("AI-O Studio") { Root().environmentObject(store) }
        Settings { SettingsView().environmentObject(store).frame(width: 480, height: 270) }
    }
}
