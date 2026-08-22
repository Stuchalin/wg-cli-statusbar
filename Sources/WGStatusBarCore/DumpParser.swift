import Foundation

/// Парсер машинночитаемого вывода `wg show all dump` (tab-separated).
///
/// Формат (man wg, show.c wireguard-tools):
/// строка интерфейса — 5 полей: `name, private-key, public-key, listen-port, fwmark`;
/// строка пира — 9 полей: `name, public-key, preshared-key, endpoint, allowed-ips,
/// latest-handshake (unix-секунды, 0 = never), rx (байты), tx (байты), keepalive`.
/// Пустые значения — placeholder `(none)`, keepalive без значения — `off`.
///
/// Секретные поля (private-key интерфейса, preshared-key пира) читаются мимо
/// и в модель не попадают; сырой вывод нигде не логируется.
public func parseWGShowDump(_ dump: String) -> [WGInterface] {
    var interfaces: [WGInterface] = []
    var currentInterface: WGInterface?

    func flushCurrentInterface() {
        if let currentInterface {
            interfaces.append(currentInterface)
        }
        currentInterface = nil
    }

    for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        if fields.count == 5 {
            flushCurrentInterface()
            currentInterface = WGInterface(name: fields[0], peers: [])
            continue
        }

        if fields.count == 9, currentInterface != nil {
            let peer = WGPeer(
                publicKey: fields[1],
                endpoint: nonPlaceholder(fields[3]),
                allowedIps: nonPlaceholder(fields[4]),
                latestHandshake: parseEpoch(fields[5]),
                rxBytes: UInt64(fields[6]) ?? 0,
                txBytes: UInt64(fields[7]) ?? 0
            )
            currentInterface?.peers.append(peer)
        }
        // Прочее (мусорные строки, пир до строки интерфейса) — скипается.
    }

    flushCurrentInterface()
    return interfaces
}

/// `(none)` → nil, остальное как есть.
private func nonPlaceholder(_ field: String) -> String? {
    field == "(none)" ? nil : field
}

/// Unix-секунды → Date; `0` (never) и нечисловое значение → nil.
private func parseEpoch(_ field: String) -> Date? {
    guard let seconds = Double(field), seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}
