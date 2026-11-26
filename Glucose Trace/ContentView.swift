import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @EnvironmentObject var bridge: GlucoseBridgeManager
    @State private var showKey = false
    @State private var confirmNewKey = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                // --- Configuration ---
                Section("Data source") {
                    Picker("Source", selection: $bridge.dataSource) {
                        ForEach(GlucoseBridgeManager.DataSource.offered) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(bridge.bridgeActive)
                    if bridge.dataSource != .nightscout {
                        Picker("Units", selection: $bridge.unitsMgdl) {
                            Text("mmol/L").tag(false)
                            Text("mg/dL").tag(true)
                        }
                        Text("LibreLinkUp gives glucose and trend only, so the watch leaves out the IOB / COB line. It is an unofficial connection that Abbott can change without notice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if bridge.dataSource == .libreLinkUp {
                    Section("LibreLinkUp") {
                        TextField("Email", text: $bridge.lluEmail)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $bridge.lluPassword)
                        Text("The login of a LibreLinkUp follower account that you share your Libre data with. Set it up once in the LibreLinkUp app and accept its terms there.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(bridge.bridgeActive) // a half-typed password would be used at the next fetch
                }

                if bridge.dataSource == .dexcomShare {
                    Section("Dexcom Share") {
                        TextField("Phone (+ country code), email or username", text: $bridge.dexcomUsername)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $bridge.dexcomPassword)
                        Picker("Region", selection: $bridge.dexcomRegion) {
                            ForEach(DexcomRegion.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text("Your own Dexcom account login. If your email is refused, use your phone number with + and country code, even when the email works on Dexcom's website. In the Dexcom app, switch Share on and invite at least one follower, or nothing is shared.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(bridge.bridgeActive) // a half-typed password would be used at the next fetch
                }

                if bridge.dataSource == .nightscout {
                    Section("Nightscout") {
                        TextField("URL  e.g. https://mysite.nightscout.io", text: $bridge.nightscoutURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        SecureField("Access token (required)", text: $bridge.nightscoutToken)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text("Your site may deny anonymous access, so a token is required. Use one with only the **readable** role (Nightscout Admin Tools → Subjects), never your API_SECRET.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("CGM only logging", isOn: $bridge.cgmOnlyLogging)
                        Text("On: Nightscout has your glucose but not your injections or carbs, so the watch leaves out the IOB / COB line. Turn it off if you log them in Nightscout. An AID app's IOB and COB (Trio, Loop, AAPS) are always shown; the loop age comes from Trio and AAPS.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(bridge.bridgeActive) // a half-typed password would be used at the next fetch
                }

                // --- Watch key ---
                Section("Watch key") {
                    if let key = bridge.bridgeKey {
                        Text(showKey ? key.groupedHex : "•••• •••• •••• •••• •••• •••• •••• ••••")
                            .font(.body.monospaced())
                    } else {
                        Text("Unavailable until the iPhone is unlocked")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                            .disabled(bridge.bridgeKey == nil)
                        Spacer()
                        Button("Copy") {
                            // Local-only (no Universal Clipboard) and cleared after 2 minutes.
                            guard let key = bridge.bridgeKey else { return }
                            UIPasteboard.general.setItems(
                                [[UTType.plainText.identifier: key.groupedHex]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        }
                        .disabled(bridge.bridgeKey == nil)
                        Spacer()
                        Button("New key", role: .destructive) { confirmNewKey = true }
                    }
                    .buttonStyle(.borderless)

                    Text("Paste this key into Glucose Trace's Bridge key setting in the Suunto app. (Building the watch app yourself? Put it in data.json.) Glucose is encrypted with it, so only your watch can read it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog("Create a new key? The watch stops showing glucose until you enter the new key in the Suunto app.",
                                    isPresented: $confirmNewKey, titleVisibility: .visible) {
                    Button("Create new key", role: .destructive) { bridge.regenerateBridgeKey(); showKey = true }
                }

                // --- Current reading ---
                Section("Current glucose") {
                    HStack {
                        Text(bridge.glucoseMgdl > 0 ? bridge.glucoseText(bridge.glucoseMgdl) : "—")
                            .font(.largeTitle.bold())
                            .foregroundStyle(colourFor(bridge.glucoseMgdl))
                        Text(GlucoseBridgeManager.arrow(for: bridge.trend))
                            .font(.largeTitle)
                        Spacer()
                        Text(bridge.minutesAgo > 0 ? "\(bridge.minutesAgo) min ago" : "")
                            .foregroundStyle(.secondary)
                    }
                    if let iob = bridge.iobUnits {
                        Text(String(format: "IOB %.2f U", iob)
                             + (bridge.cobGrams.map { String(format: " · COB %.0f g", $0) } ?? "")
                             + (bridge.lastLoopDate.map { " · loop \(Int(Date().timeIntervalSince($0) / 60)) min ago" } ?? ""))
                            .foregroundStyle(.secondary)
                    }
                    if let warning = bridge.staleWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                // --- Status ---
                Section("Bridge status") {
                    Label(bridge.statusMessage, systemImage: bridge.bleConnected
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(bridge.bleConnected ? .green : .secondary)

                    Text(bridge.diagnosticsMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if bridge.isAdvertising && !bridge.bleConnected {
                        Label("Start your workout on the watch to connect",
                              systemImage: "applewatch")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }

                    Button(bridge.bridgeActive ? "Stop bridge" : "Start bridge") {
                        if bridge.bridgeActive {
                            bridge.stopBridge()
                        } else {
                            bridge.startBridge()
                        }
                    }
                    .tint(bridge.bridgeActive ? .red : .blue)

                    Button("Refresh now") {
                        bridge.refreshNow()
                    }
                    .disabled(!bridge.bridgeActive)

                }

                // --- Instructions ---
                Section("Setup instructions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Choose your data source and enter its login above (Nightscout: URL and a read-only token).")
                        Text("2. Copy the watch key into Glucose Trace's Bridge key setting in the Suunto app, then sync the watch.")
                        Text("3. Tap **Start bridge** — the app fetches your latest glucose, then starts advertising over Bluetooth.")
                        Text("4. On your Suunto watch, add the **Glucose Trace** SuuntoPlus app to your sport mode.")
                        Text("5. Start your workout. The watch connects automatically and polling begins.")
                        Text("6. Keep this app open until the watch shows a reading — iOS hides the bridge from new connections while it's in the background. The screen stays on until then.")
                        Text("7. After that the screen can lock. If the watch disconnects, you'll get a notification to reopen the app.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                #if DEBUG
                DeveloperOptionsLink()
                #endif
            }
            .navigationTitle("Glucose Trace")
        }
        // Hide glucose from the app-switcher snapshot.
        .overlay {
            if scenePhase != .active {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
    }

    // Standard 70-180 mg/dL (3.9-10.0 mmol/L) range.
    private func colourFor(_ mgdl: Int) -> Color {
        if mgdl <= 0   { return .primary }
        if mgdl < 70   { return .red }
        if mgdl > 180  { return .orange }
        return .green
    }
}
