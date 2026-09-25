import SwiftUI
import WebKit

public enum BeautyRadioEnvironment {
    public static let baseURL = URL(string: "https://panel.seldagencerbeauty.com")!
}

@main
struct BeautyRadioApp: App {
    @StateObject private var session: RadioSession
    /// One channel manager for the life of the process. It is created here, at
    /// launch, rather than when a view appears: when a Push to Talk
    /// notification relaunches a terminated app in the background no view may
    /// ever be drawn, and the system can only restore the channel and deliver
    /// the push to a manager that already exists.
    private let pushToTalk: RadioPushToTalkManager

    init() {
        let session = RadioSession(baseURL: BeautyRadioEnvironment.baseURL)
        _session = StateObject(wrappedValue: session)
        let pushToTalk = RadioPushToTalkManager(session: session)
        self.pushToTalk = pushToTalk
        if RadioCredentials.shared.isLoggedIn {
            Task { @MainActor in await pushToTalk.start() }
        }
    }

    var body: some Scene {
        WindowGroup { RootView(session: session, pushToTalk: pushToTalk) }
    }
}

struct RootView: View {
    @ObservedObject var session: RadioSession
    let pushToTalk: RadioPushToTalkManager
    @State private var isLoggedIn = RadioCredentials.shared.isLoggedIn

    var body: some View {
        Group {
            if isLoggedIn {
                // The radio is the first thing a signed-in user sees, and the
                // channel was already joined at launch.
                MainTabs(session: session, pushToTalk: pushToTalk, onLogOut: { isLoggedIn = false })
            } else {
                LoginView(session: session, onLoggedIn: {
                    isLoggedIn = true
                    Task { await pushToTalk.start() }
                })
            }
        }
        // The server ended the session (logout on another screen, password
        // change, account disabled): go back to the login screen.
        .onChange(of: session.sessionEnded) { _, ended in
            if ended { isLoggedIn = false }
        }
    }
}

struct MainTabs: View {
    @ObservedObject var session: RadioSession
    let pushToTalk: RadioPushToTalkManager
    var onLogOut: () -> Void
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            RadioView(session: session, pushToTalk: pushToTalk)
                .tabItem { Label("Telsiz", systemImage: "dot.radiowaves.left.and.right") }
                .tag(0)

            PanelWebView(baseURL: session.baseURL)
                .ignoresSafeArea(edges: .bottom)
                .tabItem { Label("Panel", systemImage: "square.grid.2x2") }
                .tag(1)

            SettingsView(session: session, onLogOut: onLogOut)
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                .tag(2)
        }
    }
}

struct LoginView: View {
    @ObservedObject var session: RadioSession
    var onLoggedIn: () -> Void
    @State private var identifier = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Selda Gençer Beauty").font(.title2.bold())
            TextField("E-posta veya kullanıcı adı", text: $identifier)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Şifre", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(isBusy ? "Giriş yapılıyor…" : "Giriş yap") { logIn() }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || identifier.isEmpty || password.isEmpty)
            Spacer()
        }
        .padding(24)
    }

    private func logIn() {
        isBusy = true
        error = nil
        Task {
            do {
                try await session.logIn(identifier: identifier, password: password)
                onLoggedIn()
            } catch {
                self.error = error.localizedDescription
            }
            isBusy = false
        }
    }
}

/// The CRM panel stays the existing web app. Before the first page loads, the
/// stored staff JWT goes into `localStorage.authToken` (the key
/// `frontend/js/auth.js` reads) and both session cookies go into the web view's
/// cookie store. With the refresh cookie in place the server renews the panel's
/// access token by itself, so the embedded panel never shows its own login
/// screen either. The refresh token is not rotated on use, so sharing it with
/// the native side cannot lock either one out.
struct PanelWebView: UIViewRepresentable {
    let baseURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        if let token = RadioCredentials.shared.staffToken {
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            controller.addUserScript(WKUserScript(
                source: "try{localStorage.setItem('authToken','\(escaped)');}catch(e){}",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // auth.js looks for this token to recognise the native wrapper.
        webView.customUserAgent = "SeldaBeautyIosWebView"

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            await Self.installSessionCookies(in: cookieStore, host: baseURL.host ?? "")
            webView.load(URLRequest(url: baseURL.appendingPathComponent("login")))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    private static func installSessionCookies(in store: WKHTTPCookieStore, host: String) async {
        let credentials = RadioCredentials.shared
        var cookies: [(name: String, value: String, lifetime: TimeInterval)] = []
        if let access = credentials.staffToken { cookies.append(("authToken", access, 4 * 3600)) }
        if let refresh = credentials.refreshToken { cookies.append(("staffRefreshToken", refresh, 365 * 86400)) }

        for cookie in cookies {
            guard let httpCookie = HTTPCookie(properties: [
                .domain: host,
                .path: "/",
                .name: cookie.name,
                .value: cookie.value,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(cookie.lifetime),
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
                HTTPCookiePropertyKey("HttpOnly"): "TRUE"
            ]) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(httpCookie) { continuation.resume() }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var session: RadioSession
    var onLogOut: () -> Void

    var body: some View {
        Form {
            Section("Telsiz") {
                LabeledContent("Durum", value: session.isJoined ? "Bağlı" : "Bağlanıyor")
                LabeledContent("Ses çıkışı", value: session.outputRoute.isEmpty ? "-" : session.outputRoute)
                LabeledContent("Kanal", value: RadioCredentials.shared.channel)
            }
            Section {
                Button("Çıkış yap", role: .destructive) {
                    Task {
                        await session.logOut()
                        onLogOut()
                    }
                }
            }
        }
    }
}
