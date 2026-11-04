import SwiftUI
import WebKit

private enum Brand {
    static let dark = Color(red: 0.018, green: 0.13, blue: 0.16)
    static let panel = Color(red: 0.035, green: 0.21, blue: 0.25)
    static let mint = Color(red: 0.29, green: 0.88, blue: 0.84)
}

struct SavedBookmark: Codable, Identifiable {
    var id: String { address }
    let name: String
    let address: String
}

@MainActor
final class VaultieState: ObservableObject {
    @Published var address = ""
    @Published var title = "Vaultie"
    @Published var isLoading = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var blockAds = true
    @Published var bookmarks: [SavedBookmark] = []
    @Published var showBookmarks = false
    @Published var showPrivacy = false
    @Published var currentPageIsHome = true
    @Published var errorText: String?
    @Published var showTabs = false
    @Published var showDownloads = false
    @Published var downloadNotice: String?
    @Published var downloadFiles: [URL] = []
    @Published var activeTab = UUID()
    @Published var tabOrder: [UUID] = []
    private var tabViews: [UUID: WKWebView] = [:]
    var webView: WKWebView? { tabViews[activeTab] }

    let websiteStore = WKWebsiteDataStore.nonPersistent()
    private let fileURL: URL
    private let settings = UserDefaults.standard

    init() {
        tabOrder = [activeTab]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaultie", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        var excluded = appSupport
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        fileURL = appSupport.appendingPathComponent("bookmarks.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([SavedBookmark].self, from: data) {
            bookmarks = loaded
        }
        if settings.object(forKey: "blockingEnabled") != nil {
            blockAds = settings.bool(forKey: "blockingEnabled")
        }
    }

    func refreshDownloads() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadFiles = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func registerActiveWebView(_ webView: WKWebView) {
        tabViews[activeTab] = webView
    }

    func selectTab(_ id: UUID) {
        guard tabOrder.contains(id) else { return }
        activeTab = id
        let view = tabViews[id]
        address = view?.url?.absoluteString ?? ""
        title = view?.title ?? "Neuer Tab"
        canBack = view?.canGoBack ?? false
        canForward = view?.canGoForward ?? false
        currentPageIsHome = view?.url == nil || view?.url?.absoluteString == "about:blank"
        showTabs = false
    }

    func newTab() {
        let id = UUID()
        tabOrder.append(id)
        activeTab = id
        currentPageIsHome = true
        address = ""
        title = "Neuer Tab"
        canBack = false
        canForward = false
        showTabs = false
    }

    func closeTab(_ id: UUID) {
        guard let index = tabOrder.firstIndex(of: id) else { return }
        tabViews[id]?.stopLoading()
        tabViews[id]?.removeFromSuperview()
        tabViews.removeValue(forKey: id)
        tabOrder.remove(at: index)
        if tabOrder.isEmpty {
            newTab()
        } else if activeTab == id {
            selectTab(tabOrder[min(index, tabOrder.count - 1)])
        }
    }

    func tabTitle(_ id: UUID) -> String {
        let value = tabViews[id]?.title ?? "Neuer Tab"
        return value.isEmpty ? "Neuer Tab" : value
    }

    func navigate(_ text: String? = nil) {
        let query = (text ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let destination: URL?
        if let url = URL(string: query), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            destination = url
        } else if !query.contains(" "), query.contains("."), !query.contains(":") {
            destination = URL(string: "https://" + query)
        } else {
            var components = URLComponents(string: "https://www.startpage.com/sp/search")
            components?.queryItems = [URLQueryItem(name: "query", value: query)]
            destination = components?.url
        }
        guard let destination else { return }
        currentPageIsHome = false
        webView?.load(URLRequest(url: destination))
    }

    func goHome() {
        currentPageIsHome = true
        address = ""
        title = "Vaultie"
        webView?.loadHTMLString("", baseURL: nil)
    }

    func remember() {
        guard let url = webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !bookmarks.contains(where: { $0.address == url.absoluteString }) else { return }
        bookmarks.append(SavedBookmark(name: webView?.title ?? "Webseite", address: url.absoluteString))
        saveBookmarks()
    }

    func deleteBookmarks(at indexes: IndexSet) {
        bookmarks.remove(atOffsets: indexes)
        saveBookmarks()
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func toggleBlocking() {
        blockAds.toggle()
        settings.set(blockAds, forKey: "blockingEnabled")
        // New tabs/next app launch use the new rule state; rebuild the WKWebView here.
        webView?.configuration.userContentController.removeAllContentRuleLists()
        if blockAds, let web = webView { PrivacyRules.install(on: web) }
        webView?.reload()
    }

    func clearSession() {
        websiteStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in self?.goHome() }
        }
    }
}

private enum PrivacyRules {
    static func install(on webView: WKWebView) {
        let hosts = ["doubleclick.net", "googlesyndication.com", "googleadservices.com",
                     "adnxs.com", "taboola.com", "outbrain.com", "scorecardresearch.com",
                     "adsrvr.org", "criteo.com", "amazon-adsystem.com", "yieldmo.com",
                     "casalemedia.com", "rubiconproject.com", "pubmatic.com", "openx.net",
                     "smartadserver.com", "bidswitch.net", "quantserve.com", "moatads.com",
                     "demdex.net", "advertising.com", "media.net", "lijit.com",
                     "serving-sys.com", "3lift.com", "teads.tv"]
        let rules: [[String: Any]] = hosts.map { domain in
            ["trigger": ["url-filter": "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: domain) + "([/:]|$)"],
             "action": ["type": "block"]]
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: bytes, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "VaultieLocalAdblockV1",
                                                                encodedContentRuleList: json) { list, _ in
            DispatchQueue.main.async {
                if let list { webView.configuration.userContentController.add(list) }
            }
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var model: VaultieState

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.backgroundColor = UIColor(Brand.dark)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        let view: WKWebView
        if let existing = model.webView {
            view = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = model.websiteStore
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = [.audio]
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator
            view.uiDelegate = context.coordinator
            view.allowsBackForwardNavigationGestures = true
            view.isOpaque = false
            view.backgroundColor = UIColor(Brand.dark)
            model.registerActiveWebView(view)
            if model.blockAds { PrivacyRules.install(on: view) }
        }
        if host.subviews.first !== view {
            host.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            host.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let model: VaultieState
        init(model: VaultieState) { self.model = model }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let original = (suggestedFilename as NSString).lastPathComponent
            let safe = original.isEmpty ? "Download" : original
            let name = (safe as NSString).deletingPathExtension
            let ext = (safe as NSString).pathExtension
            var target = documents.appendingPathComponent(safe)
            var number = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let fileName = ext.isEmpty ? "\(name)-\(number)" : "\(name)-\(number).\(ext)"
                target = documents.appendingPathComponent(fileName)
                number += 1
            }
            completionHandler(target)
        }

        func downloadDidFinish(_ download: WKDownload) {
            Task { @MainActor in
                model.refreshDownloads()
                model.downloadNotice = "Download abgeschlossen. Du findest die Datei unter Vaultie in der Dateien-App."
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Task { @MainActor in
                model.downloadNotice = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }

        private func refresh(_ view: WKWebView) {
            guard model.webView === view else { return }
            model.address = view.url?.absoluteString ?? ""
            model.title = view.title ?? "Vaultie"
            model.canBack = view.canGoBack
            model.canForward = view.canGoForward
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            refresh(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            refresh(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
            if (error as NSError).code != NSURLErrorCancelled { model.errorText = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.isLoading = false
            model.errorText = error.localizedDescription
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

struct VaultieScreen: View {
    @StateObject private var model = VaultieState()
    @FocusState private var editAddress: Bool
    private let starters: [(String, String, String)] = [
        ("YouTube", "play.rectangle.fill", "https://youtube.com"),
        ("Startpage", "magnifyingglass", "https://startpage.com"),
        ("WhatsApp", "message.fill", "https://web.whatsapp.com"),
        ("Lesezeichen", "bookmark.fill", "vaultie:bookmarks")
    ]

    var body: some View {
        ZStack {
            Brand.dark.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image("VaultieMark").resizable().scaledToFit().frame(width: 27, height: 27)
                    TextField("Adresse oder Suche", text: $model.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($editAddress)
                        .onSubmit { model.navigate(); editAddress = false }
                        .foregroundStyle(.white)
                    Button { model.navigate(); editAddress = false } label: {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(Brand.mint)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Brand.panel, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)

                ZStack {
                    BrowserWebView(model: model)
                        .opacity(model.currentPageIsHome ? 0 : 1)
                    if model.currentPageIsHome {
                        home
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isLoading { ProgressView().tint(Brand.mint).padding(5) }
                HStack {
                    nav("chevron.left", enabled: model.canBack) {
                        model.currentPageIsHome = false
                        model.webView?.goBack()
                    }
                    Spacer()
                    nav("chevron.right", enabled: model.canForward) {
                        model.currentPageIsHome = false
                        model.webView?.goForward()
                    }
                    Spacer()
                    nav("house", enabled: true) { model.goHome() }
                    Spacer()
                    nav("star", enabled: true) { model.remember() }
                    Spacer()
                    Button { model.showTabs = true } label: {
                        Image(systemName: "square.on.square")
                            .overlay(alignment: .topTrailing) {
                                Text("\(model.tabOrder.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .offset(x: 8, y: -7)
                            }
                            .frame(width: 35, height: 38)
                    }
                    Spacer()
                    Menu {
                        Button("Neuer Tab", systemImage: "plus") { model.newTab() }
                        Button("Tabs", systemImage: "square.on.square") { model.showTabs = true }
                        Button("Lesezeichen", systemImage: "bookmark") { model.showBookmarks = true }
                        Button(model.blockAds ? "Werbeblocker deaktivieren" : "Werbeblocker aktivieren",
                               systemImage: "hand.raised") { model.toggleBlocking() }
                        Button("Downloads", systemImage: "arrow.down.circle") {
                            model.refreshDownloads()
                            model.showDownloads = true
                        }
                        Button("Sitzungsdaten löschen", systemImage: "trash") { model.clearSession() }
                        Button("Datenschutz", systemImage: "lock.shield") { model.showPrivacy = true }
                    } label: { Image(systemName: "line.3.horizontal").frame(width: 35, height: 38) }
                }
                .font(.title3).foregroundStyle(Brand.mint)
                .padding(.horizontal, 20).padding(.vertical, 6)
                .background(Brand.panel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showTabs) {
            NavigationStack {
                List {
                    ForEach(model.tabOrder, id: \.self) { id in
                        HStack {
                            Button {
                                model.selectTab(id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.tabTitle(id)).lineLimit(1)
                                    Text(id == model.activeTab ? "Aktiver Tab" : "Öffnen")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) { model.closeTab(id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .navigationTitle("Tabs")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fertig") { model.showTabs = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.newTab() } label: { Image(systemName: "plus") }
                    }
                }
            }
        }
        .sheet(isPresented: $model.showDownloads) {
            NavigationStack {
                List(model.downloadFiles, id: \.self) { file in
                    ShareLink(item: file) {
                        Label(file.lastPathComponent, systemImage: "doc")
                    }
                }
                .navigationTitle("Lokale Downloads")
                .toolbar {
                    Button("Fertig") { model.showDownloads = false }
                }
            }
        }
        .sheet(isPresented: $model.showBookmarks) {
            NavigationStack {
                List {
                    ForEach(model.bookmarks) { bookmark in
                        Button {
                            model.showBookmarks = false
                            model.navigate(bookmark.address)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark.name).foregroundStyle(.primary)
                                Text(bookmark.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete(perform: model.deleteBookmarks)
                }
                .navigationTitle("Lokale Lesezeichen")
                .toolbar { Button("Fertig") { model.showBookmarks = false } }
            }
        }
        .alert("Download", isPresented: Binding(
            get: { model.downloadNotice != nil },
            set: { if !$0 { model.downloadNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.downloadNotice = nil }
        } message: {
            Text(model.downloadNotice ?? "")
        }
        .alert("Datenschutz", isPresented: $model.showPrivacy) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Der Verlauf wird von Vaultie nicht dauerhaft gespeichert. Website-Cookies und Webspeicher verwenden einen nichtpersistenten WebKit-Datenspeicher. Lesezeichen liegen lokal auf diesem iPhone; Cloud-Synchronisierung und VPN sind nicht integriert. Webseiten können technisch notwendige Verbindungsdaten erhalten. Der Werbeblocker ist eine einfache lokale Filterliste, kein vollständiger Tracking-Schutz.")
        }
        .alert("Seite konnte nicht geladen werden", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) { Button("OK", role: .cancel) { model.errorText = nil } } message: {
            Text(model.errorText ?? "Unbekannter Fehler")
        }
    }

    private func nav(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 35, height: 38) }
            .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 12)
                Image("VaultieMark").resizable().scaledToFit()
                    .frame(width: 88, height: 88)
                Text("Vaultie").font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Privat surfen. Lokal speichern.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.74))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(starters, id: \.0) { item in
                        Button {
                            if item.2 == "vaultie:bookmarks" { model.showBookmarks = true }
                            else { model.navigate(item.2) }
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: item.1).font(.title2)
                                Text(item.0).font(.subheadline)
                            }
                            .foregroundStyle(.white).frame(maxWidth: .infinity)
                            .frame(height: 72)
                            .background(Brand.panel, in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
                .padding(.horizontal, 17)
                Label("Der Verlauf wird niemals gespeichert.", systemImage: "clock.badge.xmark")
                    .font(.footnote).foregroundStyle(Brand.mint).padding(.top, 8)
                Text("Kein integriertes VPN · Keine Cloud-Synchronisierung")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 10)
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Brand.panel, Brand.dark, .black.opacity(0.93)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

@main
struct VaultieApp: App {
    var body: some Scene {
        WindowGroup { VaultieScreen() }
    }
}
