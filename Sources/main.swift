import AppKit
import Foundation
import SwiftUI

@main
struct WGStatusBarApp: App {
    @StateObject private var model = WireGuardStatusModel()

    var body: some Scene {
        MenuBarExtra(model.menuTitle, systemImage: model.menuIcon) {
            StatusMenuView(model: model)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            EmptyView()
        }
    }
}

struct StatusMenuView: View {
    @ObservedObject var model: WireGuardStatusModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: model.menuIcon)
                    .foregroundStyle(model.statusColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WireGuard")
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
                Text("Интерфейсы не найдены")
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
                            Text(interface.isConnected ? "Подключён" : "Отключён")
                                .font(.caption)
                                .foregroundStyle(interface.isConnected ? .green : .secondary)
                        }

                        if interface.peers.isEmpty {
                            Text("Peers: не найдены")
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
                                        Text("Handshake: \(handshake)")
                                            .font(.caption2)
                                            .foregroundStyle(peer.isActive ? .green : .secondary)
                                    } else {
                                        Text("Handshake: unknown")
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
                Button("Обновить") {
                    model.refresh()
                }
                .disabled(model.isLoading)

                if model.isLoading {
                    ProgressView()
                        .scaleEffect(0.65)
                }
            }

            Button("Открыть конфиги WireGuard") {
                model.openWireGuardConfigFolder()
            }

            Button("Управление тоннелями (скоро)") {}
                .foregroundStyle(.secondary)
                .disabled(true)

            Divider()

            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

@MainActor
final class WireGuardStatusModel: ObservableObject {
    @Published private(set) var interfaces: [WGInterface] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 5

    init() {
        refresh()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    var statusText: String {
        if interfaces.isEmpty { return "Нет интерфейсов" }
        let activeCount = interfaces.filter(\.isConnected).count
        if activeCount == 0 { return "Нет активных подключений" }
        if activeCount == interfaces.count { return "Все подключены" }
        return "Подключено \(activeCount) из \(interfaces.count)"
    }

    var menuIcon: String {
        if interfaces.contains(where: \.isConnected) {
            return "lock.fill"
        }
        return "lock.slash"
    }

    var statusColor: Color {
        if interfaces.contains(where: \.isConnected) {
            return .green
        }
        return .secondary
    }

    var menuTitle: String {
        let iconPrefix = interfaces.contains(where: \.isConnected) ? "wg: on" : "wg: off"
        return iconPrefix
    }

    func refresh() {
        isLoading = true
        lastError = nil

        Task.detached {
            do {
                let output = try Self.runWGShow()
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

    func openWireGuardConfigFolder() {
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
        lastError = "Не найден каталог с конфигами WireGuard"
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private nonisolated static func runWGShow() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "wg show"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if errorText.isEmpty {
                throw NSError(
                    domain: "WGStatusBar",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Команда `wg show` завершилась с кодом \(process.terminationStatus)"]
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

    private nonisolated static func parseWGShow(_ output: String) -> [WGInterface] {
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

struct WGInterface: Identifiable {
    let id = UUID()
    let name: String
    var peers: [WGPeer]

    var isConnected: Bool {
        peers.contains { $0.isActive }
    }
}

struct WGPeer: Identifiable {
    let id = UUID()
    let publicKey: String
    var latestHandshake: String?
    var endpoint: String?
    var allowedIps: String?
    var transfer: String?

    var isActive: Bool {
        guard let handshake = latestHandshake else { return false }
        return !handshake.localizedCaseInsensitiveContains("never")
    }
}
