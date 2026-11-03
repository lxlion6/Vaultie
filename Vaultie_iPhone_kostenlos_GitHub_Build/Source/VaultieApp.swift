import SwiftUI
import WebKit

private enum Brand {
    static let dark = Color(red: 0.018, green: 0.13, blue: 0.16)
    static let panel = Color(red: 0.035, green: 0.21, blue: 0.25)
    static let mint = Color(red: 0.29, green: 0.88, blue: 0.84)
}

private struct SavedBookmark: Codable, Identifiable {
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
    weak var webView: WKWebView?

    let websiteStore = WKWebsiteDataStore.nonPersistent()
    private let fileURL: URL
    private let settings = UserDefaults.standard

    init() {
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
                     "adsrvr.org", "criteo.com", "amazon-adsystem.com"]
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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = model.websiteStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(Brand.dark)
        model.webView = view
        if model.blockAds { PrivacyRules.install(on: view) }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: VaultieState
        init(model: VaultieState) { self.model = model }

        private func refresh(_ view: WKWebView) {
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
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)

                ZStack {
                    BrowserWebView(model: model)
                        .opacity(model.currentPageIsHome ? 0 : 1)
                    if model.currentPageIsHome {
                        home
                    }
                }
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
                    Menu {
                        Button("Lesezeichen", systemImage: "bookmark") { model.showBookmarks = true }
                        Button(model.blockAds ? "Werbeblocker deaktivieren" : "Werbeblocker aktivieren",
                               systemImage: "hand.raised") { model.toggleBlocking() }
                        Button("Sitzungsdaten löschen", systemImage: "trash") { model.clearSession() }
                        Button("Datenschutz", systemImage: "lock.shield") { model.showPrivacy = true }
                    } label: { Image(systemName: "line.3.horizontal").frame(width: 35, height: 38) }
                }
                .font(.title3).foregroundStyle(Brand.mint)
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(Brand.panel)
            }
        }
        .preferredColorScheme(.dark)
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
            VStack(spacing: 23) {
                Spacer(minLength: 40)
                Image("VaultieMark").resizable().scaledToFit()
                    .frame(width: 145, height: 145)
                Text("Vaultie").font(.system(size: 33, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Privat surfen. Lokal speichern.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.74))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 13) {
                    ForEach(starters, id: \.0) { item in
                        Button {
                            if item.2 == "vaultie:bookmarks" { model.showBookmarks = true }
                            else { model.navigate(item.2) }
                        } label: {
                            VStack(spacing: 11) {
                                Image(systemName: item.1).font(.title2)
                                Text(item.0).font(.subheadline)
                            }
                            .foregroundStyle(.white).frame(maxWidth: .infinity)
                            .frame(height: 93)
                            .background(Brand.panel, in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
                .padding(.horizontal, 17)
                Label("Der Verlauf wird niemals gespeichert.", systemImage: "clock.badge.xmark")
                    .font(.footnote).foregroundStyle(Brand.mint).padding(.top, 8)
                Text("Kein integriertes VPN · Keine Cloud-Synchronisierung")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 50)
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
