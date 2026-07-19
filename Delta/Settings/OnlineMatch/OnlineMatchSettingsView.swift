//
//  OnlineMatchSettingsView.swift
//  Delta
//
//  Settings for online (relay) Melee matches: the matchmaking server REST base
//  URL, the raw-TCP relay endpoint (kept independently configurable — it cannot
//  ride the Cloudflare tunnel that fronts REST), and the shared HTTP Basic-auth
//  credential. Storage lives in Settings/UserDefaults like every other Delta
//  setting; this view is a minimal Form over those keys.
//

import SwiftUI

import GCDeltaCore

/// Bridges the stored settings to a `MeleeNetplayRelaySession.ServerConfig`.
enum OnlineMatchConfig
{
    /// Build a session config from the stored settings, or nil if the server is
    /// not usably configured (no REST URL, or no relay port). The relay host
    /// falls back to the REST hostname when left blank.
    static func makeServerConfig() -> MeleeNetplayRelaySession.ServerConfig?
    {
        guard let urlString = Settings.matchmakingServerURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString),
              let scheme = url.scheme, (scheme == "http" || scheme == "https"),
              let restHost = url.host
        else { return nil }

        let port = Settings.matchmakingRelayPort
        guard (1...65535).contains(port) else { return nil }

        let configuredRelayHost = Settings.matchmakingRelayHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayHost = (configuredRelayHost?.isEmpty == false) ? configuredRelayHost! : restHost

        return MeleeNetplayRelaySession.ServerConfig(
            restBaseURL: url,
            relayHost: relayHost,
            relayPort: UInt16(port),
            username: Settings.matchmakingUsername ?? "",
            password: Settings.matchmakingPassword ?? ""
        )
    }

    /// Whether the Host/Join Online Match actions should be offered.
    static var isConfigured: Bool { makeServerConfig() != nil }
}

@available(iOS 15, *)
struct OnlineMatchSettingsView: View
{
    var localizedTitle: String { NSLocalizedString("Online Match", comment: "") }

    @SwiftUI.State private var serverURL: String = Settings.matchmakingServerURL ?? ""
    @SwiftUI.State private var relayHost: String = Settings.matchmakingRelayHost ?? ""
    @SwiftUI.State private var relayPort: String = Settings.matchmakingRelayPort > 0 ? String(Settings.matchmakingRelayPort) : ""
    @SwiftUI.State private var username: String = Settings.matchmakingUsername ?? ""
    @SwiftUI.State private var password: String = Settings.matchmakingPassword ?? ""

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("https://matchmaking.example.com", comment: ""), text: $serverURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: serverURL) { newValue in
                        Settings.matchmakingServerURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
            } header: {
                Text(NSLocalizedString("Matchmaking Server URL", comment: ""))
            } footer: {
                Text(NSLocalizedString("HTTPS address of the matchmaking server (REST). Required to host or join online matches.", comment: ""))
            }

            Section {
                TextField(NSLocalizedString("Same as server host", comment: ""), text: $relayHost)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: relayHost) { newValue in
                        Settings.matchmakingRelayHost = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                TextField(NSLocalizedString("Relay Port", comment: ""), text: $relayPort)
                    .keyboardType(.numberPad)
                    .onChange(of: relayPort) { newValue in
                        Settings.matchmakingRelayPort = Int(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    }
            } header: {
                Text(NSLocalizedString("Relay", comment: ""))
            } footer: {
                Text(NSLocalizedString("The raw-TCP relay endpoint. Leave the host blank to reuse the server hostname.", comment: ""))
            }

            Section {
                TextField(NSLocalizedString("Username", comment: ""), text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: username) { newValue in
                        Settings.matchmakingUsername = newValue
                    }
                SecureField(NSLocalizedString("Password", comment: ""), text: $password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: password) { newValue in
                        Settings.matchmakingPassword = newValue
                    }
            } header: {
                Text(NSLocalizedString("Authentication", comment: ""))
            } footer: {
                Text(NSLocalizedString("HTTP Basic-auth credential shared with the matchmaking server.", comment: ""))
            }
        }
    }
}

@available(iOS 15, *)
extension OnlineMatchSettingsView
{
    static func makeViewController() -> UIHostingController<some View>
    {
        let view = OnlineMatchSettingsView()

        let hostingController = UIHostingController(rootView: view)
        hostingController.navigationItem.largeTitleDisplayMode = .never
        hostingController.navigationItem.title = view.localizedTitle
        return hostingController
    }
}

@available(iOS 15, *)
#Preview {
    NavigationView {
        OnlineMatchSettingsView()
    }
}
