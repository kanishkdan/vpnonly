import Foundation
import Darwin

// Small bundled parser used by the privileged engine and the unprivileged app.
// Keeping this native removes the accidental dependency on Xcode's python3
// shim on clean customer Macs.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func stdinData() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

private func validIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy {
        guard !$0.isEmpty, $0.allSatisfy(\.isNumber), let n = Int($0) else { return false }
        return n >= 0 && n <= 255
    }
}

private func validBase64Key(_ value: String) -> Bool {
    guard value.count == 44, let data = Data(base64Encoded: value) else { return false }
    return data.count == 32
}

private func validHostname(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
    return value.split(separator: ".").allSatisfy { label in
        !label.isEmpty && label.count <= 63 &&
        label.first != "-" && label.last != "-" &&
        label.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
}

private func validIPv6(_ value: String) -> Bool {
    var address = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
}

private func validIPv4CIDR(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, validIPv4(String(parts[0])),
          let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
    return true
}

private func validEndpoint(_ value: String) -> Bool {
    if value.hasPrefix("[") {
        guard let close = value.lastIndex(of: "]"),
              value.index(after: close) < value.endIndex,
              value[value.index(after: close)] == ":" else { return false }
        let host = String(value[value.index(after: value.startIndex)..<close])
        let port = String(value[value.index(close, offsetBy: 2)...])
        return validIPv6(host) && Int(port).map { (1...65535).contains($0) } == true
    }
    guard let colon = value.lastIndex(of: ":"), !value[..<colon].contains(":") else { return false }
    let host = String(value[..<colon])
    let port = String(value[value.index(after: colon)...])
    return (validHostname(host) || validIPv4(host)) && Int(port).map { (1...65535).contains($0) } == true
}

private func writePrivateFile(_ text: String, to path: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { fail("cannot write parsed config") }
    defer { close(fd) }
    _ = fchmod(fd, S_IRUSR | S_IWUSR)
    let bytes = Array(text.utf8)
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: written), bytes.count - written)
        }
        guard n > 0 else { fail("cannot write parsed config") }
        written += n
    }
}

private struct NordCountry: Decodable {
    let id: Int
    let code: String
}

private struct NordServer: Decodable {
    struct Technology: Decodable {
        struct Metadata: Decodable { let value: String }
        let identifier: String
        let metadata: [Metadata]?
    }
    let hostname: String
    let station: String
    let technologies: [Technology]
}

private func countryID(code: String) {
    guard let list = try? JSONDecoder().decode([NordCountry].self, from: stdinData()),
          let match = list.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) else {
        fail("no NordVPN country found for '\(code)'")
    }
    print(match.id)
}

private func nordServers() {
    guard let list = try? JSONDecoder().decode([NordServer].self, from: stdinData()) else {
        fail("NordVPN returned malformed server data")
    }
    var found = 0
    for server in list {
        guard validHostname(server.hostname), validIPv4(server.station),
              let tech = server.technologies.first(where: { $0.identifier == "wireguard_udp" }),
              let key = tech.metadata?.lazy.map(\.value).first(where: validBase64Key) else { continue }
        print("\(server.hostname) \(server.station) \(key)")
        found += 1
    }
    if found == 0 { fail("NordVPN returned no usable WireGuard servers") }
}

private func parseWG(input: String, output: String) {
    guard let data = FileManager.default.contents(atPath: input),
          var text = String(data: data, encoding: .utf8) else { fail("cannot read config") }
    if text.hasPrefix("\u{feff}") { text.removeFirst() }

    var section: String?
    var interface: [String: String] = [:]
    var peer: [String: String] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
            section = (name == "interface" || name == "peer") ? name : nil
            continue
        }
        guard let section, let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if ["address", "dns", "allowedips"].contains(key), let hash = value.firstIndex(of: "#") {
            value = value[..<hash].trimmingCharacters(in: .whitespaces)
        }
        if section == "interface" {
            if interface[key] == nil { interface[key] = value }
        } else if peer[key] == nil {
            peer[key] = value
        }
    }

    guard let privateKey = interface["privatekey"], validBase64Key(privateKey) else { fail("config is missing a valid PrivateKey") }
    guard let address = interface["address"] else { fail("config is missing Address") }
    guard let publicKey = peer["publickey"], validBase64Key(publicKey) else { fail("config is missing a valid PublicKey") }
    guard let endpoint = peer["endpoint"], validEndpoint(endpoint) else { fail("config has an invalid Endpoint") }
    if let psk = peer["presharedkey"], !validBase64Key(psk) { fail("config has an invalid PresharedKey") }

    let ipv4 = address.replacingOccurrences(of: ";", with: ",")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).split(separator: "/").first.map(String.init) ?? "" }
        .first(where: validIPv4)
    guard let ipv4 else { fail("config has no IPv4 Address — IPv6-only tunnels aren't supported yet") }

    let allowed4: String
    if let rawAllowed = peer["allowedips"] {
        let allowed = rawAllowed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.contains(":") }
        guard !allowed.isEmpty, allowed.allSatisfy(validIPv4CIDR) else {
            fail("config has no valid IPv4 AllowedIPs")
        }
        allowed4 = allowed.joined(separator: ",")
    } else {
        allowed4 = "0.0.0.0/0"
    }

    var lines = ["[Interface]", "PrivateKey = \(privateKey)", "", "[Peer]", "PublicKey = \(publicKey)"]
    if let psk = peer["presharedkey"] { lines.append("PresharedKey = \(psk)") }
    lines += ["Endpoint = \(endpoint)", "AllowedIPs = \(allowed4)", "PersistentKeepalive = 25", ""]
    writePrivateFile(lines.joined(separator: "\n"), to: output)
    print("\(ipv4) \(endpoint)")
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: vpnparse country-id|nord-servers|wg-config") }
switch args[1] {
case "country-id":
    guard args.count == 3 else { fail("usage: vpnparse country-id <code>") }
    countryID(code: args[2])
case "nord-servers":
    guard args.count == 2 else { fail("usage: vpnparse nord-servers") }
    nordServers()
case "wg-config":
    guard args.count == 4 else { fail("usage: vpnparse wg-config <input> <output>") }
    parseWG(input: args[2], output: args[3])
default:
    fail("unknown vpnparse command")
}
