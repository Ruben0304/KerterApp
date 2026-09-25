import Foundation

/// Clave de codificación dinámica: nos deja probar varios nombres de campo
/// del JSON del backend sin conocer aún su forma exacta.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
    init(_ s: String) { self.stringValue = s; self.intValue = nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func firstString(_ keys: [String]) -> String? {
        for k in keys {
            if let v = try? decode(String.self, forKey: AnyKey(k)), !v.isEmpty { return v }
        }
        return nil
    }
    func firstBool(_ keys: [String]) -> Bool? {
        for k in keys {
            if let v = try? decode(Bool.self, forKey: AnyKey(k)) { return v }
        }
        return nil
    }
    func firstDouble(_ keys: [String]) -> Double? {
        for k in keys {
            if let v = try? decode(Double.self, forKey: AnyKey(k)) { return v }
        }
        return nil
    }
}

/// Objeto DRM anidado (`"drm": {"kid": …, "key": …}`): prueba las claves
/// indicadas dentro del sub-objeto y devuelve el primer valor no vacío.
func nestedDRM(_ c: KeyedDecodingContainer<AnyKey>, keys: [String]) -> String? {
    for parent in ["drm", "drmInfo", "clearKey", "clearkey", "license"] {
        guard let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(parent)) else { continue }
        if let v = nested.firstString(keys) { return v }
    }
    return nil
}

// MARK: - Usuario

struct User: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    var email: String?

    init(id: String, name: String?, email: String?) {
        self.id = id; self.name = name; self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if let s = c.firstString(["id", "_id", "userId", "uuid"]) {
            id = s
        } else if let i = try? c.decode(Int.self, forKey: AnyKey("id")) {
            id = String(i)
        } else {
            id = UUID().uuidString
        }
        name = c.firstString(["name", "fullName", "username", "displayName"])
        email = c.firstString(["email", "mail"])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(email, forKey: AnyKey("email"))
    }
}

// MARK: - Canal / Evento

struct Channel: Identifiable, Hashable, Decodable {
    let id: String
    var name: String
    var subtitle: String?          // liga / competición / programa
    var category: String?
    var logoURL: URL?
    var posterURL: URL?
    var heroImageURL: URL?         // imagen ancha para el carrusel destacado
    var descriptionText: String?
    var startText: String?         // "Comenzó hace 27 min" / "Próximamente"
    var progress: Double?          // 0...1 para la barra del hero
    var isLive: Bool
    var isFeatured: Bool
    var streamURL: URL?
    var homeLogoURL: URL?          // escudo local (partidos team-vs-team)
    var awayLogoURL: URL?          // escudo visitante
    var homePlayerURL: URL?        // recorte HD de un jugador local (hero)
    var awayPlayerURL: URL?        // recorte HD de un jugador visitante
    var homeColor: String?         // color representativo del local (hex "cd0000")
    var awayColor: String?         // color representativo del visitante
    var homeAbbr: String?          // "NYC"
    var awayAbbr: String?          // "RBNY"
    var homeScore: String?
    var awayScore: String?
    var statusPill: String?        // "Final", "45'", "Vie 7:30 p. m."
    var dateLabel: String?         // "13 sep"
    var venue: String?             // "Estadio Coliseum · Getafe"
    var isFinal: Bool = false
    var playerType: String?        // "hls" | "dash"
    var drmKeyId: String?          // ClearKey KID (hex) — canales cifrados
    var drmKey: String?            // ClearKey key (hex)

    var sourceChannelName: String?  // canal que lo transmite ("ESPN 2")
    var sourceChannelLogo: URL?

    /// El canal está cifrado con ClearKey.
    var hasDRM: Bool { !(drmKey ?? "").isEmpty }
    /// Se puede previsualizar en el hero (AVPlayer solo entiende HLS sin DRM).
    var canPreview: Bool { streamURL != nil && !isDASH && !hasDRM }
    /// El stream es DASH (no reproducible con AVPlayer nativo).
    var isDASH: Bool { (playerType ?? "").lowercased() == "dash" }

    init(id: String, name: String, subtitle: String? = nil, category: String? = nil,
         logoURL: URL? = nil, posterURL: URL? = nil, heroImageURL: URL? = nil,
         descriptionText: String? = nil, startText: String? = nil, progress: Double? = nil,
         isLive: Bool = false, isFeatured: Bool = false, streamURL: URL? = nil,
         homeLogoURL: URL? = nil, awayLogoURL: URL? = nil,
         homePlayerURL: URL? = nil, awayPlayerURL: URL? = nil,
         homeColor: String? = nil, awayColor: String? = nil,
         homeAbbr: String? = nil, awayAbbr: String? = nil,
         homeScore: String? = nil, awayScore: String? = nil,
         statusPill: String? = nil, dateLabel: String? = nil, isFinal: Bool = false,
         sourceChannelName: String? = nil, sourceChannelLogo: URL? = nil,
         playerType: String? = nil, drmKeyId: String? = nil, drmKey: String? = nil) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.category = category
        self.logoURL = logoURL; self.posterURL = posterURL; self.heroImageURL = heroImageURL
        self.descriptionText = descriptionText; self.startText = startText; self.progress = progress
        self.isLive = isLive; self.isFeatured = isFeatured; self.streamURL = streamURL
        self.homeLogoURL = homeLogoURL; self.awayLogoURL = awayLogoURL
        self.homePlayerURL = homePlayerURL; self.awayPlayerURL = awayPlayerURL
        self.homeColor = homeColor; self.awayColor = awayColor
        self.homeAbbr = homeAbbr; self.awayAbbr = awayAbbr
        self.homeScore = homeScore; self.awayScore = awayScore
        self.statusPill = statusPill; self.dateLabel = dateLabel; self.isFinal = isFinal
        self.sourceChannelName = sourceChannelName; self.sourceChannelLogo = sourceChannelLogo
        self.playerType = playerType; self.drmKeyId = drmKeyId; self.drmKey = drmKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        func url(_ keys: [String]) -> URL? {
            guard let s = c.firstString(keys) else { return nil }
            if s.hasPrefix("http") { return URL(string: s) }
            let base = AppConfig.mediaBaseURL.absoluteString
            return URL(string: base + (s.hasPrefix("/") ? s : "/" + s))
        }

        if let s = c.firstString(["id", "_id", "channelId", "uuid", "slug"]) {
            id = s
        } else if let i = try? c.decode(Int.self, forKey: AnyKey("id")) {
            id = String(i)
        } else {
            id = UUID().uuidString
        }
        name = c.firstString(["name", "title", "channelName", "label"]) ?? "Canal"
        subtitle = c.firstString(["subtitle", "league", "competition", "tournament", "categoryLabel", "show"])
        // Categoría: usa `category` o, en el backend real de Kerter, el primer `tag`.
        if let cat = c.firstString(["category", "categoryName", "group", "genre", "type"]) {
            category = cat
        } else if let tags = c.firstString(["tags"]) {
            category = tags.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            category = nil
        }
        logoURL = url(["logo", "logoUrl", "icon", "iconUrl", "image", "thumbnail", "thumb"])
        posterURL = url(["poster", "posterUrl", "cover", "coverUrl", "image", "thumbnail"])
        heroImageURL = url(["hero", "heroImage", "heroUrl", "background", "backdrop", "wide", "landscape", "banner"])
        descriptionText = c.firstString(["description", "desc", "summary", "subtitle2"])
        startText = c.firstString(["startText", "scheduleText", "when", "airTime", "scheduleLabel"])
        progress = c.firstDouble(["progress", "percent"])
        streamURL = url(["stream_url", "streamUrl", "sourceUrl", "url", "hls", "hlsUrl",
                         "manifest", "manifestUrl", "playbackUrl", "src", "link"])
        homeLogoURL = url(["homeLogo", "homeLogoUrl", "localLogo"])
        awayLogoURL = url(["awayLogo", "awayLogoUrl", "visitorLogo"])
        homeColor = c.firstString(["homeColor", "localColor"])
        awayColor = c.firstString(["awayColor", "visitorColor"])
        homeAbbr = c.firstString(["homeAbbr", "homeAbbreviation"])
        awayAbbr = c.firstString(["awayAbbr", "awayAbbreviation"])
        homeScore = c.firstString(["homeScore", "localScore"])
        awayScore = c.firstString(["awayScore", "visitorScore"])
        statusPill = c.firstString(["statusPill", "statusText"])
        dateLabel = c.firstString(["dateLabel", "matchDate"])
        isFinal = c.firstBool(["isFinal", "finished", "completed"]) ?? false
        playerType = c.firstString(["player_type", "playerType"])
        // Claves ClearKey: el backend las manda como `drm_key1_id`/`drm_key1`,
        // pero se aceptan alias (kid/key en hex, base64 o UUID) y un objeto
        // anidado `drm: {kid, key}` por si cambia la forma del JSON.
        // Se guardan en hex canónico para que el reproductor no tenga que
        // adivinar el formato después.
        let rawKid = c.firstString(["drm_key1_id", "drmKey1Id", "drmKeyId", "drm_key_id",
                                    "drmKid", "kid", "KID", "clearkey_kid", "clearkeyKid",
                                    "keyId", "key_id"])
            ?? DRMKeyFormat.canonicalHex(from: nestedDRM(c, keys: ["kid", "KID", "keyId", "key_id"]) ?? "")
        let rawKey = c.firstString(["drm_key1", "drmKey1", "drmKey", "drm_key",
                                    "key", "KEY", "clearkey_key", "clearkeyKey", "contentKey"])
            ?? DRMKeyFormat.canonicalHex(from: nestedDRM(c, keys: ["key", "KEY", "contentKey"]) ?? "")
        drmKeyId = rawKid.flatMap { DRMKeyFormat.canonicalHex(from: $0) ?? $0 }
        drmKey = rawKey.flatMap { DRMKeyFormat.canonicalHex(from: $0) ?? $0 }
        isFeatured = c.firstBool(["featured", "isFeatured", "highlighted"]) ?? false

        if let b = c.firstBool(["isLive", "live", "online"]) {
            isLive = b
        } else if let status = c.firstString(["status", "state"]) {
            let l = status.lowercased()
            isLive = l.contains("live") || l.contains("vivo") || l == "online" || l == "on"
        } else {
            isLive = streamURL != nil
        }
    }

    /// Texto de horario a mostrar.
    var scheduleLabel: String {
        startText ?? (isLive ? "En vivo" : "Próximamente")
    }
}

// MARK: - Competición

/// Competición de fútbol con su logo oficial (PNG transparente de ESPN,
/// variante para fondo oscuro) y el slug de ESPN para traer sus partidos.
struct Competition: Identifiable, Hashable {
    let id: String        // slug ESPN, p. ej. "esp.1"
    let name: String
    let logoURL: URL?
    let brandHex: UInt    // color de marca para el fondo de la tarjeta

    init(_ id: String, _ name: String, logo: String, brand: UInt) {
        self.id = id; self.name = name; self.brandHex = brand
        self.logoURL = URL(string: logo)
    }

    private static func espnLogo(_ n: Int) -> String {
        "https://a.espncdn.com/i/leaguelogos/soccer/500-dark/\(n).png"
    }

    static let featured: [Competition] = [
        .init("uefa.champions", "Champions League", logo: espnLogo(2), brand: 0x0A2A8C),
        .init("uefa.nations", "Nations League", logo: espnLogo(2395), brand: 0x0F7A8A),
        .init("esp.1", "LaLiga", logo: espnLogo(15), brand: 0xFF4B44),
        .init("eng.1", "Premier League", logo: espnLogo(23), brand: 0x5B1F8F),
        .init("esp.copa_del_rey", "Copa del Rey", logo: espnLogo(80), brand: 0xA3172F),
        .init("uefa.europa", "Europa League", logo: espnLogo(2310), brand: 0xF26B00),
        .init("uefa.europa.conf", "Conference League", logo: espnLogo(20296), brand: 0x00A843),
        .init("ita.1", "Serie A", logo: espnLogo(12), brand: 0x008FD7),
        .init("ger.1", "Bundesliga", logo: espnLogo(10), brand: 0xD20515),
        .init("fra.1", "Ligue 1", logo: espnLogo(9), brand: 0x1E3A8A),
        .init("esp.super_cup", "Supercopa de España",
              logo: "https://a.espncdn.com/guid/f3ea21b4-d55a-317d-9e8e-6dfd6cd7963a/logos/default-dark.png",
              brand: 0xB5892E),
        .init("eng.fa", "FA Cup", logo: espnLogo(40), brand: 0x2B3F8C),
        .init("conmebol.libertadores", "Libertadores", logo: espnLogo(58), brand: 0xC49A2C),
        .init("fifa.cwc", "Mundial de Clubes", logo: espnLogo(1932), brand: 0x1F4FA8),
        .init("fifa.world", "Mundial", logo: espnLogo(4), brand: 0x326295),
        .init("mex.1", "Liga MX", logo: espnLogo(22), brand: 0x1E7A45),
        .init("usa.1", "MLS", logo: espnLogo(19), brand: 0x1D3C8F),
        .init("por.1", "Liga Portugal", logo: espnLogo(14), brand: 0x0B4EA2),
        .init("ned.1", "Eredivisie", logo: espnLogo(11), brand: 0xE8511E),
        .init("arg.1", "Liga Argentina", logo: espnLogo(1), brand: 0x4A90C8),
        .init("bra.1", "Brasileirão", logo: espnLogo(85), brand: 0x009C3B),
    ]
}

extension Competition {
    /// Competición base de las fichas de selecciones del riel "Equipos": no
    /// sale en "Competiciones", pero ESPN publica ahí a todas las selecciones.
    static let internationalFriendlies = Competition("fifa.friendly", "Amistosos internacionales",
                                                    logo: "https://a.espncdn.com/i/leaguelogos/soccer/500-dark/4.png",
                                                    brand: 0x326295)

    /// Competición que corresponde al nombre de liga que da el backend o ESPN
    /// ("LaLiga", "UEFA Champions League"…).
    static func matching(league: String?) -> Competition? {
        guard let slug = ESPNService.slug(forLeague: league) else { return nil }
        return featured.first { $0.id == slug }
    }

    /// Los logos guardados son la variante para fondo oscuro; en tema claro
    /// usamos la normal de ESPN para que no desaparezcan sobre blanco.
    func lightAwareLogo(dark: Bool) -> URL? {
        guard !dark, let url = logoURL else { return logoURL }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/500-dark/", with: "/500/"))
    }
}
