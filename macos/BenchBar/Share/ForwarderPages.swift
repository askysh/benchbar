import Foundation

/// The pages the forwarder serves itself when it cannot or must not relay. Static HTML with
/// no script and no external URL; plain text for anything that does not accept HTML.
nonisolated enum ForwarderPage: Equatable, Sendable {
    case ended(host: String)
    case removed(host: String, askAgain: String)
    case hostOffline(host: String, lastSeen: String)
    case identityChanged(host: String)
    case notAvailable

    var status: Int {
        switch self {
        case .hostOffline: return 502
        case .notAvailable, .removed, .ended, .identityChanged: return 403
        }
    }

    var title: String {
        switch self {
        case .ended: return "Room ended"
        case .removed: return "Removed from the room"
        case .hostOffline: return "Not sharing right now"
        case .identityChanged: return "This room looks different"
        case .notAvailable: return "Not available"
        }
    }

    /// R3.8 copy.
    var message: String {
        switch self {
        case .ended(let host): return "\(host) ended the room."
        case .removed(let host, _): return "\(host) removed you from this room."
        case .hostOffline(let host, let lastSeen): return "\(host) isn't sharing right now (last seen \(lastSeen))."
        case .identityChanged(let host):
            return "\(host)'s Mac looks different from the one you joined. BenchBar did not connect. If \(host) reset BenchBar, remove the room and join again with a new code."
        case .notAvailable: return "This page isn't available through BenchBar."
        }
    }

    func response(acceptsHTML: Bool) -> Data {
        let body: String
        let type: String
        if acceptsHTML {
            type = "text/html; charset=utf-8"
            var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(Self.escape(title))</title></head><body><h1>\(Self.escape(title))</h1><p>\(Self.escape(message))</p>"
            if case .removed(_, let askAgain) = self, askAgain.hasPrefix("benchbar://share/") {
                html += "<p><a href=\"\(Self.escape(askAgain))\">Ask again</a></p>"
            }
            body = html + "</body></html>"
        } else {
            type = "text/plain; charset=utf-8"
            body = message + "\n"
        }
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(title)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
