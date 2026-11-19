import SwiftUI
import ServiceManagement
import MarketCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @UIState private var loginStatus = SMAppService.mainApp.status
    @UIState private var loginError: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("Settings")).font(.title2.weight(.semibold))
                Spacer()
                Button(store.t("Done")) { store.showingSettings = false }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Form {
                Section(store.t("General")) {
                    Picker(store.t("Language"), selection: $store.preferences.language) {
                        Text("English").tag(AppLanguage.en)
                        Text("简体中文").tag(AppLanguage.zh)
                    }
                    Picker(store.t("Refresh interval"), selection: $store.preferences.refreshMinutes) {
                        Text(store.t("1 minute")).tag(1)
                        Text(store.t("5 minutes")).tag(5)
                        Text(store.t("15 minutes")).tag(15)
                    }
                    Toggle(store.t("Always on top"), isOn: $store.preferences.alwaysOnTop)
                    Text(store.t("Stays on one desktop. Always on top floats above apps on that desktop.")).font(.caption).foregroundStyle(.secondary)
                    Toggle(store.t("Red up, green down"), isOn: $store.preferences.redUp)
                    Toggle(store.t("Launch at login"), isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLogin))
                    if loginStatus == .requiresApproval { Button(store.t("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() } }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Text(store.t("Appearance follows your Mac.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(store.t("Data & connection")) {
                    Picker(store.t("Crypto source"), selection: $store.preferences.cryptoSource) {
                        ForEach(CryptoSource.allCases, id: \.self) { source in Text(store.t(source.title)).tag(source) }
                    }
                    Text(store.t("Uses your Mac’s network and proxy settings. A VPN may be needed for crypto.")).font(.caption).foregroundStyle(.secondary)
                    Text(store.t("Stock feeds are unofficial. Availability and delays can change.")).font(.caption).foregroundStyle(.secondary)
                    Text(store.t("Mainland connectivity has not been verified.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { store.diagnose() } label: {
                            HStack { if store.isDiagnosing { ProgressView().controlSize(.mini) }; Text(store.t(store.isDiagnosing ? "Testing…" : "Test connections")) }
                        }.disabled(store.isDiagnosing)
                        Spacer()
                        if !store.connectionResults.isEmpty {
                            Button(store.t("Copy report")) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.diagnosticsText(), forType: .string)
                            }
                        }
                    }
                    ForEach(store.connectionResults) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(item.success ? .green : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.caption.weight(.medium))
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                    if !store.connectionResults.isEmpty { Text(store.t("Connectivity tests use this network only; successful HTTP responses do not certify data freshness.")).font(.caption2).foregroundStyle(.secondary) }
                }
                Section {
                    HStack {
                        Text(store.t("Data is saved locally on this Mac.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(store.t("Show data folder")) { NSWorkspace.shared.selectFile(store.stateLocation, inFileViewerRootedAtPath: "") }
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 550, height: 580).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { loginStatus = SMAppService.mainApp.status }
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }
}
