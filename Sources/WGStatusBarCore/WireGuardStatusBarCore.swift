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
                            Text(interface.name)
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
                                    if let handshake = peer.latestHandshake {
                                        Text(L10n.string("peer.handshake", handshake))
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
                    model.refresh()
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

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 5

    public init() {
        refresh()
        startTimer()
    }

    internal init(testing interfaces: [WGInterface]) {
        self.interfaces = interfaces
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

    public func refresh() {
        isLoading = true
        lastError = nil

        Task.detached {
            do {
                let output = try await Self.runWGShow()
                let parsed = Self.parseWGShow(output)
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

    private static func runWGShow(timeout: TimeInterval = 5.0) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let output = try Self.runWGShowSync(timeout: timeout)
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
        process.arguments = ["-lc", "wg show"]

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

    static func parseWGShow(_ output: String) -> [WGInterface] {
        var interfaces: [WGInterface] = []
        var currentInterfaceName: String?
        var currentPeers: [WGPeer] = []
        var currentPeer: WGPeer?

        func flushInterfaceIfNeeded() {
            guard let name = currentInterfaceName else { return }
            var peers = currentPeers
            if let peer = currentPeer {
                peers.append(peer)
            }
            interfaces.append(WGInterface(name: name, peers: peers))
            currentInterfaceName = nil
            currentPeers = []
            currentPeer = nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("interface:") {
                flushInterfaceIfNeeded()
                currentInterfaceName = String(line.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("peer:") {
                if let peer = currentPeer {
                    currentPeers.append(peer)
                }
                let key = String(line.dropFirst("peer:".count)).trimmingCharacters(in: .whitespaces)
                currentPeer = WGPeer(publicKey: key)
                continue
            }

            if line.hasPrefix("latest handshake:") {
                let value = String(line.dropFirst("latest handshake:".count)).trimmingCharacters(in: .whitespaces)
                if var peer = currentPeer {
                    peer.latestHandshake = value
                    currentPeer = peer
                }
                continue
            }

            if line.hasPrefix("allowed ips:") {
                let value = String(line.dropFirst("allowed ips:".count)).trimmingCharacters(in: .whitespaces)
                if var peer = currentPeer {
                    peer.allowedIps = value
                    currentPeer = peer
                }
                continue
            }

            if line.hasPrefix("endpoint:") {
                let value = String(line.dropFirst("endpoint:".count)).trimmingCharacters(in: .whitespaces)
                if var peer = currentPeer {
                    peer.endpoint = value
                    currentPeer = peer
                }
                continue
            }

            if line.hasPrefix("transfer:") {
                let value = String(line.dropFirst("transfer:".count)).trimmingCharacters(in: .whitespaces)
                if var peer = currentPeer {
                    peer.transfer = value
                    currentPeer = peer
                }
                continue
            }
        }

        flushInterfaceIfNeeded()
        return interfaces
    }
}

public struct WGInterface: Identifiable {
    public let id: String
    public let name: String
    public var peers: [WGPeer]

    public var isConnected: Bool {
        peers.contains { $0.isActive }
    }

    public init(name: String, peers: [WGPeer]) {
        self.id = name
        self.name = name
        self.peers = peers
    }
}

public struct WGPeer: Identifiable {
    public let id: String
    public let publicKey: String
    public var latestHandshake: String?
    public var endpoint: String?
    public var allowedIps: String?
    public var transfer: String?

    public init(
        publicKey: String,
        latestHandshake: String? = nil,
        endpoint: String? = nil,
        allowedIps: String? = nil,
        transfer: String? = nil
    ) {
        self.id = publicKey
        self.publicKey = publicKey
        self.latestHandshake = latestHandshake
        self.endpoint = endpoint
        self.allowedIps = allowedIps
        self.transfer = transfer
    }

    public var isActive: Bool {
        guard let handshake = latestHandshake else { return false }
        let normalizedHandshake = handshake.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedHandshake != "never"
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
