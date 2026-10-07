import Foundation

/// 只保存 JSON，不把当前版本不认识的字段解释为可执行功能。
enum ConfigJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), string(String), integer(Int64), unsigned(UInt64), number(Decimal)
    case array([ConfigJSON]), object([String: ConfigJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([ConfigJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ConfigJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var identity: String? {
        guard case .object(let fields) = self else { return nil }
        if case .string(let id) = fields["id"] { return "id:" + (UUID(uuidString: id)?.uuidString ?? id) }
        if case .string(let key) = fields["itemKey"] { return "item:" + key }
        return nil
    }
}

/// 只记录未知字段；已知值按用户编辑写回，按条目身份保留附加字段。
struct ConfigPreservation: Equatable, Sendable {
    struct Element: Equatable, Sendable {
        var index: Int
        var identity: String?
        var fields: ConfigPreservation
        var opaque: ConfigJSON?
    }

    var unknown: [String: ConfigJSON] = [:]
    var children: [String: ConfigPreservation] = [:]
    var elements: [Element] = []
    var isEmpty: Bool { unknown.isEmpty && children.isEmpty && elements.isEmpty }

    init() {}

    init(original: ConfigJSON, known: ConfigJSON) {
        switch (original, known) {
        case (.object(let original), .object(let known)):
            for (key, value) in original {
                if let current = known[key] {
                    let extra = Self(original: value, known: current)
                    if !extra.isEmpty { children[key] = extra }
                } else {
                    unknown[key] = value
                }
            }
        case (.array(let original), .array(let known)):
            for (index, value) in original.enumerated() {
                var current = value.identity.flatMap { id in known.first { $0.identity == id } }
                if current == nil, value.identity == nil, index < known.count {
                    if case .object = known[index] {
                        if case .object = value { current = known[index] }
                    } else { current = known[index] }
                }
                if let current {
                    let extra = Self(original: value, known: current)
                    if !extra.isEmpty { elements.append(Element(index: index, identity: value.identity, fields: extra)) }
                } else {
                    // 读失败的条目不生效，原样放回原位置。
                    elements.append(Element(index: index, identity: value.identity, fields: Self(), opaque: value))
                }
            }
        default: break
        }
    }

    /// 合并两台机器时保留两边的附加字段；调用方决定冲突时优先的一侧。
    func combining(with fallback: Self) -> Self {
        var result = self
        result.unknown = fallback.unknown.merging(unknown) { _, preferred in preferred }
        for (key, value) in fallback.children {
            result.children[key] = children[key]?.combining(with: value) ?? value
        }
        for element in fallback.elements {
            if let index = result.elements.firstIndex(where: {
                if let id = element.identity { return $0.identity == id }
                return $0.index == element.index && $0.opaque == element.opaque
            }) {
                result.elements[index].fields = result.elements[index].fields.combining(with: element.fields)
            } else { result.elements.append(element) }
        }
        return result
    }

    func merging(into known: ConfigJSON) -> ConfigJSON {
        switch known {
        case .object(let known):
            var result = unknown
            for (key, value) in known { result[key] = children[key]?.merging(into: value) ?? value }
            return .object(result)
        case .array(let known):
            var result = known.enumerated().map { index, value in
                let extra = elements.first { element in
                    element.opaque == nil && (value.identity != nil
                        ? element.identity == value.identity : element.identity == nil && element.index == index)
                }
                return extra?.fields.merging(into: value) ?? value
            }
            for extra in elements where extra.opaque != nil {
                if let id = extra.identity, known.contains(where: { $0.identity == id }) { continue }
                result.insert(extra.opaque!, at: min(extra.index, result.count))
            }
            return .array(result)
        default: return known
        }
    }
}

extension ConfigJSON {
    /// 已移除的旧内置设置仍需清理，不能因保留未来字段而把它们写回来。
    func removingLegacySettings(profiles decoded: [Profile]) -> ConfigJSON {
        guard case .object(var root) = self else { return self }
        root.removeValue(forKey: "engine")
        if case .array(let profiles) = root["profiles"] {
            var decodedIndex = 0
            root["profiles"] = .array(profiles.compactMap { value in
                guard case .object(var fields) = value else { return value }
                if fields["engine"] == .bool(true) { return nil }
                fields.removeValue(forKey: "engine")
                // 容错读取生成的身份也用于附加字段，避免缺失或无效 id 的配置重复写回。
                if decodedIndex < decoded.count {
                    fields["id"] = .string(decoded[decodedIndex].id.uuidString)
                    decodedIndex += 1
                }
                return .object(fields)
            })
        }
        if case .object(var automation) = root["automation"], case .array(let rules) = automation["networkRules"] {
            automation["networkRules"] = .array(rules.filter { rule in
                if case .object(let fields) = rule, case .string(let action) = fields["action"] { return !action.hasPrefix("mode:") }
                return true
            })
            root["automation"] = .object(automation)
        }
        return .object(root)
    }
}
