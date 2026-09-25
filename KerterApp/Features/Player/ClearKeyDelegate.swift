import AVFoundation

/// Resuelve claves ClearKey para canales cifrados usando el soporte nativo de
/// `AVContentKeySession` (sin dependencias externas). El backend nos da la
/// KID y la key; aquí se convierten al formato JSON Web Key que pide
/// AVFoundation para el key system `.clearKey`.
final class ClearKeyDelegate: NSObject, AVContentKeySessionDelegate {
    private let keyId: Data
    private let key: Data

    /// `nil` si la KID o la key vienen vacías o mal formadas. Acepta hex
    /// ("1a2b…"), UUID con guiones, base64 y base64url (el backend a veces
    /// manda un formato u otro según el canal).
    init?(keyIdHex: String, keyHex: String) {
        guard let keyId = DRMKeyFormat.data(from: keyIdHex),
              let key = DRMKeyFormat.data(from: keyHex),
              keyId.count == 16, key.count == 16 else { return nil }
        self.keyId = keyId
        self.key = key
    }

    /// Variante directa cuando el llamador ya normalizó el material.
    init?(keyId: Data, key: Data) {
        guard keyId.count == 16, key.count == 16 else { return nil }
        self.keyId = keyId
        self.key = key
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        ProxyLog.log("ClearKey: didProvide keyRequest identifier=\(String(describing: keyRequest.identifier))")
        respond(to: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession,
                            didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        ProxyLog.log("ClearKey: didProvideRenewing keyRequest identifier=\(String(describing: keyRequest.identifier))")
        respond(to: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession,
                            contentKeyRequest keyRequest: AVContentKeyRequest,
                            didFailWithError err: Error) {
        ProxyLog.log("ClearKey: keyRequest FALLÓ: \(err.localizedDescription)")
    }

    /// El stream solo trae una clave, así que la key request rara vez trae la
    /// KID en `keyRequest.identifier`; usamos siempre la única que tenemos.
    private func respond(to keyRequest: AVContentKeyRequest) {
        let jwk: [String: Any] = [
            "keys": [[
                "kty": "oct",
                "k": key.base64URLEncodedString(),
                "kid": keyId.base64URLEncodedString()
            ]],
            "type": "temporary"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: jwk) else {
            keyRequest.processContentKeyResponseError(
                NSError(domain: "ClearKey", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No se pudo construir la respuesta de clave."]))
            return
        }
        ProxyLog.log("ClearKey: respondiendo con JWK kid=\(keyId.base64URLEncodedString())")
        let response = AVContentKeyResponse(clearKeyData: data, initializationVector: nil)
        keyRequest.processContentKeyResponse(response)
    }
}

private extension Data {
    /// "1a2b3c" → bytes. Acepta mayúsculas/minúsculas y un largo par.
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Base64 "URL-safe" sin relleno, como pide el formato JSON Web Key.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Normaliza el material de clave que manda el backend a los 16 bytes que
/// pide CENC/ClearKey. Acepta:
/// - hex de 32 caracteres, con o sin guiones de UUID, `0x`, espacios;
/// - base64 estándar o base64url, con o sin relleno `=`.
/// Devuelve `nil` si no se puede interpretar o no son 16 bytes.
enum DRMKeyFormat {
    static func data(from input: String) -> Data? {
        var clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if clean.hasPrefix("0x") || clean.hasPrefix("0X") {
            clean = String(clean.dropFirst(2))
        }
        // UUID "xxxxxxxx-xxxx-…" → hex continuo.
        let noDashes = clean.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if noDashes.count == 32, let hex = Data(hexString: noDashes) {
            return hex
        }
        // Base64 / base64url (con o sin padding).
        var b64 = noDashes
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        if let decoded = Data(base64Encoded: b64), decoded.count == 16 {
            return decoded
        }
        return nil
    }

    /// Hex canónico en minúsculas (32 chars) para guardar en el modelo, o
    /// `nil` si el valor no es interpretable.
    static func canonicalHex(from input: String) -> String? {
        guard let data = data(from: input), data.count == 16 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
