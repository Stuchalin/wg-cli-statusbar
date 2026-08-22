import AppKit
import Foundation
import SwiftUI

private enum WGShowError: LocalizedError {
    case commandTimeout

    var errorDescription: String? {
        switch self {
        case .commandTimeout:
            return L10n.string("error.wg_show_timeout")
        }
    }
}

/// Запускает `wg show all dump` и возвращает сырой вывод; инжектится для тестов.
public protocol WGShowCommandRunning {
    func runDump() async throws -> String
}

/// Продакшн-раннер: `/bin/zsh -lc "wg show all dump"` (login-shell, чтобы Homebrew's
/// `wg` был на PATH) с таймаутом. Сырой вывод содержит секреты — не логировать.
public struct ProcessWGShowRunner: WGShowCommandRunning {
    public init() {}

    public func runDump() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let output = try Self.runWGShowSync(timeout: 5.0)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runWGShowSync(timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "wg show all dump"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let stateQueue = DispatchQueue(label: "com.wgstatusbar.runwgshow.state")
        var timedOut = false

        try process.run()
        let timeoutTask = DispatchWorkItem {
            stateQueue.sync {
                timedOut = true
            }
            if process.isRunning {
                process.terminate()
            }
        }
        process.terminationHandler = { _ in
            timeoutTask.cancel()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        process.waitUntilExit()

        if stateQueue.sync(execute: { timedOut }) {
            throw WGShowError.commandTimeout
        }

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if errorText.isEmpty {
                throw NSError(
                    domain: "WGStatusBar",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("error.wg_show_failed", String(process.terminationStatus))]
                )
            }
            throw NSError(
                domain: "WGStatusBar",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        return output
    }
}

/// Именование туннелей для модели; инжектится для тестов (моки со счётчиками).
public protocol WireGuardTunnelNaming: AnyObject {
    func displayName(for interfaceName: String) -> String
    func rescan()
}

extension WireGuardTunnelNamer: WireGuardTunnelNaming {}

public struct StatusMenuView: View {
    @ObservedObject var model: WireGuardStatusModel

    public init(model: WireGuardStatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: model.menuIcon)
                .foregroundStyle(model.statusColor)
                .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("app.title"))
                        .font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if model.interfaces.isEmpty {
                Text(L10n.string("status.no_interfaces"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.interfaces) { interface in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(interface.displayName)
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Text(interface.isConnected ? L10n.string("state.connected") : L10n.string("state.disconnected"))
                                .font(.caption)
                                .foregroundStyle(interface.isConnected ? .green : .secondary)
                        }

                        if interface.peers.isEmpty {
                            Text(L10n.string("peers.not_found"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(interface.peers) { peer in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.publicKey)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("↓ \(Formatters.formatBytes(peer.rxBytes))  ↑ \(Formatters.formatBytes(peer.txBytes))")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    if let handshake = peer.latestHandshake {
                                        Text(L10n.string("peer.handshake", Formatters.formatAgo(handshake)))
                                            .font(.caption2)
                                            .foregroundStyle(peer.isActive ? .green : .secondary)
                                    } else {
                                        Text(L10n.string("peer.handshake_unknown"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button(L10n.string("button.refresh")) {
                    model.refresh(forceNameRescan: true)
                }
                .disabled(model.isLoading)

                if model.isLoading {
                    ProgressView()
                        .scaleEffect(0.65)
                }
            }

            Button(L10n.string("button.open_configs")) {
                model.openWireGuardConfigFolder()
            }

            Button(L10n.string("button.tunnel_management_soon")) {}
                .foregroundStyle(.secondary)
                .disabled(true)

            Divider()

            Button(L10n.string("button.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

public final class WireGuardStatusModel: ObservableObject {
    @Published public private(set) var interfaces: [WGInterface] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let commandRunner: WGShowCommandRunning
    private let tunnelNamer: WireGuardTunnelNaming
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 5

    public init() {
        self.commandRunner = ProcessWGShowRunner()
        self.tunnelNamer = WireGuardTunnelNamer()
        refresh()
        startTimer()
    }

    internal init(testing interfaces: [WGInterface]) {
        self.commandRunner = ProcessWGShowRunner()
        self.tunnelNamer = WireGuardTunnelNamer()
        self.interfaces = interfaces
    }

    internal init(commandRunner: WGShowCommandRunning, tunnelNamer: WireGuardTunnelNaming) {
        self.commandRunner = commandRunner
        self.tunnelNamer = tunnelNamer
    }

    deinit {
        timer?.invalidate()
    }

    public var statusText: String {
        if interfaces.isEmpty { return L10n.string("status.no_interfaces") }
        let activeCount = interfaces.filter(\.isConnected).count
        if activeCount == 0 { return L10n.string("status.no_active_connections") }
        if activeCount == interfaces.count { return L10n.string("status.all_connected") }
        return L10n.string("status.connected_count", String(activeCount), String(interfaces.count))
    }

    public var menuIcon: String {
        if interfaces.contains(where: \.isConnected) {
            return "lock.fill"
        }
        return "lock.slash"
    }

    public var statusColor: Color {
        if interfaces.contains(where: \.isConnected) {
            return .green
        }
        return .secondary
    }

    public var menuTitle: String {
        let iconPrefix = interfaces.contains(where: \.isConnected)
            ? L10n.string("menu.title.on")
            : L10n.string("menu.title.off")
        return iconPrefix
    }

    /// `forceNameRescan` — принудительный рескан имён туннелей (кнопка «Обновить»);
    /// обычный тик ресканит лениво и только встретив незнакомый utun.
    public func refresh(forceNameRescan: Bool = false) {
        isLoading = true
        lastError = nil

        let runner = commandRunner
        let namer = tunnelNamer
        Task.detached {
            do {
                let output = try await runner.runDump()
                let parsed = Self.resolveDisplayNames(
                    for: parseWGShowDump(output),
                    namer: namer,
                    forcingRescan: forceNameRescan
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.interfaces = parsed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// Проставляет интерфейсам `displayName` из namer'а.
    ///
    /// Незнакомый utun после первого прохода — единственный исключительный
    /// `rescan()` за refresh (между тиками мог подняться новый конфиг wg-quick),
    /// затем повторный резолв только ещё неизвестных имён. При принудительном
    /// рескане второго не нужно — каталог только что перечитан.
    private static func resolveDisplayNames(
        for interfaces: [WGInterface],
        namer: WireGuardTunnelNaming,
        forcingRescan: Bool
    ) -> [WGInterface] {
        if forcingRescan {
            namer.rescan()
        }

        var resolved = interfaces
        var hasUnknownName = false
        for index in resolved.indices {
            let displayName = namer.displayName(for: resolved[index].name)
            hasUnknownName = hasUnknownName || displayName == resolved[index].name
            resolved[index].displayName = displayName
        }

        if hasUnknownName && !forcingRescan {
            namer.rescan()
            for index in resolved.indices where resolved[index].displayName == resolved[index].name {
                resolved[index].displayName = namer.displayName(for: resolved[index].name)
            }
        }

        return resolved
    }

    public func openWireGuardConfigFolder() {
        let candidateFolders: [URL] = [
            URL(fileURLWithPath: "/usr/local/etc/wireguard"),
            URL(fileURLWithPath: "/etc/wireguard"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("wireguard")
        ]

        for path in candidateFolders {
            if FileManager.default.fileExists(atPath: path.path) {
                NSWorkspace.shared.open(path)
                return
            }
        }
        lastError = L10n.string("error.config_folder_not_found")
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }
}

enum L10n {
    static func string(_ key: String, _ args: String...) -> String {
        let raw = NSLocalizedString(key, tableName: "Localizable", bundle: .module, comment: "")
        if args.isEmpty {
            return raw
        }
        return String(format: raw, arguments: args)
    }
}
