import Foundation

/// A property wrapper preserves absent versus present-invalid, including null.
@propertyWrapper
struct AudioDuckingBackupField: Codable {
    var wrappedValue: AudioDuckingBackupPayload

    init(wrappedValue: AudioDuckingBackupPayload = .absent) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        guard let value = try? AudioDuckingConfiguration(from: decoder), value.isValid else {
            wrappedValue = .invalid
            return
        }
        wrappedValue = .valid(value)
    }

    func encode(to encoder: Encoder) throws {
        switch wrappedValue {
        case .absent:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .invalid:
            throw EncodingError.invalidValue(wrappedValue, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid audio ducking payload cannot be exported"))
        case .valid(let value):
            guard value.isValid else {
                throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                    debugDescription: "Invalid audio ducking configuration"))
            }
            try value.encode(to: encoder)
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: AudioDuckingBackupField.Type, forKey key: Key) throws -> AudioDuckingBackupField {
        guard contains(key) else { return AudioDuckingBackupField(wrappedValue: .absent) }
        return try AudioDuckingBackupField(from: superDecoder(forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: AudioDuckingBackupField, forKey key: Key) throws {
        if case .absent = value.wrappedValue { return }
        try value.encode(to: superEncoder(forKey: key))
    }
}
