import CryptoKit
import Foundation

/// Cifrado del emparejamiento por red local con DeporTV (Fire TV/Android
/// TV): la clave AES-GCM sale del código de 6 dígitos que se ve en la
/// pantalla de la TV, así que la propia TV valida el código al comprobar la
/// etiqueta GCM al descifrar — no hace falta mandarlo aparte. Ver
/// `PairingCrypto.kt` en DeporTV (mismo esquema, ambos lados).
enum PairingCrypto {
    private static let salt = "deportv-pair"

    private static func deriveKey(code: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data((code + salt).utf8))
        return SymmetricKey(data: digest)
    }

    /// IV(12) + ciphertext + tag(16) — el formato que espera el servidor local de la TV.
    static func encrypt(_ plainText: String, code: String) -> Data? {
        guard let sealed = try? AES.GCM.seal(Data(plainText.utf8), using: deriveKey(code: code)) else { return nil }
        return sealed.combined
    }
}
