import AVFoundation

/// Resuelve claves ClearKey para canales cifrados usando el soporte nativo de
/// `AVContentKeySession` (sin dependencias externas). El backend nos da la
/// KID y la key en hex; aquí se convierten al formato JSON Web Key que pide
/// AVFoundation para el key system `.clearKey`.
final class ClearKeyDelegate: NSObject, AVContentKeySessionDelegate {
    private let keyId: Data
    private let key: Data

    /// `nil` si el hex de la KID o la key vienen vacíos o mal formados.
    init?(keyIdHex: String, keyHex: String) {
        guard let keyId = Data(hexString: keyIdHex), let key = Data(hexString: keyHex) else { return nil }
        self.keyId = keyId
        self.key = key
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        respond(to: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession,
                            didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        respond(to: keyRequest)
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
