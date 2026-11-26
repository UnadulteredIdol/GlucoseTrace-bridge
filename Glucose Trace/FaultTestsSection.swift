#if DEBUG
import SwiftUI
import UIKit

// Developer options: a screen of its own behind one row at the bottom of the
// settings, so the tests stay out of the way of the normal setup. Debug builds
// only, so none of this reaches a release build.
struct DeveloperOptionsLink: View {
    @EnvironmentObject var bridge: GlucoseBridgeManager

    var body: some View {
        Section {
            NavigationLink {
                Form { FaultTestsSection() }
                    .navigationTitle("Developer options")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Label("Developer options", systemImage: "hammer")
                    Spacer()
                    // A test keeps running after leaving the screen: show which.
                    if let fault = bridge.activeFault {
                        Text(fault.rawValue)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } footer: {
            Text("Debug builds only.")
        }
    }
}

// Fault tests: the bridge misbehaving on purpose for a set time (see
// BridgeFault in GlucoseBridgeManager.swift).
struct FaultTestsSection: View {
    @EnvironmentObject var bridge: GlucoseBridgeManager
    @State private var seconds = 180

    var body: some View {
        Section("Fault tests") {
            Picker("Duration", selection: $seconds) {
                Text("15 s").tag(15)
                Text("1 min").tag(60)
                Text("3 min").tag(180)
                Text("5 min").tag(300)
            }
            .pickerStyle(.segmented)

            ForEach(BridgeFault.allCases) { fault in
                Button {
                    bridge.startFault(fault, seconds: seconds)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fault.rawValue)
                        Text(fault.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(bridge.activeFault != nil || !bridge.isAdvertising)
            }

            if let fault = bridge.activeFault {
                Button("End \(fault.rawValue.lowercased()) now", role: .destructive) { bridge.endFault() }
            }

            Button {
                bridge.endAppLikeIOS()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("End app (as iOS would)")
                    Text("Kills the app 1 s after the tap, like a system kill, to test that iOS restores the bridge when the watch reads. Not the app switcher.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Start a workout on the watch first. Keep this screen open during a test.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !bridge.faultLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(bridge.faultLog.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)

                HStack {
                    Button("Copy log") { UIPasteboard.general.string = bridge.faultLog.joined(separator: "\n") }
                    Spacer()
                    Button("Clear", role: .destructive) { bridge.faultLog.removeAll() }
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
#endif
