import Foundation
import CoreBluetooth
import Combine
import UIKit
import UserNotifications

// Random UUIDs, unique to this project -- must match the watch's ext1.js.
// The characteristic UUID changes with the protocol version (now v5), see PROTOCOL.md.
let kGlucoseServiceUUID = CBUUID(string: "F17F3300-386E-46B5-A72A-C2FC31F7A639")
let kGlucoseCharUUID    = CBUUID(string: "9EF12279-A492-49BF-B7F2-5371E9EAF2CB") // protocol v5

let mgdlPerMmol = 18.01559 // Nightscout's own factor, so values match its display

struct NightscoutEntry: Decodable {
    let sgv: Int?
    let direction: String?
    let date: TimeInterval

    // Nightscout `date` is epoch milliseconds; tolerate seconds too.
    var time: Date { Date(timeIntervalSince1970: date > 1e11 ? date / 1000 : date) }
}

private let trendMap: [String: UInt8] = [
    "DoubleUp": 1, "SingleUp": 2, "FortyFiveUp": 3, "Flat": 4,
    "FortyFiveDown": 5, "SingleDown": 6, "DoubleDown": 7,
    "NOT COMPUTABLE": 0, "RATE OUT OF RANGE": 0
]

// ---------------------------------------------------------------------------
// BLE messages (protocol v5): the live reading, the history readings for the
// watch's graph and the status line. Each is 8 bytes; the layout is in
// BridgeMessage (BridgeSecurity.swift) and PROTOCOL.md. PacketSealer seals it
// with the bridge key into the 16-byte packet the watch gets.
//
// The packet is built fresh for every notification and read, so the age byte
// is always current -- even if the app was suspended and woken by a read.
// Live notifications are only sent for new CGM readings or changed pump
// data; the watch counts age locally in between and re-syncs with a
// periodic read.
// ---------------------------------------------------------------------------
@MainActor
class GlucoseBridgeManager: NSObject, ObservableObject {

    @Published var glucoseMgdl: Int     = 0
    @Published var trend: UInt8         = 0
    @Published var rateMgdl: Double     = 0    // mg/dL per 5 min
    // Display unit, from the Nightscout site's settings; the watch follows it.
    @Published var unitsMgdl: Bool = UserDefaults.standard.bool(forKey: "unitsMgdl") {
        didSet { UserDefaults.standard.set(unitsMgdl, forKey: "unitsMgdl") }
    }
    // CGM-only logging (default on): Nightscout holds glucose but no logged
    // injections, so a logged-treatments IOB of 0 is unknown ("--"); most MDI
    // users never log there and 0 would hide an active correction. Off: 0 is
    // shown. An AID app's IOB is always used.
    @Published var cgmOnlyLogging: Bool = UserDefaults.standard.object(forKey: "cgmOnlyLogging") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cgmOnlyLogging, forKey: "cgmOnlyLogging") }
    }

    // Where readings come from. The watch gets the same packets either way;
    // LibreLinkUp and Dexcom Share have glucose and trend only.
    enum DataSource: String, CaseIterable, Identifiable {
        case nightscout = "Nightscout", libreLinkUp = "LibreLinkUp", dexcomShare = "Dexcom Share"
        var id: String { rawValue }
        // Dexcom Share is parked (owner, 23 Nov 2026): the code stays, the app does not offer it
        // until a tester asks for it. Add .dexcomShare back here to offer it again.
        static let offered: [DataSource] = [.nightscout, .libreLinkUp]
    }
    @Published var dataSource: DataSource = {
        let stored = DataSource(rawValue: UserDefaults.standard.string(forKey: "dataSource") ?? "") ?? .nightscout
        return DataSource.offered.contains(stored) ? stored : .nightscout
    }() {
        didSet { UserDefaults.standard.set(dataSource.rawValue, forKey: "dataSource"); cloudClient = nil }
    }
    @Published var lluEmail: String = UserDefaults.standard.string(forKey: "lluEmail") ?? "" {
        didSet { UserDefaults.standard.set(lluEmail, forKey: "lluEmail"); cloudClient = nil }
    }
    @Published var lluPassword: String = Keychain.string("lluPassword") {
        didSet { Keychain.setString(lluPassword, "lluPassword"); cloudClient = nil }
    }
    @Published var dexcomUsername: String = UserDefaults.standard.string(forKey: "dexcomUser") ?? "" {
        didSet { UserDefaults.standard.set(dexcomUsername, forKey: "dexcomUser"); cloudClient = nil }
    }
    @Published var dexcomPassword: String = Keychain.string("dexcomPassword") {
        didSet { Keychain.setString(dexcomPassword, "dexcomPassword"); cloudClient = nil }
    }
    @Published var dexcomRegion: DexcomRegion = DexcomRegion(rawValue: UserDefaults.standard.string(forKey: "dexcomRegion") ?? "") ?? .ous {
        didSet { UserDefaults.standard.set(dexcomRegion.rawValue, forKey: "dexcomRegion"); cloudClient = nil }
    }
    private var cloudClient: CloudSource?  // made at the first fetch, keeps the login
    private var cloudBlocked = false       // login refused: no retries until Start again
    private var recentReadings: [CGMReading] = [] // cloud readings of the last 20 min, for the rate
    private var lastCloudReadings: [CGMReading] = [] // the last fetch's readings: the graph backfill, without another request
    private var subscription = 0 // counts subscriptions, so a backfill for a watch that left is dropped
    @Published var staleWarning: String?   // cloud reading older than 3 h; kept apart from statusMessage, which BLE events overwrite
    @Published var minutesAgo: Int      = 0
    @Published var iobUnits: Double?             // as Nightscout shows it (AID app or logged boluses); nil if unknown
    @Published var cobGrams: Double?             // likewise (logged carbs)
    @Published var lastLoopDate: Date?
    @Published var statusMessage: String = "Not started"
    @Published var isAdvertising: Bool  = false
    @Published var bleConnected: Bool   = false {
        didSet {
            print("[DIAG] \(diagnosticsMessage)")
            if bleConnected { startPolling() } else { stopPolling() }
            updateKeepAwake()
        }
    }

    @Published var nightscoutURL: String {
        didSet { UserDefaults.standard.set(nightscoutURL, forKey: "nsURL") }
    }
    @Published var nightscoutToken: String {
        didSet { Keychain.setString(nightscoutToken, "nsToken") }
    }
    @Published private(set) var bridgeKey: Data? = Keychain.bridgeKey() // nil while the Keychain is locked

    var diagnosticsMessage: String { "Watch: \(bleConnected ? "connected" : "waiting")" }

    private var peripheralManager: CBPeripheralManager!
    private var glucoseCharacteristic: CBMutableCharacteristic?
    // When the watch last wrote its pause byte (PROTOCOL.md, pause message).
    // A workout is paused before it is ended, so a disconnect within 5 minutes
    // of it is most likely the end, not a lost link. A hint, not authenticated.
    private var watchPausedAt: Date?

    // Polling: a light 15 s tick fetches only once the next CGM reading is
    // due (one CGM interval after the last one, plus slack for upload), or
    // every 60 s when a reading is late or a fetch failed. The interval is
    // measured from the data: 1 min for Libre-style uploads, 5 min for Dexcom.
    private var pollTimer: Timer?
    private let tickInterval: TimeInterval  = 15
    private var cgmInterval: TimeInterval   = 300
    private let uploadSlack: TimeInterval   = 20
    private let retryInterval: TimeInterval = 60
    private let staleRateMinutes = 15       // send rate 0 once a reading is this old
    private var nextFetchAt: Date = .distantPast

    private var isFetching = false
    // One fetch gets this long in all, whatever the network does: iOS gives a
    // background task about 30 s and kills the app that overruns it.
    private let fetchDeadline: TimeInterval = 20
    private var fetchWork: Task<Void, Never>?
    private var fetchBackgroundTask = UIBackgroundTaskIdentifier.invalid
    // State restoration (iOS relaunched the app after ending it): the bridge
    // is running again without a tap. Only "running" is kept on disk, never
    // a reading.
    private static let restoreIdentifier = "GlucoseBridgePeripheral"
    private static let runningKey = "bridgeRunning"
    private var serviceRestored = false         // the service survived: don't add it again at the first poweredOn
    private var dropRestoredServices = false    // restored but not wanted: remove it once Bluetooth is on
    // Until the first fetch after a relaunch is done there is no reading: the
    // watch gets a failed read (it retries) instead of a "no reading" packet
    // that blanks its screen and buzzes.
    private var restoredAwaitingFetch = false
    private var pendingPush = false
    // Graph backfill, paced by the watch: the first history reading follows
    // the live one as a notification, each further one answers a read, and
    // the watch reads again 2 s after each history reading until it gets the
    // live one back. All 36 at once flooded the watch's Bluetooth (dropped the
    // phone and the HR belt, lost most of the history), and a timer here
    // stalls while iOS keeps the app in the background (2026-10-23).
    private var historyQueue: [(sgv: Int, block: Int)] = [] // block = unix time / 300, newest first
    private var historyKickoff = false // the first history packet is still to be notified
    // The watch's status line (PROTOCOL.md, Status): sent after the live
    // reading when it changes and on every new subscription.
    private var sentStatus: BridgeMessage.Status = .ok
    private var pendingStatus = false
    private var fetchFailure: BridgeMessage.Status = .ok // why the last fetch failed
    private var pushAfterFetch = false // a watch subscribed while a fetch was running
    private var lastEntryDate: Date?
    private var urlSession: URLSession!
    @Published private(set) var bridgeActive: Bool = false // Start pressed, until Stop (the UI follows this)
    // Kept across launches, so a restart within the same second can't reuse a
    // nonce (a repeat with the same key leaks how two messages differ).
    private var lastNonce = UInt32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "lastNonce")) {
        didSet { UserDefaults.standard.set(Int(lastNonce), forKey: "lastNonce") }
    }
    private var unitsFetched = false
    private var lastFetchFailed = false   // the last Nightscout request failed
    #if DEBUG
    @Published var activeFault: BridgeFault? // see Fault tests
    @Published var faultLog: [String] = []
    private var faultTimer: Timer?
    #endif
    private var nightscoutNotified = false // "Nightscout" notification shown for this gap

    private static let logTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    override init() {
        nightscoutURL   = UserDefaults.standard.string(forKey: "nsURL")   ?? ""
        // One-time move of a token saved by older builds out of UserDefaults.
        if let legacy = UserDefaults.standard.string(forKey: "nsToken") {
            Keychain.setString(legacy, "nsToken")
            UserDefaults.standard.removeObject(forKey: "nsToken")
        }
        nightscoutToken = Keychain.string("nsToken")
        super.init()

        peripheralManager = CBPeripheralManager(delegate: self, queue: nil,
                                                options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)

        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(appStateChanged), name: name, object: nil)
        }
    }

    // MARK: - Public control
    func startBridge() {
        guard !bridgeActive else { return } // a second tap during the first fetch would re-add the service and drop the watch
        if bridgeKey == nil { bridgeKey = Keychain.bridgeKey() }
        guard bridgeKey != nil else {
            statusMessage = "Watch key unavailable. Unlock the iPhone and try again."; return
        }
        switch dataSource {
        case .nightscout:
            guard !nightscoutURL.isEmpty else {
                statusMessage = "Please enter your Nightscout URL first."; return
            }
            guard URL(string: nightscoutURL.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() == "https" else {
                statusMessage = "Nightscout URL must start with https://"; return
            }
            guard !nightscoutToken.trimmingCharacters(in: .whitespaces).isEmpty else {
                statusMessage = "Please enter your Nightscout access token."; return
            }
        case .libreLinkUp:
            guard !lluEmail.isEmpty, !lluPassword.isEmpty else {
                statusMessage = "Please enter your LibreLinkUp email and password."; return
            }
        case .dexcomShare:
            guard !dexcomUsername.isEmpty, !dexcomPassword.isEmpty else {
                statusMessage = "Please enter your Dexcom username and password."; return
            }
        }
        cloudClient = nil; cloudBlocked = false; recentReadings = []; lastCloudReadings = []; staleWarning = nil // fresh login after a settings fix
        sentStatus = .ok; fetchFailure = .ok
        if dataSource != .nightscout { iobUnits = nil; cobGrams = nil; lastLoopDate = nil }
        bridgeActive = true
        UserDefaults.standard.set(true, forKey: Self.runningKey)
        unitsFetched = false // pick up a units change on the site
        updateKeepAwake()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusMessage = "Fetching glucose…"
        Task { await fetchGlucose(); setupBLEService() }
    }

    func stopBridge() {
        bridgeActive = false; stopPolling()
        UserDefaults.standard.set(false, forKey: Self.runningKey)
        restoredAwaitingFetch = false
        // Tell a connected watch why the data stops ("Bridge off"; a
        // diagnostic, PROTOCOL.md Status) before the service goes.
        let toldWatch = bleConnected && glucoseCharacteristic.map {
            peripheralManager.updateValue(statusPayload(.bridgeOff), for: $0, onSubscribedCentrals: nil)
        } == true
        peripheralManager.stopAdvertising()
        // Drop the watch instead of serving a frozen reading; a second later
        // if it is being told, so the notification goes out first.
        DispatchQueue.main.asyncAfter(deadline: .now() + (toldWatch ? 1 : 0)) { [weak self] in
            guard let self, !self.bridgeActive else { return }
            self.peripheralManager.removeAllServices()
        }
        glucoseCharacteristic = nil
        isAdvertising = false; bleConnected = false
        cancelWatchLost()
        watchPausedAt = nil
        nightscoutNotified = false
        updateKeepAwake()
        statusMessage = "Stopped"
    }

    // A new key takes effect immediately; the watch needs the same key in the
    // Suunto app settings before it accepts packets again.
    func regenerateBridgeKey() {
        bridgeKey = Keychain.newBridgeKey()
        lastNonce = 0
    }

    // iOS hides a backgrounded peripheral's service UUID from non-Apple
    // scanners, so keep the screen on until the watch has connected.
    private func updateKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = bridgeActive && !bleConnected
    }

    // Scheduled 60 s ahead and withdrawn if the watch reconnects, so a short
    // drop-out stays quiet; a scheduled notification still fires if iOS has
    // suspended the app by then. The bridge cannot tell a finished workout
    // from a lost link, hence the wording. iOS does not show it while the app
    // is in the foreground. Generic text only -- no glucose values on the
    // lock screen.
    private func scheduleWatchLost() {
        guard bridgeActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Watch disconnected"
        content.body = "If your workout is still running, open the bridge app so the watch can reconnect."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watchLost", content: content, trigger: trigger))
    }
    private func cancelWatchLost() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["watchLost"])
    }

    // Nightscout guard. The watch only sees the reading age grow (grey at
    // 6 min, signal-lost buzz at 10), not why. Once the newest reading is
    // 10 min old, one notification says whether Nightscout can't be reached
    // or has nothing new (CGM or AID app no longer uploading, as when Trio's
    // Nightscout access was removed on 2026-10-30). A fresh reading resets
    // it. Checked after every fetch: every 60 s while readings are late.
    private func checkNightscout() {
        guard bridgeActive else { return }
        updateWatchStatus()
        let age = lastEntryDate.map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 600 { nightscoutNotified = false; return }
        guard !nightscoutNotified else { return }
        nightscoutNotified = true
        let content = UNMutableNotificationContent()
        let source = dataSource.rawValue
        if lastFetchFailed && cloudBlocked {
            content.title = "\(source) refused the login"
            content.body = "The watch keeps the last reading as it ages. Check the login in the bridge app, then press Stop and Start."
        } else if lastFetchFailed {
            content.title = "Can't reach \(source)"
            content.body = dataSource == .nightscout
                ? "The watch keeps the last reading as it ages. Check the phone's internet connection and your Nightscout site."
                : "The watch keeps the last reading as it ages. Check the phone's internet connection and the login in the bridge app."
        } else {
            content.title = "No new readings in \(source)"
            content.body = dataSource == .nightscout
                ? "Nothing new for 10 minutes. Check that your CGM or AID app (for example Trio) is still uploading to Nightscout."
                : "Nothing new for 10 minutes. Check that your CGM app is running and sharing."
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nightscout", content: content, trigger: nil))
        log("REST", content.title)
    }

    // The watch's status line, by the same 10-minute rule as the notification
    // above: nothing while the reading is fresh, so one failed fetch doesn't
    // flash a message.
    private func currentStatus() -> BridgeMessage.Status {
        let age = lastEntryDate.map { Date().timeIntervalSince($0) } ?? .infinity
        if lastFetchFailed && fetchFailure == .loginFailed { return .loginFailed } // at once: only the user can fix it
        if age < 600 { return .ok }
        if lastFetchFailed { return fetchFailure == .ok ? .sourceDown : fetchFailure }
        return age > 3 * 3600 ? .noSensor : .noNewData
    }
    private func updateWatchStatus() {
        let status = currentStatus()
        guard status != sentStatus else { return }
        sentStatus = status; pendingStatus = true
        log("BLE", "Watch status: \(status)")
        drainBLE()
    }
    /// No internet, or the service itself failing.
    private static func failure(_ error: Error) -> BridgeMessage.Status {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                                        .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed]
        return (error as? URLError).map { offline.contains($0.code) } == true ? .noInternet : .sourceDown
    }

    /// The Refresh button: LibreLinkUp keeps its 1-minute minimum.
    func refreshNow() {
        if dataSource == .libreLinkUp && Date() < nextFetchAt {
            statusMessage = "LibreLinkUp: next check in \(Int(nextFetchAt.timeIntervalSinceNow / 60) + 1) min"
            return
        }
        Task { await fetchGlucose() }
    }

    /// "7.2 mmol/L" or "130 mg/dL", in the display unit.
    func glucoseText(_ mgdl: Int) -> String {
        unitsMgdl ? "\(mgdl) mg/dL" : String(format: "%.1f mmol/L", Double(mgdl) / mgdlPerMmol)
    }

    static func arrow(for trend: UInt8) -> String {
        switch trend {
        case 1: return "↑↑"; case 2: return "↑"; case 3: return "↗"; case 4: return "→"
        case 5: return "↘"; case 6: return "↓"; case 7: return "↓↓"; default: return "?"
        }
    }

    // MARK: - BLE service setup
    private func setupBLEService() {
        guard peripheralManager.state == .poweredOn else { return }
        let characteristic = CBMutableCharacteristic(type: kGlucoseCharUUID,
                                                     properties: [.notify, .read, .write], value: nil, permissions: [.readable, .writeable])
        glucoseCharacteristic = characteristic
        let service = CBMutableService(type: kGlucoseServiceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheralManager.removeAllServices()
        peripheralManager.add(service)
    }

    // MARK: - Polling lifecycle
    private func startPolling() {
        guard bridgeActive else { return }
        pollTimer?.invalidate()
        // Scheduled on the main run loop, so the callback is already on the main actor.
        pollTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
    }
    private func tick() {
        if let entryDate = lastEntryDate { minutesAgo = Self.minutes(since: entryDate) }
        if Date() >= nextFetchAt { Task { await fetchGlucose() } }
    }

    // MARK: - BLE packet
    private static func minutes(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    private func currentReading() -> [UInt8] {
        let loop = lastLoopDate.map { Self.minutes(since: $0) }
        guard glucoseMgdl > 0, let entryDate = lastEntryDate else {
            return BridgeMessage.live(glucose: 0, trend: 0, unitMgdl: unitsMgdl, aidAlert: false, rate: 0, age: 255,
                                      iob: iobUnits, cob: cobGrams, loop: loop)
        }
        let age = Self.minutes(since: entryDate)
        return BridgeMessage.live(glucose: glucoseMgdl, trend: Int(trend), unitMgdl: unitsMgdl, aidAlert: false,
                                  rate: age > staleRateMinutes ? 0 : Int(rateMgdl.rounded()), age: age,
                                  iob: iobUnits, cob: cobGrams, loop: loop)
    }

    // Nonce = unix seconds, bumped so it strictly increases even for two
    // packets in the same second (the watch rejects repeats as replays, and
    // accepts nonces up to 10 min ahead of its clock, so a backfill burst of
    // 36 packets is fine).
    // The message is built for the nonce it goes out with (a history packet
    // counts its blocks back from it).
    private func seal(_ message: (UInt32) -> [UInt8]) -> Data {
        let now = UInt32(Date().timeIntervalSince1970)
        lastNonce = lastNonce > now &+ 60 ? now : max(now, lastNonce &+ 1) // a saved nonce far ahead (clock set back) would be rejected by the watch
        guard let bridgeKey else { return Data() } // not reached: Start needs the key; the watch drops an empty packet
        return PacketSealer.seal(message(lastNonce), nonce: lastNonce, key: bridgeKey)
    }

    private func currentPayload() -> Data { seal { _ in currentReading() } }
    private func statusPayload(_ status: BridgeMessage.Status) -> Data {
        let source: BridgeMessage.Source = dataSource == .nightscout ? .nightscout
            : dataSource == .libreLinkUp ? .libreLinkUp : .dexcomShare
        return seal { _ in BridgeMessage.status(status, source: source) }
    }
    /// The next history packet (up to five 5-minute blocks), nil when done.
    private func historyPayload() -> Data? {
        guard !historyQueue.isEmpty else { return nil }
        return seal { BridgeMessage.history(from: &historyQueue, nonce: $0)! }
    }

    private func pushToBLE() {
        pendingPush = true
        drainBLE()
    }

    // Sends the live reading, then the status if due, then the first history
    // packet. Each
    // is sealed as it goes out, so its nonce is above any packet sent
    // meanwhile (a read reply, say). updateValue returns false when the
    // transmit queue is full; sending goes on from
    // peripheralManagerIsReady(toUpdateSubscribers:).
    private func drainBLE() {
        guard let char = glucoseCharacteristic else { return }
        #if DEBUG
        if activeFault != nil { return } // a fault sends nothing; endFault pushes
        #endif
        // After a relaunch nothing goes out before the first reading: a "no
        // reading" packet, or a status without data, would blank the watch.
        // What is held is sent when that fetch is done.
        if restoredAwaitingFetch && lastEntryDate == nil { return }
        if pendingPush {
            pendingPush = !peripheralManager.updateValue(currentPayload(), for: char, onSubscribedCentrals: nil)
            if pendingPush { return }
        }
        if pendingStatus {
            pendingStatus = !peripheralManager.updateValue(statusPayload(sentStatus), for: char, onSubscribedCentrals: nil)
            if pendingStatus { return }
        }
        if historyKickoff {
            let queueBefore = historyQueue
            if let packet = historyPayload(), peripheralManager.updateValue(packet, for: char, onSubscribedCentrals: nil) {
                historyKickoff = false
            } else {
                historyQueue = queueBefore // queue full: the same blocks go with the next try
            }
        }
    }

    private func statusLine() -> String {
        let rate = unitsMgdl ? String(format: "%+.0f", rateMgdl) : String(format: "%+.1f", rateMgdl / mgdlPerMmol)
        return "\(glucoseText(glucoseMgdl)) \(Self.arrow(for: trend)) \(rate) \(minutesAgo)m ago"
            + (iobUnits.map { String(format: " · IOB %.2f U", $0) } ?? "")
            + (cobGrams.map { String(format: " · COB %.0f g", $0) } ?? "")
    }

    // MARK: - Display unit (Nightscout DISPLAY_UNITS, "mg/dl" or "mmol")
    /// Keeps the last known unit when the request fails; retried next fetch.
    private func fetchUnits(base: String, token: String) async {
        var components = URLComponents(string: base + "/api/v1/status.json")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url,
              let result = try? await urlSession.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let units = (status["settings"] as? [String: Any])?["units"] as? String else { return }
        unitsMgdl = !units.lowercased().hasPrefix("mmol")
        unitsFetched = true
    }

    // MARK: - Delta, IOB and COB as Nightscout computes and shows them
    /// One request to /api/v2/properties for what Nightscout's own page shows.
    /// rate: its delta (mean of the newest 5-min bucket minus the one
    /// before) in mg/dL per 5 min; for mmol/L its "scaled" value, which
    /// Nightscout takes from the rounded mmol/L means (mgdl -1 shows as "+0"),
    /// so the watch shows exactly Nightscout's number (whole mg/dL carry every
    /// 0.1 mmol/L step through the watch's conversion unchanged). Only if it
    /// belongs to the reading just fetched. iob / cob: from the AID app's
    /// uploads when there are any, else from treatments logged in Nightscout
    /// (MDI via Care Portal); logged-treatment values count only with the
    /// "CGM only logging" setting off (cgmOnlyLogging). All nil if the
    /// server doesn't offer it (before Nightscout 0.9) or the request fails.
    private func fetchNightscoutProperties(base: String, token: String, for time: Date) async -> (rate: Double?, iob: Double?, cob: Double?) {
        var components = URLComponents(string: base + "/api/v2/properties/delta,iob,cob")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url,
              let result = try? await urlSession.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
        else { log("REST", "No Nightscout properties, own 5-min rate used"); return (nil, nil, nil) }

        var rate: Double?
        if let delta = json["delta"] as? [String: Any],
           let recent = ((delta["times"] as? [String: Any])?["recent"] as? NSNumber)?.doubleValue,
           abs(recent / 1000 - time.timeIntervalSince1970) < 60 {
            let scaled = unitsMgdl ? nil : (delta["scaled"] as? NSNumber)?.doubleValue
            rate = scaled.map { $0 * mgdlPerMmol } ?? (delta["mgdl"] as? NSNumber)?.doubleValue
        }
        // With CGM-only logging, IOB and COB from logged treatments ("Care
        // Portal") are ignored: nothing is logged, and Nightscout's 0 would
        // hide an active correction. With all unknown the watch hides the
        // pump line. An AID app's values always count; no source (older
        // Nightscout) counts as logged treatments.
        func use(_ d: [String: Any]) -> Bool {
            !cgmOnlyLogging || (d["source"] as? String).map { $0 != "Care Portal" } == true
        }
        let iob = (json["iob"] as? [String: Any]).flatMap { use($0) ? ($0["iob"] as? NSNumber)?.doubleValue : nil }
        let cob = (json["cob"] as? [String: Any]).flatMap { use($0) ? ($0["cob"] as? NSNumber)?.doubleValue : nil }
        return (rate, iob, cob)
    }

    // MARK: - Pump / loop status (Trio uploads it as Nightscout devicestatus)
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// IOB, COB and last loop time from the newest OpenAPS-style
    /// devicestatus. All nil when there is none (MDI, or the AID app isn't
    /// uploading). IOB or COB older than 30 min counts as unknown. The loop
    /// time is the last change the pump confirmed (see fetchLastEnacted).
    private func fetchPumpStatus(base: String, token: String) async -> (iob: Double?, cob: Double?, loop: Date?) {
        var components = URLComponents(string: base + "/api/v1/devicestatus.json")
        components?.queryItems = [URLQueryItem(name: "find[openaps][$exists]", value: "true"),
                                  URLQueryItem(name: "count", value: "1"),
                                  URLQueryItem(name: "token", value: token)]
        guard let url = components?.url,
              let result = try? await urlSession.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: result.0) as? [[String: Any]],
              let openaps = list.first?["openaps"] as? [String: Any] else { return (nil, nil, nil) }

        // COB from the newer of the loop's suggestion and enactment.
        let latest = [openaps["suggested"], openaps["enacted"]]
            .compactMap { $0 as? [String: Any] }
            .compactMap { d in Self.isoDate(d["timestamp"]).map { (d, $0) } }
            .max { $0.1 < $1.1 }
        let loop = await fetchLastEnacted(base: base, token: token)
        var cob: Double?
        if let latest, Date().timeIntervalSince(latest.1) < 30 * 60 {
            cob = (latest.0["COB"] as? NSNumber)?.doubleValue
        }
        // Trio sends one IOB object; oref0 rigs send an array of them.
        let entry = (openaps["iob"] as? [String: Any]) ?? (openaps["iob"] as? [[String: Any]])?.first
        var iob: Double?
        if let entry, let value = (entry["iob"] as? NSNumber)?.doubleValue,
           let time = Self.isoDate(entry["time"]) ?? latest?.1,
           Date().timeIntervalSince(time) < 30 * 60 {
            iob = value
        } else if let latest, Date().timeIntervalSince(latest.1) < 30 * 60 {
            // Open loop: Trio uploads no IOB object, only the IOB inside its
            // suggestion (2026-11-01: Nightscout fell back to Care Portal 0
            // and the watch showed "IOB --" with Trio running).
            iob = (latest.0["IOB"] as? NSNumber)?.doubleValue
        }
        return (iob, cob, loop)
    }

    /// When the pump last confirmed a change from the loop: the newest
    /// devicestatus with an enactment that wasn't refused (oref0 marks that
    /// "recieved", Trio "received"; false = the pump didn't take it). A
    /// suggestion alone doesn't count: Trio keeps suggesting every 5 min while
    /// the pump is out of reach, so "loop 3m" would hide that nothing reached
    /// it. Asked separately because the newest devicestatus often has no
    /// enactment. Nil in open loop (nothing is enacted), without an AID app,
    /// or when the last enactment is over 6 h old: the AID app is no longer
    /// uploading (Trio's Nightscout access removed, 2026-10-30, left the
    /// watch on a red "Loop 126m" for days).
    private func fetchLastEnacted(base: String, token: String) async -> Date? {
        var components = URLComponents(string: base + "/api/v1/devicestatus.json")
        components?.queryItems = [URLQueryItem(name: "find[openaps.enacted][$exists]", value: "true"),
                                  URLQueryItem(name: "count", value: "3"),
                                  URLQueryItem(name: "token", value: token)]
        guard let url = components?.url,
              let result = try? await urlSession.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: result.0) as? [[String: Any]] else { return nil }
        return list
            .compactMap { ($0["openaps"] as? [String: Any])?["enacted"] as? [String: Any] }
            .filter { ($0["received"] ?? $0["recieved"]) as? Bool != false }
            .compactMap { Self.isoDate($0["timestamp"]) }
            .max()
            .flatMap { Date().timeIntervalSince($0) < 6 * 3600 ? $0 : nil }
    }

    // Glucose values only go to the console in debug builds.
    private func log(_ tag: String, _ message: String) {
        #if DEBUG
        print("[\(tag)] \(Self.logTime.string(from: Date())) \(message)")
        #endif
    }

    // MARK: - App lifecycle
    @objc private func appStateChanged() {
        if bridgeKey == nil { bridgeKey = Keychain.bridgeKey() } // readable again after an unlock
        guard bridgeActive, Date() >= nextFetchAt else { return }; Task { await fetchGlucose() }
    }

    // MARK: - REST fetch (3 entries for averaged delta)
    private func nightscoutBase() -> (base: String, token: String) {
        var base = nightscoutURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        return (base, nightscoutToken.trimmingCharacters(in: .whitespaces))
    }

    // Percent-encode the token as a query item rather than pasting it in.
    private func entriesURL(count: Int) -> URL? {
        let (base, token) = nightscoutBase()
        var components = URLComponents(string: base + "/api/v1/entries/sgv.json")
        components?.queryItems = [URLQueryItem(name: "count", value: String(count)),
                                  URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    // The last 3 hours as history readings for the watch's graph: the newest
    // reading of each 5-minute block (block = unix time / 300), newest first,
    // so the recent part of the graph fills first.
    // The live reading is left out; it follows as a normal packet. 240
    // entries cover 3 hours of 1-minute data with room for gaps. On any
    // error the watch simply gets no backfill.
    private func fetchHistory() async -> [(sgv: Int, time: Date)] {
        if dataSource != .nightscout { return await cloudHistory() }
        guard let url = entriesURL(count: 240) else { return [] }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let entries = try JSONDecoder().decode([NightscoutEntry].self, from: data)
            let since = Date().addingTimeInterval(-3 * 3600)
            var newest: [Int: NightscoutEntry] = [:]
            for e in entries where e.time >= since && e.time != lastEntryDate && (e.sgv ?? 0) > 0 {
                let block = Int(e.time.timeIntervalSince1970 / 300)
                if newest[block].map({ e.time > $0.time }) ?? true { newest[block] = e }
            }
            let readings = newest.keys.sorted(by: >).compactMap { newest[$0] }.map { (sgv: $0.sgv!, time: $0.time) }
            log("BLE", "Backfill: \(readings.count) history readings")
            return readings
        } catch {
            log("BLE", "Backfill failed: \(error.localizedDescription)")
            return []
        }
    }

    func fetchGlucose() async {
        guard !isFetching else { return }
        isFetching = true
        // The fetch runs as its own task so that the deadline and iOS's
        // expiration handler can cancel it (URLSession then throws at once).
        let work = Task { await self.runFetch() }
        fetchWork = work
        // Ask iOS for time to finish if a watch read woke the app to fetch.
        fetchBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NightscoutFetch") { [weak self] in
            // On the main thread. Out of time: stop the work and give the task back at once.
            MainActor.assumeIsolated { self?.fetchWork?.cancel(); self?.endFetchBackgroundTask() }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(self.fetchDeadline))
            if !Task.isCancelled { work.cancel() } // cancelled itself when the fetch finished first
        }
        await work.value
        deadline.cancel()
        fetchWork = nil
        isFetching = false
        if restoredAwaitingFetch { restoredAwaitingFetch = false; drainBLE() } // normal again, whatever the fetch brought
        // A watch that subscribed mid-fetch still gets a packet if this
        // fetch failed or brought nothing new.
        if pushAfterFetch { pushAfterFetch = false; pushToBLE() }
        checkNightscout()
        endFetchBackgroundTask()
    }

    // Ends the fetch's background task, once: from the end of the fetch or
    // the expiration handler, whichever comes first.
    private func endFetchBackgroundTask() {
        guard fetchBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fetchBackgroundTask)
        fetchBackgroundTask = .invalid
    }

    // The fetch itself, run by fetchGlucose. Task.isCancelled here means the
    // deadline or iOS's expiration handler hit.
    private func runFetch() async {
        nextFetchAt = Date().addingTimeInterval(retryInterval) // fallback if this fetch fails
        lastFetchFailed = true // until the entries arrive
        fetchFailure = cloudBlocked ? .loginFailed : .ok
        if dataSource != .nightscout { await fetchFromCloud(); return }

        let (base, token) = nightscoutBase()
        guard let url = entriesURL(count: 12) else { statusMessage = "Invalid URL"; return }

        do {
            let (data, response) = try await urlSession.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                fetchFailure = (code == 401 || code == 403) ? .loginFailed : .sourceDown
                statusMessage = (code == 401 || code == 403)
                    ? "Token rejected — check it has the readable role"
                    : "HTTP error \(code)"
                log("REST", statusMessage); return
            }

            let entries = try JSONDecoder().decode([NightscoutEntry].self, from: data)
            lastFetchFailed = false
            guard let current = entries.first, let sgv = current.sgv else {
                statusMessage = "No data from Nightscout"; return
            }

            // Reading interval, from the two newest entries (60-300 s).
            if entries.count >= 2 {
                cgmInterval = min(max(current.time.timeIntervalSince(entries[1].time), 60), 300)
            }

            // Rate = Nightscout's own delta (fetchNightscoutProperties), so the
            // watch shows what Nightscout shows. Fallback: the change over the
            // last ~5 min (the first entry at least 4.5 min back, or the oldest
            // fetched), scaled to "per 5 min". A 10-min window lagged the
            // CGM's arrow at turns (arrow up, rate still negative; 2026-10-24).
            var rate = 0.0
            let old = entries.first { current.time.timeIntervalSince($0.time) >= 270 } ?? entries.last
            if let old, let oldSgv = old.sgv {
                let minutesElapsed = current.time.timeIntervalSince(old.time) / 60
                if minutesElapsed > 0.5 {
                    rate = Double(sgv - oldSgv) / minutesElapsed * 5
                }
            }

            if !unitsFetched { await fetchUnits(base: base, token: token) } // before the delta: it depends on the unit
            let props = await fetchNightscoutProperties(base: base, token: token, for: current.time)
            if let delta = props.rate { rate = delta }

            let isNew     = current.time != lastEntryDate
            lastEntryDate = current.time
            // Sent as mg/dL unchanged; the watch converts and rounds once.
            glucoseMgdl   = sgv
            trend         = trendMap[current.direction ?? ""] ?? 0
            rateMgdl      = rate
            minutesAgo    = Self.minutes(since: current.time)

            let nextReading = current.time.addingTimeInterval(cgmInterval + uploadSlack)
            if nextReading > Date() { nextFetchAt = nextReading }

            // IOB and COB as Nightscout shows them (AID app or logged
            // treatments); the AID app's own upload if Nightscout gives none.
            // The loop time comes from the AID app only.
            let pump = await fetchPumpStatus(base: base, token: token)
            // Out of time during these requests: they came back nil, which
            // would read as "unknown". The glucose is good, so keep the old
            // IOB, COB and loop time for this round.
            let timedOut = Task.isCancelled
            let iob  = timedOut ? iobUnits : (props.iob ?? pump.iob)
            let cob  = timedOut ? cobGrams : (props.cob ?? pump.cob)
            let loop = timedOut ? lastLoopDate : pump.loop
            let pumpChanged = iob != iobUnits || cob != cobGrams || loop != lastLoopDate
            iobUnits     = iob
            cobGrams     = cob
            lastLoopDate = loop

            if isNew || pumpChanged || pushAfterFetch { pushAfterFetch = false; pushToBLE() }
            statusMessage = statusLine()
            log("REST", statusMessage)
        } catch {
            fetchFailure = Self.failure(error) // a cancelled request is not an offline code: source down
            statusMessage = Task.isCancelled ? "Nightscout: no answer in \(Int(fetchDeadline)) s" : "Nightscout: \(error.localizedDescription)"
            log("REST", statusMessage)
        }
    }

    // MARK: - LibreLinkUp / Dexcom Share (CloudSources.swift)
    private func cloud() -> CloudSource {
        if let cloudClient { return cloudClient }
        let client: CloudSource = dataSource == .libreLinkUp
            ? LibreLinkUpClient(email: lluEmail.trimmingCharacters(in: .whitespaces), password: lluPassword, session: urlSession)
            : DexcomShareClient(username: dexcomUsername.trimmingCharacters(in: .whitespaces), password: dexcomPassword,
                                region: dexcomRegion, session: urlSession)
        cloudClient = client
        return client
    }

    /// Glucose and trend from the follower service; rate from the change
    /// over the last ~5 min, as Nightscout's fallback does. A refused login
    /// stops fetching until Start (repeated failed logins can lock a Dexcom
    /// account).
    private func fetchFromCloud() async {
        let source = dataSource.rawValue
        guard !cloudBlocked else { return } // no request until Start again; the status and alert still follow (every 60 s)
        // LibreLinkUp at most once a minute, also while readings are late (as
        // xDrip4iOS polls it); the readings themselves come every minute.
        if dataSource == .libreLinkUp { nextFetchAt = Date().addingTimeInterval(60) }
        do {
            let readings = try await cloud().fetchReadings()
            lastFetchFailed = false
            lastCloudReadings = readings
            guard let current = readings.first else { statusMessage = "No data from \(source)"; return }

            // Keep 20 minutes of readings across fetches: LibreLinkUp's
            // history is sparser than its 1-minute current reading.
            let cutoff = Date().addingTimeInterval(-20 * 60)
            var recent = recentReadings.filter { $0.time >= cutoff }
            for r in readings where r.time >= cutoff && !recent.contains(where: { abs($0.time.timeIntervalSince(r.time)) < 30 }) {
                recent.append(r)
            }
            recent.sort { $0.time > $1.time }
            recentReadings = recent
            if recent.count >= 2 {
                cgmInterval = min(max(recent[0].time.timeIntervalSince(recent[1].time), 60), 300)
            }
            var rate = 0.0
            if let old = recent.first(where: { current.time.timeIntervalSince($0.time) >= 270 }) ?? recent.last {
                let minutesElapsed = current.time.timeIntervalSince(old.time) / 60
                if minutesElapsed > 0.5 { rate = Double(current.mgdl - old.mgdl) / minutesElapsed * 5 }
            }

            let isNew     = current.time != lastEntryDate
            lastEntryDate = current.time
            glucoseMgdl   = current.mgdl
            trend         = trendMap[current.direction ?? ""] ?? 0
            rateMgdl      = rate
            minutesAgo    = Self.minutes(since: current.time)
            iobUnits = nil; cobGrams = nil; lastLoopDate = nil // not offered by these services

            let nextReading = current.time.addingTimeInterval(cgmInterval + uploadSlack)
            if nextReading > Date() { nextFetchAt = dataSource == .libreLinkUp ? max(nextReading, nextFetchAt) : nextReading }

            if isNew || pushAfterFetch { pushAfterFetch = false; pushToBLE() }
            statusMessage = statusLine()
            log("REST", "\(source): \(statusMessage)")
            // Older than 3 h (Dexcom's sensor-failure cut-off): the login works
            // but the sensor isn't uploading, e.g. an ended sensor or one read
            // by another app.
            let age = Date().timeIntervalSince(current.time)
            if age > 3 * 3600 {
                let ageText = age >= 48 * 3600 ? "\(Int(age / 86400)) days" : "\(Int(age / 3600)) hours"
                let app = dataSource == .libreLinkUp ? "the Libre app" : "the Dexcom app with Share on"
                staleWarning = "\(source)'s latest reading is \(ageText) old. Is your sensor connected to \(app)?"
                log("REST", staleWarning!)
            } else {
                staleWarning = nil
            }
        } catch CloudSourceError.credentials(let message) {
            fetchFailure = .loginFailed
            cloudBlocked = true; cloudClient = nil
            statusMessage = message + " — fix it, then Stop and Start the bridge."
            log("REST", statusMessage)
        } catch {
            fetchFailure = Self.failure(error)
            let message = error.localizedDescription
            statusMessage = Task.isCancelled ? "\(source): no answer in \(Int(fetchDeadline)) s"
                : (message == "401" || message == "session") ? "\(source): login expired, retrying" : "\(source): \(message)"
            log("REST", statusMessage)
        }
    }

    // The watch's 3-hour graph from the follower service: the newest
    // reading of each 5-minute block, newest first, live reading left out.
    private func cloudHistory() async -> [(sgv: Int, time: Date)] {
        let readings = lastCloudReadings // from the last fetch: no extra request (rate limits, Dexcom lockout)
        let since = Date().addingTimeInterval(-3 * 3600)
        var newest: [Int: CGMReading] = [:]
        for r in readings where r.time >= since && r.time != lastEntryDate && r.time != readings.first?.time {
            let block = Int(r.time.timeIntervalSince1970 / 300)
            if newest[block].map({ r.time > $0.time }) ?? true { newest[block] = r }
        }
        let history = newest.keys.sorted(by: >).compactMap { newest[$0] }.map { (sgv: $0.mgdl, time: $0.time) }
        log("BLE", "Backfill: \(history.count) history readings")
        return history
    }

    private func logBLEEvent(_ message: String) {
        statusMessage = message; print("[EVENT] \(message)")
        #if DEBUG
        faultNote(message)
        #endif
    }
}

// MARK: - CBPeripheralManagerDelegate
extension GlucoseBridgeManager: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                statusMessage = "Bluetooth ready"
                if dropRestoredServices {
                    dropRestoredServices = false
                    peripheral.removeAllServices(); peripheral.stopAdvertising()
                }
                if !bridgeActive {
                    // Not running (or not restored): no stale "running" may survive this launch.
                    UserDefaults.standard.set(false, forKey: Self.runningKey)
                } else if serviceRestored {
                    // Restored with its service and the watch's subscription: adding it again would drop both.
                    serviceRestored = false
                    drainBLE()
                } else {
                    setupBLEService()
                }
            case .poweredOff: statusMessage = "Bluetooth is off"; isAdvertising = false; serviceRestored = false // the service is gone
            case .unauthorized: statusMessage = "Bluetooth permission denied"
            case .resetting: statusMessage = "Bluetooth resetting…"; isAdvertising = false; serviceRestored = false
            default: statusMessage = "Bluetooth unavailable"
            }
        }
    }
    // iOS relaunched the app in the background after ending it. Runs on the
    // main queue like didReceiveRead, so it is done before the handlers that
    // follow (they hop to the main actor later). Nothing is sent to
    // CoreBluetooth here: the manager is not powered on yet.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService])?
            .first { $0.uuid == kGlucoseServiceUUID }?
            .characteristics?.first { $0.uuid == kGlucoseCharUUID } as? CBMutableCharacteristic
        if bridgeKey == nil { bridgeKey = Keychain.bridgeKey() }
        guard UserDefaults.standard.bool(forKey: Self.runningKey), bridgeKey != nil, !bridgeActive, let restored else {
            // The user had stopped it, or the key can't be read (phone not
            // unlocked since boot): don't serve. Remove what iOS kept, at poweredOn.
            UserDefaults.standard.set(false, forKey: Self.runningKey)
            dropRestoredServices = true
            return
        }
        glucoseCharacteristic = restored
        serviceRestored = true
        bridgeActive = true
        restoredAwaitingFetch = true
        isAdvertising = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] != nil || peripheral.isAdvertising
        bleConnected = !(restored.subscribedCentrals ?? []).isEmpty // polling, keep-awake
        statusMessage = "Fetching glucose…"
        logBLEEvent("Restored after iOS ended the app")
        Task { await fetchGlucose() }
    }
    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error { logBLEEvent("Advertising error: \(error.localizedDescription)"); isAdvertising = false }
            else { logBLEEvent("Advertising — waiting for watch…"); isAdvertising = true }
        }
    }
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            if let err = error { logBLEEvent("Error adding service: \(err)") }
            else {
                logBLEEvent("Service added — starting advertisement")
                // No local name: a name like "NSBridge" would tell anyone
                // scanning nearby that this phone carries glucose data.
                // Already advertising after a service change (fault tests).
                if !peripheral.isAdvertising {
                    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [kGlucoseServiceUUID]])
                }
            }
        }
    }
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            bleConnected = true; logBLEEvent("Watch connected ✓")
            cancelWatchLost()
            watchPausedAt = nil
            subscription += 1
            let thisSubscription = subscription
            sentStatus = currentStatus(); pendingStatus = true // the watch may still show an old status
            // Send a fresh reading first: pushing while a fetch is running
            // would hand the watch the reading from before the fetch (one
            // from the previous workout showed up as a stray graph dot).
            if isFetching {
                pushAfterFetch = true
            } else {
                if Date() >= nextFetchAt { await fetchGlucose() }
                pushToBLE()
            }
            // Then backfill the watch's 3-hour graph, trickled after the live
            // reading (a watch that reconnects after a gap gets it filled too):
            // the 36 blocks the watch's graph holds, for this watch only.
            let history = await fetchHistory()
            guard bleConnected, thisSubscription == subscription else { return }
            let oldest = Int(Date().timeIntervalSince1970 / 300) - 35
            historyQueue = history.map { ($0.sgv, Int($0.time.timeIntervalSince1970 / 300)) }.filter { $0.1 >= oldest }
            historyKickoff = !historyQueue.isEmpty
            drainBLE()
        }
    }
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            bleConnected = false
            // Paused within 5 min: most likely the workout ended, so no "Watch disconnected" notification.
            if let paused = watchPausedAt, Date().timeIntervalSince(paused) < 300 {
                logBLEEvent("Watch disconnected (workout paused or ended)")
            } else {
                logBLEEvent("Watch disconnected"); scheduleWatchLost()
            }
            watchPausedAt = nil
            historyQueue = []; historyKickoff = false; subscription += 1
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainBLE()
    }
    // The watch's pause byte (PROTOCOL.md). Only a single byte 01 at offset 0 counts.
    // One respond per call, to the first request.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        guard request.characteristic.uuid == kGlucoseCharUUID, request.offset == 0,
              let value = request.value, value.first == 1 else {
            peripheral.respond(to: request, withResult: .writeNotPermitted)
            return
        }
        watchPausedAt = Date()
        log("BLE", "Watch paused the workout")
        peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == kGlucoseCharUUID else { return }
        #if DEBUG
        if faultHandlesRead(peripheral, request) { return }
        #endif
        if restoredAwaitingFetch {
            // Relaunched, first fetch still running: the watch logs a failed read and asks again later.
            peripheral.respond(to: request, withResult: .unlikelyError)
        } else {
            if !historyKickoff, let packet = historyPayload() {
                request.value = packet
            } else {
                request.value = currentPayload()
            }
            peripheral.respond(to: request, withResult: .success)
        }
        if Date() >= nextFetchAt { Task { await fetchGlucose() } }
    }
}

#if DEBUG
// MARK: - Fault tests (debug builds only)
// The bridge misbehaving on purpose, so the watch's reaction can be checked
// against its log (tools/watch-log in the SuuntoPlus dev env). Each fault
// lasts the chosen time, then the bridge goes back to normal by itself. The
// fault log has the times to line up with the watch log. The screen stays on
// meanwhile: iOS stalls timers in the background.
enum BridgeFault: String, CaseIterable, Identifiable {
    case hang = "Bridge hangs"
    case vanish = "Service vanishes"
    case hide = "Drop and hide"
    case slow = "Slow replies"

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .hang: return "Stays connected, sends nothing, reads fail (as seen on 30 Oct). Watch: \u{201C}No phone\u{201D} and a buzz at 2 min, then a new connection; data back after the end."
        case .vanish: return "Removes the Bluetooth service but keeps advertising, like Stop then Start. Watch: reconnects after the end."
        case .hide: return "Removes the service and stops advertising, so the watch can't find the phone. Watch: \u{201C}No phone\u{201D} at 2 min, reconnects after the end. Keep the app open and the phone unlocked: nothing can wake the app during this test, so in the background it never ends (16 Nov)."
        case .slow: return "Answers reads 5 s late and sends no notifications. Watch: no \u{201C}No phone\u{201D}: reads still succeed (the watch gives up after ~10 s) and gaps stay under 2 min."
        }
    }
}

extension GlucoseBridgeManager {
    func startFault(_ fault: BridgeFault, seconds: Int) {
        guard bridgeActive, activeFault == nil else { return }
        activeFault = fault
        faultNote("START \(fault.rawValue), \(seconds) s")
        UIApplication.shared.isIdleTimerDisabled = true
        switch fault {
        case .hang, .slow: break // drainBLE and faultHandlesRead do the rest
        case .vanish:
            peripheralManager.removeAllServices(); glucoseCharacteristic = nil
        case .hide:
            peripheralManager.stopAdvertising(); isAdvertising = false
            peripheralManager.removeAllServices(); glucoseCharacteristic = nil
        }
        // Removing the service sends no unsubscribe, so the screen would keep
        // showing "connected" (2026-11-16). The watch subscribes again after the end.
        if fault == .vanish || fault == .hide {
            bleConnected = false
            statusMessage = "Service removed for a fault test"
        }
        faultTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFault() }
        }
    }

    func endFault() {
        guard let fault = activeFault else { return }
        faultTimer?.invalidate(); faultTimer = nil
        activeFault = nil
        faultNote("END \(fault.rawValue)")
        updateKeepAwake()
        switch fault {
        case .hang, .slow: pushToBLE()
        case .vanish, .hide: setupBLEService() // adds the service, then advertises
        }
    }

    // Reads during a fault: failed (hang) or answered 5 s late (slow, sealed
    // when sent; the watch gives up on a read after ~10 s, 2026-11-01).
    // True = handled.
    func faultHandlesRead(_ peripheral: CBPeripheralManager, _ request: CBATTRequest) -> Bool {
        switch activeFault {
        case .hang:
            faultNote("read refused")
            peripheral.respond(to: request, withResult: .unlikelyError)
            return true
        case .slow:
            faultNote("read, answering in 5 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                request.value = self.currentPayload()
                peripheral.respond(to: request, withResult: .success)
                self.faultNote("read answered")
            }
            return true
        default:
            return false
        }
    }

    // Ends the process like a system kill (memory pressure, a crash) so state
    // restoration can be tested. The note goes first; SIGKILL leaves no time to log.
    func endAppLikeIOS() {
        faultNote("END app: SIGKILL in 1 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { kill(getpid(), SIGKILL) }
    }

    func faultNote(_ text: String) {
        let line = Self.logTime.string(from: Date()) + " " + text
        if text.hasPrefix("START") || text.hasPrefix("END") || text.hasPrefix("read") { print("[FAULT] " + line) } // the rest is printed already
        faultLog.append(line)
        if faultLog.count > 200 { faultLog.removeFirst(faultLog.count - 200) }
    }
}
#endif
