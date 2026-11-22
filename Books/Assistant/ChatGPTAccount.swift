import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import Security

/// A model the signed-in ChatGPT account can use, from its model catalog.
struct ChatGPTModel: Codable, Hashable, Identifiable {
    var slug: String
    var name: String
    var detail: String
    var efforts: [String]
    var defaultEffort: String?

    var id: String { slug }
    var symbol: String {
        let s = slug.lowercased()
        if s.contains("astra") { return "brain" }
        if s.contains("luna") || s.contains("mini") { return "bolt" }
        return "sparkle"
    }

    static let fallback = ChatGPTModel(slug: "gpt-6.2-sol", name: "GPT-6.2-Sol", detail: "Fast, go-to model for everyday work.",
                                       efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "low")

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra High"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    static func effortDetail(_ effort: String) -> String {
        switch effort {
        case "minimal", "none": "Answers right away"
        case "low": "Quickest replies"
        case "medium": "Balanced"
        case "high": "Thinks it through"
        case "xhigh": "Thinks longer"
        case "max": "Thinks hardest, slower"
        case "ultra": "Thinks longest, slowest"
        default: ""
        }
    }
}

enum ChatGPTAuthError: LocalizedError {
    case declined
    case planUsageNotGranted
    case otherAccount
    case invalidResponse(String)
    case sessionEnded

    var errorDescription: String? {
        switch self {
        case .declined: "Sign-in was cancelled in the browser."
        case .planUsageNotGranted: "Books needs permission to use your ChatGPT plan. Continue with ChatGPT again and allow it."
        case .otherAccount: "That’s a different ChatGPT account. Choose Use Another Account to switch."
        case .invalidResponse(let message): message
        case .sessionEnded: "Your ChatGPT session ended. Continue with ChatGPT to sign in again."
        }
    }
}

/// Sign in with ChatGPT for open-source apps: the reader authorizes Books to use their ChatGPT plan,
/// and Books calls the Responses API with the resulting OAuth access token.
@MainActor @Observable
final class ChatGPTAccount {
    static let shared = ChatGPTAccount()

    enum Status: Equatable { case signedOut, signingIn, signedIn }

    private(set) var status: Status = .signedOut
    private(set) var email: String?
    private(set) var models: [ChatGPTModel]
    /// Why the last sign-in or session failed, for the sign-in card.
    var problem: String?
    /// Set when ChatGPT reports a usage limit; new questions wait until the reader tries again.
    var usageLimitReached = false
    /// Whether "Use Another Account" makes sense: a previous account is remembered.
    var hasSavedAccount: Bool { lastRegistration != nil }

    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private static let log = Logger(subsystem: "com.zyu.books", category: "ChatGPT")

    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var refreshTask: Task<Credentials, Error>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var callback: LoopbackCallback?

    private init() {
        models = (UserDefaults.standard.data(forKey: Keys.models)).flatMap { try? JSONDecoder().decode([ChatGPTModel].self, from: $0) } ?? []
        if let saved = Keychain.load() {
            credentials = saved
            email = saved.email
            status = .signedIn
            if lastRegistration == nil {
                remember(Registration(subject: saved.subject, clientID: saved.clientID, email: saved.email, idToken: saved.idToken, needsConsent: false))
            }
            Task { await loadModels() }
        }
    }

    // MARK: Sign in

    func signIn(anotherAccount: Bool = false) {
        guard status != .signingIn else { return }
        let previous = status
        problem = nil
        status = .signingIn
        signInTask = Task {
            do {
                let creds = try await authorize(registration: anotherAccount ? nil : lastRegistration)
                credentials = creds
                email = creds.email
                status = .signedIn
                usageLimitReached = false
                NSApp.activate()
                NSApp.requestUserAttention(.informationalRequest)
                if !UserDefaults.standard.bool(forKey: Keys.welcomed) {
                    UserDefaults.standard.set(true, forKey: Keys.welcomed)
                    Self.showPlanWelcome()
                }
                await loadModels()
            } catch {
                status = credentials != nil && previous == .signedIn ? .signedIn : .signedOut
                if !(error is CancellationError) { problem = error.localizedDescription }
            }
            callback?.stop()
            callback = nil
            signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        callback?.cancel()
    }

    func signOut() async -> Bool {
        let creds = credentials
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        email = nil
        status = .signedOut
        Keychain.delete()
        if var registration = lastRegistration {
            registration.idToken = nil
            remember(registration)
        }
        guard let creds else { return true }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt))) }
            var request = URLRequest(url: Endpoint.revoke)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": creds.refreshToken, "token_type_hint": "refresh_token", "client_id": creds.clientID])
            if let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse,
               http.statusCode < 500 {
                return http.statusCode == 200
            }
        }
        return false
    }

    private func authorize(registration: Registration?) async throws -> Credentials {
        let server = LoopbackCallback()
        callback = server
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(32)
        let nonce = Self.randomURLSafe(32)

        var query: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", registration?.clientID ?? "dynamic_agent_client"),
            ("redirect_uri", redirect),
            ("scope", Self.scopes),
            ("resource", Endpoint.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("ext_agent_host_id", Self.hostID),
        ]
        if let registration {
            if let hint = registration.idToken { query.append(("id_token_hint", hint)) }
            if let email = registration.email { query.append(("login_hint", email)) }
            if registration.needsConsent { query.append(("prompt", "consent")) }
        } else {
            query.append(("agent_name_hint", "Books"))
        }
        var components = URLComponents(url: Endpoint.authorize, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.map { "\($0)=\(Self.encode($1))" }.joined(separator: "&")
        NSWorkspace.shared.open(components.url!)

        let params = try await server.wait()
        guard params["state"] == state else { throw ChatGPTAuthError.invalidResponse("The sign-in response didn’t match this request. Try again.") }
        if let error = params["error"] {
            if error == "access_denied" { throw ChatGPTAuthError.declined }
            throw ChatGPTAuthError.invalidResponse(params["error_description"] ?? "Sign-in failed (\(error)).")
        }
        guard let code = params["code"], !code.isEmpty else { throw ChatGPTAuthError.invalidResponse("Sign-in returned no authorization code.") }
        let clientID: String
        if let registration {
            if let issued = params["client_id"], issued != registration.clientID { throw ChatGPTAuthError.otherAccount }
            clientID = registration.clientID
        } else {
            guard let issued = params["client_id"], !issued.isEmpty else {
                throw ChatGPTAuthError.invalidResponse("ChatGPT didn’t finish registering Books. Try again.")
            }
            clientID = issued
        }

        let tokens = try await Self.tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Endpoint.resource,
        ])
        guard let idToken = tokens.idToken else { throw ChatGPTAuthError.invalidResponse("Sign-in returned no ID token.") }
        let identity = try await IDToken.verify(idToken, clientID: clientID, nonce: nonce)
        if let registration, registration.subject != identity.subject { throw ChatGPTAuthError.otherAccount }

        let scopes = tokens.scope?.split(separator: " ").map(String.init) ?? []
        var saved = Registration(subject: identity.subject, clientID: clientID, email: identity.email, idToken: idToken, needsConsent: false)
        guard scopes.contains("chatgpt.tokens.use.direct"), let refresh = tokens.refreshToken else {
            saved.needsConsent = true
            remember(saved)
            throw ChatGPTAuthError.planUsageNotGranted
        }
        remember(saved)
        let creds = Credentials(subject: identity.subject, email: identity.email, clientID: clientID, idToken: idToken,
                                accessToken: tokens.accessToken, refreshToken: refresh, scopes: scopes,
                                expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600)))
        Keychain.save(creds)
        return creds
    }

    // MARK: Access tokens

    /// A current access token, refreshed first when it's about to expire or `force` is set.
    func accessToken(force: Bool = false) async throws -> String {
        guard let creds = credentials else { throw ChatGPTAuthError.sessionEnded }
        if !force, creds.expiresAt.timeIntervalSinceNow > 120 { return creds.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await Self.refresh(creds) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            guard credentials?.subject == renewed.subject else { throw CancellationError() }
            credentials = renewed
            Keychain.save(renewed)
            return renewed.accessToken
        } catch let error as TokenError where error.isTerminal {
            sessionEnded()
            throw ChatGPTAuthError.sessionEnded
        }
    }

    /// The server rejected the session for good: keep the registration, drop the tokens.
    func sessionEnded() {
        credentials = nil
        Keychain.delete()
        status = .signedOut
        problem = ChatGPTAuthError.sessionEnded.localizedDescription
    }

    private static func refresh(_ creds: Credentials) async throws -> Credentials {
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token", "client_id": creds.clientID,
            "refresh_token": creds.refreshToken, "resource": Endpoint.resource,
        ])
        var renewed = creds
        renewed.accessToken = tokens.accessToken
        if let refresh = tokens.refreshToken { renewed.refreshToken = refresh }
        if let id = tokens.idToken { renewed.idToken = id }
        if let scope = tokens.scope { renewed.scopes = scope.split(separator: " ").map(String.init) }
        renewed.expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600))
        return renewed
    }

    // MARK: Models

    func loadModels() async {
        guard let token = try? await accessToken() else { return }
        var request = URLRequest(url: Endpoint.models)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.error("Model list failed: HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            return
        }
        var list: [ChatGPTModel] = []
        if let catalog = json["models"] as? [[String: Any]] {
            for m in catalog where (m["visibility"] as? String ?? "list") == "list" {
                guard let slug = m["slug"] as? String else { continue }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
                list.append(ChatGPTModel(slug: slug, name: m["display_name"] as? String ?? slug, detail: m["description"] as? String ?? "",
                                         efforts: efforts, defaultEffort: m["default_reasoning_level"] as? String))
            }
        } else if let data = json["data"] as? [[String: Any]] {
            list = data.compactMap { $0["id"] as? String }.map {
                ChatGPTModel(slug: $0, name: $0, detail: "", efforts: ["low", "medium", "high"], defaultEffort: nil)
            }
        }
        guard !list.isEmpty else { return }
        models = list
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Keys.models)
    }

    // MARK: Plan welcome

    /// Runs from the run loop rather than the main queue, so main-actor work keeps going while the alert is up.
    private static func showPlanWelcome() {
        RunLoop.main.perform { presentPlanWelcome() }
    }

    private static func presentPlanWelcome() {
        let alert = NSAlert()
        alert.messageText = "You’re using your ChatGPT plan"
        alert.informativeText = "Questions you ask in Books use your ChatGPT plan. You can review and manage Books’ usage in ChatGPT settings."
        alert.addButton(withTitle: "Got It")
        alert.addButton(withTitle: "Manage Usage")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(usageURL) }
    }

    // MARK: Registrations

    private struct Registration: Codable {
        var subject: String
        var clientID: String
        var email: String?
        var idToken: String?
        var needsConsent: Bool
    }

    private var lastRegistration: Registration? {
        Keychain.load(Registration.self, account: "registration")
    }

    private func remember(_ registration: Registration) {
        Keychain.save(registration, account: "registration")
    }

    /// Stable, opaque identifier for this Mac's installation of Books.
    private static var hostID: String {
        if let id = UserDefaults.standard.string(forKey: Keys.hostID) { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: Keys.hostID)
        return id
    }

    private enum Keys {
        static let hostID = "chatGPTHostID"
        static let models = "chatGPTModels"
        static let welcomed = "chatGPTPlanWelcomed"
    }

    // MARK: OAuth plumbing

    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    enum Endpoint {
        static let issuer = "https://auth.openai.com"
        static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
        static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
        static let revoke = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
        static let jwks = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
        static let resource = "https://api.openai.com/v1"
        static let models = URL(string: "https://api.openai.com/v1/models")!
        static let responses = URL(string: "https://api.openai.com/v1/responses")!
    }

    private struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var scope: String?
        var expiresIn: Int?
    }

    private struct TokenError: LocalizedError {
        var code: String?
        var message: String
        var isTerminal: Bool {
            ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused", "invalid_client"].contains(code ?? "")
        }
        var errorDescription: String? { message }
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Endpoint.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            let nested = json["error"] as? [String: Any]
            let code = json["error"] as? String ?? nested?["code"] as? String
            let message = json["error_description"] as? String ?? nested?["message"] as? String
                ?? "ChatGPT sign-in failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            throw TokenError(code: code, message: message)
        }
        return TokenResponse(accessToken: access, refreshToken: json["refresh_token"] as? String, idToken: json["id_token"] as? String,
                             scope: json["scope"] as? String, expiresIn: (json["expires_in"] as? NSNumber)?.intValue)
    }

    private static func form(_ fields: [String: String]) -> Data {
        Data(fields.map { "\($0)=\(encode($1))" }.joined(separator: "&").utf8)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URLEncoded
    }
}

// MARK: - Credentials

private struct Credentials: Codable {
    var subject: String
    var email: String?
    var clientID: String
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var scopes: [String]
    var expiresAt: Date
}

/// Generic-password items for the sign-in: `credentials` (tokens) and `registration` (issued client ID and hints).
private enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.zyu.books.chatgpt", kSecAttrAccount as String: account]
    }

    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query(account) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Books ChatGPT sign-in"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }

    static func load() -> Credentials? { load(Credentials.self, account: "credentials") }
    static func save(_ creds: Credentials) { save(creds, account: "credentials") }
    static func delete() { delete(account: "credentials") }
}

// MARK: - ID token

private enum IDToken {
    struct Identity { var subject: String; var email: String? }

    /// Checks the RS256 signature against OpenAI's JWKS, then issuer, audience, expiry and nonce.
    static func verify(_ token: String, clientID: String, nonce: String) async throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = Data(base64URL: String(parts[0])), let payloadData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError.invalidResponse("The ChatGPT ID token is malformed.")
        }
        guard header["alg"] as? String == "RS256", let key = try await signingKey(kid: header["kid"] as? String) else {
            throw ChatGPTAuthError.invalidResponse("The ChatGPT ID token’s signing key is unknown.")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw ChatGPTAuthError.invalidResponse("The ChatGPT ID token’s signature is invalid.")
        }
        let audience = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        let expiry = (claims["exp"] as? NSNumber)?.doubleValue ?? 0
        guard claims["iss"] as? String == ChatGPTAccount.Endpoint.issuer, audience.contains(clientID),
              expiry + 5 > Date().timeIntervalSince1970, claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTAuthError.invalidResponse("The ChatGPT ID token didn’t match this sign-in.")
        }
        let email = claims["email_verified"] as? Bool == true ? claims["email"] as? String : nil
        return Identity(subject: subject, email: email)
    }

    private static func signingKey(kid: String?) async throws -> SecKey? {
        let (data, _) = try await URLSession.shared.data(from: ChatGPTAccount.Endpoint.jwks)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { kid == nil || $0["kid"] as? String == kid }),
              jwk["kty"] as? String == "RSA",
              let n = (jwk["n"] as? String).flatMap(Data.init(base64URL:)),
              let e = (jwk["e"] as? String).flatMap(Data.init(base64URL:)) else { return nil }
        let der = DER.sequence(DER.integer(n) + DER.integer(e))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    /// Just enough ASN.1 DER for a PKCS#1 RSAPublicKey.
    private enum DER {
        static func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }

        static func integer(_ value: Data) -> Data {
            var v = Data(value.drop { $0 == 0 })
            if v.isEmpty || v.first! & 0x80 != 0 { v.insert(0, at: 0) }
            return Data([0x02]) + length(v.count) + v
        }

        static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
    }
}

// MARK: - Loopback callback

/// Receives the browser's OAuth redirect on 127.0.0.1.
@MainActor
private final class LoopbackCallback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var result: CheckedContinuation<[String: String], Error>?
    private var received: [String: String]?
    private var failure: Error?

    /// Binds 1455 when free, otherwise any port; only the port may vary between sign-ins.
    func start() async throws -> UInt16 {
        if let port = try? await bind(1455) { return port }
        return try await bind(nil)
    }

    private func bind(_ port: UInt16?) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.ready?.resume(returning: l.port?.rawValue ?? 0)
                        self.ready = nil
                    case .failed(let error), .waiting(let error):
                        l.cancel()
                        self.ready?.resume(throwing: error)
                        self.ready = nil
                    default: break
                    }
                }
            }
            l.start(queue: .main)
        }
    }

    /// Waits up to ten minutes for the redirect.
    func wait() async throws -> [String: String] {
        if let received { return received }
        if let failure { throw failure }
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(600))
            self?.finish(.failure(ChatGPTAuthError.invalidResponse("Sign-in timed out. Try again.")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        switch outcome {
        case .success(let params): received = params
        case .failure(let error): failure = error
        }
        result?.resume(with: outcome)
        result = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, head: String(decoding: buffer, as: UTF8.self))
                } else if error != nil || done || buffer.count > 65536 {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let target = head.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        var status = "404 Not Found"
        var body = ""
        if components?.path == "/auth/callback", received == nil, failure == nil {
            var params: [String: String] = [:]
            for item in components?.queryItems ?? [] { params[item.name] = item.value ?? "" }
            let ok = params["error"] == nil
            status = "200 OK"
            body = Self.page(ok ? "You’re signed in to Books" : "Sign-in didn’t finish",
                             ok ? "You can close this tab and return to Books." : "Return to Books to try again.")
            finish(.success(params))
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(_ title: String, _ message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Books</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;color:#222}
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}h1{font-size:22px;font-weight:600}</style></head>
        <body><div><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }
}

// MARK: - Base64URL

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
