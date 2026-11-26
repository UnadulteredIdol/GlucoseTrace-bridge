import Foundation
import CryptoKit

// ---------------------------------------------------------------------------
// CGM follower services as data sources, next to Nightscout. Both are the
// services behind the manufacturers' own "follow" apps; neither has a public
// API, so this uses the same unofficial access as other open-source follower
// apps. Either can change without notice and stop working until updated.
// They give glucose and trend only: no IOB, COB or loop status.
// ---------------------------------------------------------------------------

/// One CGM reading in mg/dL; direction uses Nightscout's names ("Flat", ...).
struct CGMReading {
    let mgdl: Int
    let time: Date
    let direction: String?
}

enum CloudSourceError: LocalizedError {
    case credentials(String)    // wrong login or an account step needed: don't retry until fixed
    case service(String)        // anything else: retried at the next fetch
    var errorDescription: String? {
        switch self { case .credentials(let m), .service(let m): return m }
    }
}

@MainActor
protocol CloudSource: AnyObject {
    /// Readings of the last ~3 hours, newest first.
    func fetchReadings() async throws -> [CGMReading]
}

// MARK: - LibreLinkUp (Abbott, Libre 2 / Libre 3 via the LibreLink app)
// The user shares their data with a LibreLinkUp follower account (their own
// is fine) and enters that login here. Login tells the client which regional
// server holds the account. Since LibreLinkUp 4.12 every request after login
// also needs the SHA-256 of the account's user id.
@MainActor
final class LibreLinkUpClient: CloudSource {
    // The app version Abbott's server expects; bump it when logins start
    // failing with "update the app". 4.17.0 since December 2025 (the version
    // xDrip4iOS sends too).
    private static let appVersion = "4.17.0"
    private static let globalBase = "https://api.libreview.io"

    private let email: String
    private let password: String
    private let session: URLSession
    private var base = LibreLinkUpClient.globalBase
    private var token: String?
    private var accountId: String?
    private var patientId: String?
    private var userId: String?

    init(email: String, password: String, session: URLSession) {
        self.email = email; self.password = password; self.session = session
    }

    func fetchReadings() async throws -> [CGMReading] {
        if token == nil { try await login() }
        do {
            return try await graph()
        } catch CloudSourceError.service(let m) where m == "401" {
            token = nil; patientId = nil // token expired: log in once more
            try await login()
            return try await graph()
        }
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw CloudSourceError.service("LibreLinkUp: bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = body == nil ? "GET" : "POST"
        for (k, v) in ["product": "llu.ios", "version": Self.appVersion, "Accept": "application/json",
                       "Content-Type": "application/json", "Cache-Control": "no-cache"] {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let accountId { req.setValue(accountId, forHTTPHeaderField: "Account-Id") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw CloudSourceError.service("401") }
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudSourceError.service("LibreLinkUp: HTTP \(code)")
        }
        return json
    }

    private func login() async throws {
        token = nil; accountId = nil
        var json = try await request("/llu/auth/login", body: ["email": email, "password": password])
        // Accounts live on regional servers; the global one redirects once.
        if let data = json["data"] as? [String: Any], data["redirect"] as? Bool == true,
           let region = data["region"] as? String,
           region.count <= 8, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { // it goes into the host name the password is sent to
            base = "https://api-\(region).libreview.io"
            json = try await request("/llu/auth/login", body: ["email": email, "password": password])
        }
        let status = (json["status"] as? NSNumber)?.intValue ?? -1
        let data = json["data"] as? [String: Any]
        if status == 4 || data?["step"] != nil {
            throw CloudSourceError.credentials("LibreLinkUp: open the LibreLinkUp app once and accept the new terms")
        }
        // An outdated version header is refused with status 920 and the
        // minimum version (as documented by the community); retrying won't help.
        if status == 920 || data?["minimumVersion"] != nil {
            let minimum = (data?["minimumVersion"] as? String).map { " (\($0) or newer)" } ?? ""
            throw CloudSourceError.credentials("LibreLinkUp wants a newer app version\(minimum) than this bridge sends: update the bridge")
        }
        guard status == 0,
              let ticket = (data?["authTicket"] as? [String: Any])?["token"] as? String,
              let userId = (data?["user"] as? [String: Any])?["id"] as? String else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw CloudSourceError.credentials("LibreLinkUp: login failed" + (message.map { " (\($0))" } ?? ""))
        }
        token = ticket
        self.userId = userId
        accountId = SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func graph() async throws -> [CGMReading] {
        if patientId == nil {
            let json = try await request("/llu/connections")
            // Your own data first when the account also follows others.
            let list = (json["data"] as? [[String: Any]]) ?? []
            guard let connection = list.first(where: { $0["patientId"] as? String == userId }) ?? list.first,
                  let id = connection["patientId"] as? String else {
                throw CloudSourceError.credentials("LibreLinkUp: nobody shares data with this account yet")
            }
            patientId = id
        }
        let json = try await request("/llu/connections/\(patientId!)/graph")
        guard let data = json["data"] as? [String: Any] else { throw CloudSourceError.service("LibreLinkUp: no data") }
        var readings: [CGMReading] = []
        if let current = (data["connection"] as? [String: Any])?["glucoseMeasurement"] as? [String: Any],
           let reading = Self.reading(current, withTrend: true) {
            readings.append(reading)
        }
        for item in (data["graphData"] as? [[String: Any]]) ?? [] {
            if let reading = Self.reading(item, withTrend: false) { readings.append(reading) }
        }
        return readings.sorted { $0.time > $1.time }
    }

    // FactoryTimestamp is UTC ("11/1/2026 2:04:31 PM"); Timestamp is the
    // phone's local time and isn't used.
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f
    }()
    // TrendArrow 1-5, falling fast to rising fast; Libre has no double arrows.
    private static let trendNames = [1: "SingleDown", 2: "FortyFiveDown", 3: "Flat", 4: "FortyFiveUp", 5: "SingleUp"]

    static func reading(_ item: [String: Any], withTrend: Bool) -> CGMReading? {
        guard let mgdl = (item["ValueInMgPerDl"] as? NSNumber)?.intValue, mgdl > 0,
              let stamp = item["FactoryTimestamp"] as? String,
              let time = timeFormat.date(from: stamp) else { return nil }
        let trend = withTrend ? (item["TrendArrow"] as? NSNumber).flatMap { trendNames[$0.intValue] } : nil
        return CGMReading(mgdl: mgdl, time: time, direction: trend)
    }
}

// MARK: - Dexcom Share (Dexcom G6 / G7 / ONE+ via the Dexcom app)
// Uses the Dexcom account itself (not a follower's). Share must be switched
// on in the Dexcom app, with at least one follower invited. US accounts use
// the US server, Japan its own, everyone else "outside US".
enum DexcomRegion: String, CaseIterable, Identifiable {
    case us = "US", ous = "Outside US", jp = "Japan"
    var id: String { rawValue }
    var base: String {
        switch self {
        case .us:  return "https://share2.dexcom.com/ShareWebServices/Services"
        case .ous: return "https://shareous1.dexcom.com/ShareWebServices/Services"
        case .jp:  return "https://share.dexcom.jp/ShareWebServices/Services"
        }
    }
    var applicationId: String {
        self == .jp ? "d8665ade-9673-4e27-9ff6-92db4ce13d13" : "d89443d2-327c-4a6f-89e5-496bbb0317db"
    }
}

@MainActor
final class DexcomShareClient: CloudSource {
    private static let noSession = "00000000-0000-0000-0000-000000000000"
    // Dexcom gives this same refusal for a wrong password, region or login
    // type. Tested 2026-11-05: an email that works on Dexcom's website was
    // refused here, the same account's phone number with + was accepted.
    private static let refusedHelp = "If you used an email address, try your phone number with + and country code. Also check the password and region."

    private let username: String
    private let password: String
    private let region: DexcomRegion
    private let session: URLSession
    private var sessionId: String?
    private var known: [CGMReading] = [] // the last 3 hours (at least the newest reading), newest first

    init(username: String, password: String, region: DexcomRegion, session: URLSession) {
        self.username = username; self.password = password; self.region = region; self.session = session
    }

    func fetchReadings() async throws -> [CGMReading] {
        if sessionId == nil { try await login() }
        do {
            return try await latest()
        } catch CloudSourceError.service(let m) where m == "session" {
            sessionId = nil // Dexcom sessions expire: log in once more
            try await login()
            return try await latest()
        }
    }

    private func post(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Any {
        var components = URLComponents(string: region.base + path)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CloudSourceError.service("Dexcom: bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if code == 200, let json { return json }
        // Errors come back as {"Code": "...", "Message": "..."}.
        let errorCode = (json as? [String: Any])?["Code"] as? String ?? ""
        switch errorCode {
        case "SessionIdNotFound", "SessionNotValid":
            throw CloudSourceError.service("session")
        case "AccountPasswordInvalid", "SSO_AuthenticatePasswordInvalid", "SSO_AuthenticateAccountNotFound":
            throw CloudSourceError.credentials("Dexcom refused this login (\(errorCode)). \(Self.refusedHelp)")
        case "SSO_AuthenticateMaxAttemptsExceeed", "SSO_AuthenticateMaxAttemptsExceeded":
            throw CloudSourceError.credentials("Dexcom: too many failed logins (\(errorCode)); wait before trying again")
        default:
            throw CloudSourceError.service("Dexcom: HTTP \(code) \(errorCode)")
        }
    }

    // Two steps: account id from the username, then a session for that id.
    private func login() async throws {
        let app = region.applicationId
        guard let accountId = try await post("/General/AuthenticatePublisherAccount",
                                              body: ["accountName": username, "password": password, "applicationId": app]) as? String,
              accountId != Self.noSession,
              let id = try await post("/General/LoginPublisherAccountById",
                                       body: ["accountId": accountId, "password": password, "applicationId": app]) as? String,
              id != Self.noSession else {
            throw CloudSourceError.credentials("Dexcom refused this login. \(Self.refusedHelp)")
        }
        sessionId = id
    }

    // Asks only for what is new: one reading normally, more after a gap, up
    // to the 3 hours the watch's graph holds. 24 hours back, so an ended
    // sensor's last reading still comes (for the "sensor ended?" hint).
    private func latest() async throws -> [CGMReading] {
        let count = known.first.map { max(1, min(36, Int(Date().timeIntervalSince($0.time) / 300) + 1)) } ?? 36
        let result = try await post("/Publisher/ReadPublisherLatestGlucoseValues",
                                    query: [URLQueryItem(name: "sessionId", value: sessionId),
                                            URLQueryItem(name: "minutes", value: "1440"),
                                            URLQueryItem(name: "maxCount", value: String(count))])
        guard let list = result as? [[String: Any]] else { throw CloudSourceError.service("Dexcom: no data") }
        let fresh = list.compactMap(Self.reading)
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        let merged = (fresh + known.filter { k in !fresh.contains { abs($0.time.timeIntervalSince(k.time)) < 30 } })
            .sorted { $0.time > $1.time }
        known = merged.enumerated().filter { $0.offset == 0 || $0.element.time >= cutoff }.map(\.element)
        return known
    }

    // Trend is a name ("Flat") on current servers, a number 0-9 on old ones.
    private static let trendNames = ["None", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat",
                                     "FortyFiveDown", "SingleDown", "DoubleDown", "NotComputable", "RateOutOfRange"]

    // "WT": "Date(1793545591000)", epoch milliseconds in UTC.
    static func reading(_ item: [String: Any]) -> CGMReading? {
        guard let mgdl = (item["Value"] as? NSNumber)?.intValue, mgdl > 0,
              let wt = item["WT"] as? String,
              let ms = Double(wt.filter(\.isNumber)) else { return nil }
        let trend = (item["Trend"] as? String) ?? (item["Trend"] as? NSNumber).flatMap {
            trendNames.indices.contains($0.intValue) ? trendNames[$0.intValue] : nil
        }
        return CGMReading(mgdl: mgdl, time: Date(timeIntervalSince1970: ms / 1000), direction: trend)
    }
}
