import SwiftUI
import Charts
import MallCore

enum StudioSection: String, CaseIterable, Identifiable {
    case overview, catalog, inventory, prices, history, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "经营概览"
        case .catalog: return "商品中心"
        case .inventory: return "库存中心"
        case .prices: return "价格与利润"
        case .history: return "历史趋势"
        case .settings: return "账户设置"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .catalog: return "shippingbox"
        case .inventory: return "tray.full"
        case .prices: return "tag"
        case .history: return "chart.xyaxis.line"
        case .settings: return "gear"
        }
    }
}
struct ProductCover: View {
    let product: Product
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            .overlay {
                if let url = product.cover {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
                    }.padding(3)
                } else { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
            }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}
struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(.secondary) }
            Text(value).font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct Overview: View {
    @EnvironmentObject var store: Store
    let navigate: (StudioSection) -> Void
    var categories: [String] { Array(Set(store.products.map(\.category))).sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("经营概览").font(.largeTitle.bold())
                    Text(store.shop).font(.title3).foregroundStyle(.secondary)
                    Text(store.updated.map { "最近同步：" + $0.formatted() } ?? "尚未成功同步").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(title: "账户余额", value: store.updated == nil ? "—" : "¥" + store.balance, icon: "wallet.pass")
                    MetricTile(title: "可对接商品", value: store.updated == nil ? "—" : String(store.products.count), icon: "shippingbox")
                    MetricTile(title: "商品分类", value: store.updated == nil ? "—" : String(categories.count), icon: "square.grid.2x2")
                    MetricTile(title: "自动发货", value: store.updated == nil ? "—" : String(store.products.filter { $0.deliveryWay == 0 }.count), icon: "bolt")
                }
                if store.updated == nil && !store.busy {
                    ContentUnavailableView("尚未同步商城", systemImage: "network", description: Text("在账户设置中配置商户密钥，或点击工具栏刷新。"))
                    Button("账户设置") { navigate(.settings) }.buttonStyle(.borderedProminent)
                } else if !categories.isEmpty {
                    GroupBox("商品分类") {
                        Chart(categories, id: \.self) { name in
                            BarMark(x: .value("商品", store.products.filter { $0.category == name }.count), y: .value("分类", name))
                                .foregroundStyle(Color.accentColor.gradient)
                        }.frame(height: max(160, CGFloat(categories.count) * 27)).padding(8)
                    }
                    HStack { Text("最近查询").font(.title2.bold()); Spacer(); Button("查看历史") { navigate(.history) } }
                    if store.history.isEmpty { Text("暂无查询记录").foregroundStyle(.secondary) }
                    ForEach(Array(store.history.suffix(5).reversed())) { sample in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(store.products.first(where: { $0.id == sample.code })?.name ?? sample.code).lineLimit(1)
                                Text(sample.race + " · " + sample.time.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("¥" + NSDecimalNumber(decimal: sample.price).stringValue).monospacedDigit()
                        }.padding(.vertical, 5)
                    }
                }
                Text("只读模式 · 供应商库存和销量不是本店资产或营业额。").font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth: 1100, alignment: .leading)
        }
    }
}
struct PriceMatrix: View {
    let detail: [String: Any]
    var heads: [[String: Any]] { detail["level_price_compare_heads"] as? [[String: Any]] ?? [] }
    var rows: [[String: Any]] { detail["level_price_compare_matrix"] as? [[String: Any]] ?? [] }
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("规格").font(.caption.weight(.semibold)).frame(width: 180, alignment: .leading)
                    ForEach(Array(heads.enumerated()), id: \.offset) { h in
                        Text(stringValue(h.element["name"]) ?? "—").font(.caption.weight(.semibold)).frame(minWidth: 76, alignment: .trailing)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    GridRow {
                        Text(stringValue(row.element["spec"]) ?? "—").frame(width: 180, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        let cells = row.element["cells"] as? [[String: Any]] ?? []
                        ForEach(heads.indices, id: \.self) { i in
                            Text(cells.indices.contains(i) ? "¥" + (stringValue(cells[i]["price"]) ?? "—") : "—").monospacedDigit().frame(minWidth: 76, alignment: .trailing)
                        }
                    }
                    Divider()
                }
            }.padding(12)
        }
    }
}
struct CatalogWorkspace: View {
    @EnvironmentObject var store: Store
    let section: StudioSection
    @State private var category = ""
    @State private var search = ""
    @State private var selectedID: String?
    @State private var availability = "all"
    var categories: [String] { Array(Set(store.products.map(\.category))).sorted() }
    var filtered: [Product] {
        store.products.filter { p in
            (category.isEmpty || p.category == category) &&
            (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || p.id.localizedCaseInsensitiveContains(search)) &&
            (availability == "all" || (availability == "low" && (Int(p.stock).map { $0 > 0 && $0 <= 10 } ?? false)) || (availability == "out" && Int(p.stock) == 0))
        }
    }
    var selection: Product? { filtered.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(section.title).font(.largeTitle.bold())
                Text(section == .inventory ? "目录库存筛选；选择商品获取独立规格库存。超大库存可能为系统占位值。" : section == .prices ? "选择商品查看会员价格及实时总报价。" : "选择分类或搜索商品名称、对接 CODE。").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Picker("分类", selection: $category) {
                        Text("全部分类").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 290)
                    if section == .inventory {
                        Picker("库存", selection: $availability) {
                            Text("全部").tag("all"); Text("低库存（1–10）").tag("low"); Text("无库存").tag("out")
                        }.frame(maxWidth: 220)
                    }
                    Spacer()
                    Text("\(filtered.count) 项").monospacedDigit().foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(filtered) { p in
                        HStack(spacing: 10) {
                            ProductCover(product: p)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).lineLimit(2).font(.subheadline.weight(.medium))
                                HStack(spacing: 6) {
                                    Text("¥" + p.price).monospacedDigit()
                                    Text("·")
                                    Text(Int(p.stock).map { $0 >= 1_000_000 } == true ? "库存待确认" : "目录库存 " + p.stock)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(p.id)
                    }
                }.listStyle(.inset).frame(minWidth: 260, idealWidth: 320).searchable(text: $search, placement: .automatic, prompt: "搜索商品或 CODE")
                if let selection {
                    ProductDetail(product: selection, mode: section).id(store.merchant + ":" + selection.id + ":" + section.rawValue).frame(minWidth: 340)
                } else {
                    ContentUnavailableView(filtered.isEmpty ? "没有符合条件的商品" : "选择商品", systemImage: filtered.isEmpty ? "magnifyingglass" : "shippingbox", description: Text("详情、库存与价格将在此显示。"))
                }
            }
        }
        .onChange(of: store.merchant) { _, _ in selectedID = nil; category = ""; search = "" }
        .onChange(of: categories) { _, values in if !values.contains(category) { category = "" } }
    }
}
struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var product = ""
    @State private var variant = ""
    @State private var quantity = 1
    @State private var days = 30
    @State private var metric = "price"
    @State private var hover: Date?
    var codes: [String] { Array(Set(store.history.map(\.code))).sorted() }
    var races: [String] { Array(Set(store.history.filter { $0.code == product }.map(\.race))).sorted() }
    var quantities: [Int] { Array(Set(store.history.filter { $0.code == product && $0.race == variant }.map(\.quantity))).sorted() }
    var samples: [Snapshot] {
        store.history.filter {
            $0.code == product && $0.race == variant && $0.quantity == quantity &&
            (days == 0 || $0.time >= Date().addingTimeInterval(-Double(days)*86400))
        }.sorted { $0.time < $1.time }
    }
    var nearest: Snapshot? {
        guard let hover else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(hover)) < abs($1.time.timeIntervalSince(hover)) }
    }
    func value(_ sample: Snapshot) -> Double { metric == "price" ? NSDecimalNumber(decimal: sample.price).doubleValue : Double(sample.stock) }
    func reset() {
        if !codes.contains(product) { product = store.history.last?.code ?? "" }
        if !races.contains(variant) { variant = races.first ?? "" }
        if !quantities.contains(quantity) { quantity = quantities.first ?? 1 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("历史趋势").font(.largeTitle.bold()); Spacer(); Button { store.export() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }.disabled(store.history.isEmpty) }
            Text("仅展示本商户手动查询的真实快照。总报价需按相同数量比较。").foregroundStyle(.secondary)
            if store.history.isEmpty {
                ContentUnavailableView("暂无历史数据", systemImage: "chart.xyaxis.line", description: Text("在商品详情完成一次报价与库存查询后自动记录。"))
            } else {
                HStack {
                    Picker("商品", selection: $product) { ForEach(codes, id: \.self) { c in Text(store.products.first(where: { $0.id == c })?.name ?? c).tag(c) } }
                    Picker("规格", selection: $variant) { ForEach(races, id: \.self) { Text($0.isEmpty ? "默认规格" : $0).tag($0) } }
                }
                HStack {
                    Picker("数量", selection: $quantity) { ForEach(quantities, id: \.self) { Text(String($0)).tag($0) } }
                    Picker("时间范围", selection: $days) { Text("7 天").tag(7); Text("30 天").tag(30); Text("全部").tag(0) }
                    Picker("指标", selection: $metric) { Text("总报价").tag("price"); Text("库存").tag("stock") }.pickerStyle(.segmented)
                }
                if samples.isEmpty { ContentUnavailableView("所选范围没有数据", systemImage: "calendar") }
                else {
                    Chart {
                        ForEach(samples) { sample in
                            LineMark(x: .value("时间", sample.time), y: .value("数值", value(sample)))
                            PointMark(x: .value("时间", sample.time), y: .value("数值", value(sample)))
                        }
                        if let nearest {
                            RuleMark(x: .value("时间", nearest.time)).foregroundStyle(.secondary)
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    Text(nearest.time.formatted(date: .abbreviated, time: .shortened) + " · " + value(nearest).formatted()).font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                }
                        }
                    }.chartXSelection(value: $hover).frame(minHeight: 180, idealHeight: 240).padding(.vertical, 8)
                    List(Array(samples.reversed())) { sample in
                        HStack {
                            Text(sample.time.formatted()).foregroundStyle(.secondary)
                            Spacer()
                            Text("¥" + NSDecimalNumber(decimal: sample.price).stringValue).monospacedDigit()
                            Text(sample.stock >= 1_000_000 ? "库存待确认" : "库存 " + String(sample.stock)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }.padding(24)
        .onAppear { reset() }
        .onChange(of: product) { _, _ in reset(); hover = nil }
        .onChange(of: variant) { _, _ in reset(); hover = nil }
        .onChange(of: quantity) { _, _ in hover = nil }
        .onChange(of: store.history.count) { _, _ in reset() }
        .onChange(of: store.merchant) { _, _ in product = ""; variant = ""; reset() }
    }
}
struct Root: View {
    @EnvironmentObject var store: Store
    @State private var section: StudioSection? = .overview
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("工作台") {
                    ForEach(StudioSection.allCases.filter { $0 != .settings }) { s in Label(s.title, systemImage: s.icon).tag(s) }
                }
                Section("系统") { Label(StudioSection.settings.title, systemImage: StudioSection.settings.icon).tag(StudioSection.settings) }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if !store.error.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(store.error + (store.updated == nil ? "" : "（仍显示上次同步数据）")).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await store.refresh() } }.disabled(store.busy)
                    }.padding(12).background(.quaternary)
                }
                switch section ?? .overview {
                case .overview: Overview { section = $0 }
                case .catalog, .inventory, .prices:
                    CatalogWorkspace(section: section ?? .catalog).id(section)
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.busy ? "同步中" : store.updated == nil ? "未连接" : store.error.isEmpty ? "已同步" : "同步异常").font(.caption).foregroundStyle(.secondary)
                        Button { Task { await store.refresh() } } label: { Label("刷新商城", systemImage: "arrow.clockwise") }.disabled(store.busy || store.merchant.isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 580)
        .task { if store.merchant.isEmpty { section = .settings } else { await store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .init("StudioShowOverview"))) { _ in section = .overview }
    }
}
