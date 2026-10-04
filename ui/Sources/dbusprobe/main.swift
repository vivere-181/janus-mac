// Developer tool: dumps KDE Connect's D-Bus object tree (interfaces + current property values).
// Usage: dbusprobe [path] [--calls "path|iface|member"]...
import Foundation
import KDEConnectKit

let address = try String(contentsOfFile: KDEConnectEngine.addressFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let bus = try DBusConnection(address: address)
try await bus.hello()
let dest = "org.kde.kdeconnect"
var args = Array(CommandLine.arguments.dropFirst())

if args.first == "--call", args.count >= 2 {
    let p = args[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    let callArgs: [DBusValue] = p.dropFirst(3).map { a in
        if a == "true" || a == "false" { return .bool(a == "true") }
        if let i = Int32(a) { return .int32(i) }
        return .string(a)
    }
    let r = try await bus.call(destination: dest, path: p[0], interface: p[1], member: p[2], callArgs)
    r.forEach { print($0) }
    exit(0)
}

// --listen "path|iface|member" [seconds]: trigger a call, then print incoming signals' shapes (values redacted).
if args.first == "--listen", args.count >= 2 {
    func shape(_ v: DBusValue) -> String {
        switch v {
        case .string(let s): return "s(\(s.count))"
        case .array(let e, let vs): return "a\(e)[\(vs.count)]" + (vs.first.map { " first=" + shape($0) } ?? "")
        case .structure(let vs): return "(" + vs.map(shape).joined(separator: ", ") + ")"
        case .variant(let i): return "v<" + shape(i) + ">"
        case .dict(_, _, let kv): return "{" + kv.prefix(4).map { "\($0.0): \(shape($0.1))" }.joined(separator: ", ") + "}"
        default: return v.signature + "=" + v.description
        }
    }
    bus.addSignalHandler { m in
        guard m.sender != "org.freedesktop.DBus" else { return }
        print("signal \(m.interface ?? "").\(m.member ?? "") sig=\(m.body.map(\.signature).joined()) :: \(m.body.map(shape).joined(separator: " | "))")
    }
    try await bus.addMatch("type='signal'")
    let p = args[1].split(separator: "|").map(String.init)
    _ = try? await bus.call(destination: dest, path: p[0], interface: p[1], member: p[2])
    try await Task.sleep(for: .seconds(Double(args.count > 2 ? args[2] : "8") ?? 8))
    exit(0)
}

func walk(_ path: String, depth: Int) async {
    guard depth < 6, let xml = try? await bus.introspect(destination: dest, path: path) else { return }
    let doc = try? XMLDocument(xmlString: xml)
    let ifaces = (try? doc?.nodes(forXPath: "/node/interface")) ?? []
    for case let iface as XMLElement in ifaces {
        guard let name = iface.attribute(forName: "name")?.stringValue, !name.hasPrefix("org.freedesktop") else { continue }
        print("\n\(path)  [\(name)]")
        let props = (try? await bus.getAllProperties(destination: dest, path: path, interface: name)) ?? [:]
        for case let el as XMLElement in iface.children ?? [] {
            let n = el.attribute(forName: "name")?.stringValue ?? ""
            switch el.name {
            case "property":
                let t = el.attribute(forName: "type")?.stringValue ?? ""
                let a = el.attribute(forName: "access")?.stringValue ?? ""
                let v = props[n].map { String(String(describing: $0).prefix(200)) } ?? "?"
                print("  prop \(n): \(t) \(a) = \(v)")
            case "method", "signal":
                let argsDesc = (el.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == "arg" }.map {
                    "\($0.attribute(forName: "direction")?.stringValue ?? "") \($0.attribute(forName: "name")?.stringValue ?? ""):\($0.attribute(forName: "type")?.stringValue ?? "")"
                }.joined(separator: ", ")
                print("  \(el.name!) \(n)(\(argsDesc))")
            default: break
            }
        }
    }
    let children = ((try? doc?.nodes(forXPath: "/node/node")) ?? []).compactMap { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue }
    for c in children { await walk(path == "/" ? "/\(c)" : "\(path)/\(c)", depth: depth + 1) }
}

await walk(args.first ?? "/modules/kdeconnect", depth: 0)
