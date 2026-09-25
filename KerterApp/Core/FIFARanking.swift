import Foundation

/// Ranking mundial masculino de la FIFA, grabado en la app (no se consulta en
/// línea). Actualización del 20 de julio de 2026; la siguiente de la FIFA es el
/// 7 de octubre de 2026, y ese día basta con reemplazar `entries`.
///
/// Sirve para dos cosas: ordenar el hero cuando el partido es entre
/// selecciones (mejor ranking primero) y elegir las selecciones del riel
/// "Equipos" de Inicio (las 12 primeras + Cuba).
enum FIFARanking {
    struct Entry: Hashable, Sendable {
        let rank: Int
        /// Código FIFA de tres letras ("ESP"); coincide con la abreviatura de ESPN.
        let code: String
        /// Nombre en español, como lo escribe la cartelera de Kerter.
        let name: String
        let english: String
        let points: Int

        init(_ rank: Int, _ code: String, _ name: String, _ english: String, _ points: Int) {
            self.rank = rank; self.code = code; self.name = name
            self.english = english; self.points = points
        }
    }

    /// Fecha de la actualización que trae la app.
    static let snapshotDate = "2026-07-20"

    /// Cuántas selecciones del ranking salen en el riel "Equipos" de Inicio.
    static let featuredTopCount = 12
    /// Selecciones que salen siempre, además del top.
    static let alwaysFeaturedCodes = ["CUB"]

    /// Las 12 primeras del ranking y Cuba, en ese orden.
    static var featured: [Entry] {
        let top = Array(entries.prefix(featuredTopCount))
        let extra = alwaysFeaturedCodes.compactMap { code in
            entries.first { $0.code == code && !top.contains($0) }
        }
        return top + extra
    }

    // MARK: - Búsqueda por nombre

    /// Nombre normalizado → selección. Vale el nombre en español, en inglés, el
    /// código FIFA y las variantes que usa la cartelera ("Holanda", "Bosnia-Herzegovina").
    private static let index: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in entries {
            for variant in [entry.name, entry.english, entry.code] { map[key(normalized: variant)] = entry }
        }
        for (alias, code) in aliases {
            if let entry = entries.first(where: { $0.code == code }) { map[key(normalized: alias)] = entry }
        }
        return map
    }()

    /// Sin acentos, en minúsculas y con espacios simples: "Bosnia-Herzegovina" → "bosnia herzegovina".
    private static func key(normalized s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "es"))
        let cleaned = folded.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    static func entry(for teamName: String) -> Entry? {
        index[key(normalized: teamName)]
    }

    /// Puesto en el ranking, o `nil` si el nombre no es una selección.
    static func rank(of teamName: String) -> Int? { entry(for: teamName)?.rank }

    /// Código FIFA de la selección que nombra `teamName` en cualquier idioma.
    static func code(for teamName: String) -> String? { entry(for: teamName)?.code }

    // MARK: - Partidos de selecciones

    /// Palabras de competiciones entre selecciones en el nombre de liga de Kerter.
    private static let internationalLeagueWords = [
        "naciones", "nations", "mundial", "world cup", "eliminatoria", "clasificacion",
        "amistoso", "friendl", "eurocopa", "euro 20", "copa america", "copa oro", "gold cup",
        "copa africana", "copa de africa", "copa asia", "asian cup", "selecciones",
    ]

    /// `(mejor puesto, peor puesto)` de los dos equipos si el partido es entre
    /// selecciones; `nil` si es de clubes. Un equipo que no está en el ranking
    /// cuenta como último.
    static func matchRanks(home: String, away: String, league: String?) -> (best: Int, worst: Int)? {
        let leagueKey = key(normalized: league ?? "")
        let isClubWorldCup = leagueKey.contains("club")
        let byLeague = !isClubWorldCup && internationalLeagueWords.contains { leagueKey.contains($0) }
        let h = rank(of: home), a = rank(of: away)
        // Sin liga que lo delate, solo si los dos son selecciones y la liga no es de clubes conocida.
        let byTeams = h != nil && a != nil && ESPNService.slug(forLeague: league) == nil
        guard byLeague || byTeams else { return nil }
        let missing = entries.count + 1
        let ranks = [h ?? missing, a ?? missing]
        return (ranks.min()!, ranks.max()!)
    }

    // MARK: - Variantes de nombre

    /// Cómo llama la cartelera a algunas selecciones, que no coincide con el nombre FIFA.
    private static let aliases: [(String, String)] = [
        ("Holanda", "NED"), ("Estados Unidos", "USA"), ("EE UU", "USA"), ("USA", "USA"),
        ("Corea del Sur", "KOR"), ("Corea del Norte", "PRK"), ("China", "CHN"),
        ("Bosnia", "BIH"), ("Bosnia-Herzegovina", "BIH"), ("República Checa", "CZE"),
        ("Republica Checa", "CZE"), ("Czechia", "CZE"), ("Czech Republic", "CZE"),
        ("Irlanda", "IRL"), ("Eire", "IRL"), ("Turkiye", "TUR"), ("Turkey", "TUR"),
        ("Macedonia", "MKD"), ("North Macedonia", "MKD"), ("Costa de Marfil", "CIV"),
        ("Ivory Coast", "CIV"), ("Cote d Ivoire", "CIV"), ("Rep. Dem. del Congo", "COD"),
        ("DR Congo", "COD"), ("Congo DR", "COD"), ("Emiratos Árabes", "UAE"),
        ("Arabia Saudí", "KSA"), ("Arabia Saudita", "KSA"), ("Irán", "IRN"),
        ("Cabo Verde", "CPV"), ("Cape Verde", "CPV"), ("Granada", "GRN"),
        ("Palestina", "PLE"), ("Hong Kong", "HKG"), ("Guinea Bissau", "GNB"),
        ("Chinese Taipei", "TPE"), ("Taiwán", "TPE"), ("Suazilandia", "SWZ"),
        ("Islas Feroe", "FRO"), ("Faroe Islands", "FRO"), ("Curazao", "CUW"),
        ("Trinidad y Tobago", "TRI"), ("Gambia", "GAM"), ("Birmania", "MYA"),
    ]

    // MARK: - Datos (FIFA/Coca-Cola Men's World Ranking, 20-jul-2026)

    static let entries: [Entry] = [
        .init(1, "ESP", "España", "Spain", 1996),
        .init(2, "ARG", "Argentina", "Argentina", 1970),
        .init(3, "FRA", "Francia", "France", 1949),
        .init(4, "ENG", "Inglaterra", "England", 1923),
        .init(5, "BRA", "Brasil", "Brazil", 1805),
        .init(6, "MAR", "Marruecos", "Morocco", 1804),
        .init(7, "POR", "Portugal", "Portugal", 1788),
        .init(8, "BEL", "Bélgica", "Belgium", 1778),
        .init(9, "NED", "Países Bajos", "Netherlands", 1776),
        .init(10, "MEX", "México", "Mexico", 1754),
        .init(11, "COL", "Colombia", "Colombia", 1740),
        .init(12, "GER", "Alemania", "Germany", 1726),
        .init(13, "CRO", "Croacia", "Croatia", 1723),
        .init(14, "SUI", "Suiza", "Switzerland", 1711),
        .init(15, "ITA", "Italia", "Italy", 1705),
        .init(16, "USA", "Estados Unidos", "United States", 1690),
        .init(17, "JPN", "Japón", "Japan", 1674),
        .init(18, "SEN", "Senegal", "Senegal", 1653),
        .init(19, "NOR", "Noruega", "Norway", 1651),
        .init(20, "URU", "Uruguay", "Uruguay", 1635),
        .init(21, "DEN", "Dinamarca", "Denmark", 1619),
        .init(22, "IRN", "RI de Irán", "Iran", 1610),
        .init(23, "AUT", "Austria", "Austria", 1599),
        .init(24, "EGY", "Egipto", "Egypt", 1597),
        .init(25, "ECU", "Ecuador", "Ecuador", 1593),
        .init(26, "NGA", "Nigeria", "Nigeria", 1585),
        .init(27, "TUR", "Turquía", "Turkiye", 1583),
        .init(28, "AUS", "Australia", "Australia", 1582),
        .init(29, "ALG", "Argelia", "Algeria", 1577),
        .init(30, "CAN", "Canadá", "Canada", 1571),
        .init(31, "CIV", "Costa de Marfil", "Ivory Coast", 1565),
        .init(32, "KOR", "Corea del Sur", "South Korea", 1559),
        .init(33, "UKR", "Ucrania", "Ukraine", 1549),
        .init(34, "PAR", "Paraguay", "Paraguay", 1542),
        .init(35, "RUS", "Rusia", "Russia", 1530),
        .init(36, "POL", "Polonia", "Poland", 1526),
        .init(37, "SWE", "Suecia", "Sweden", 1526),
        .init(38, "WAL", "Gales", "Wales", 1517),
        .init(39, "HUN", "Hungría", "Hungary", 1506),
        .init(40, "SRB", "Serbia", "Serbia", 1502),
        .init(41, "COD", "RD del Congo", "Democratic Republic of the Congo", 1495),
        .init(42, "SCO", "Escocia", "Scotland", 1491),
        .init(43, "CMR", "Camerún", "Cameroon", 1481),
        .init(44, "PAN", "Panamá", "Panama", 1478),
        .init(45, "SVK", "Eslovaquia", "Slovakia", 1474),
        .init(46, "GRE", "Grecia", "Greece", 1473),
        .init(47, "VEN", "Venezuela", "Venezuela", 1469),
        .init(48, "CZE", "Chequia", "Czechia", 1467),
        .init(49, "CHI", "Chile", "Chile", 1458),
        .init(50, "PER", "Perú", "Peru", 1458),
        .init(51, "CRC", "Costa Rica", "Costa Rica", 1456),
        .init(52, "ROU", "Rumanía", "Romania", 1456),
        .init(53, "MLI", "Mali", "Mali", 1456),
        .init(54, "RSA", "Sudáfrica", "South Africa", 1451),
        .init(55, "IRL", "República de Irlanda", "Republic of Ireland", 1441),
        .init(56, "SVN", "Eslovenia", "Slovenia", 1441),
        .init(57, "TUN", "Túnez", "Tunisia", 1427),
        .init(58, "KSA", "Arabia Saudí", "Saudi Arabia", 1426),
        .init(59, "QAT", "Qatar", "Qatar", 1411),
        .init(60, "UZB", "Uzbekistán", "Uzbekistan", 1410),
        .init(61, "BIH", "Bosnia y Herzegovina", "Bosnia-Herzegovina", 1409),
        .init(62, "BFA", "Burkina Faso", "Burkina Faso", 1407),
        .init(63, "IRQ", "Irak", "Iraq", 1404),
        .init(64, "CPV", "Cabo Verde", "Cape Verde", 1403),
        .init(65, "GHA", "Ghana", "Ghana", 1387),
        .init(66, "HON", "Honduras", "Honduras", 1379),
        .init(67, "ALB", "Albania", "Albania", 1376),
        .init(68, "UAE", "Emiratos Árabes Unidos", "United Arab Emirates", 1370),
        .init(69, "MKD", "Macedonia del Norte", "North Macedonia", 1369),
        .init(70, "NIR", "Irlanda del Norte", "Northern Ireland", 1365),
        .init(71, "JAM", "Jamaica", "Jamaica", 1358),
        .init(72, "GEO", "Georgia", "Georgia", 1355),
        .init(73, "JOR", "Jordania", "Jordan", 1350),
        .init(74, "ISL", "Islandia", "Iceland", 1343),
        .init(75, "FIN", "Finlandia", "Finland", 1342),
        .init(76, "ISR", "Israel", "Israel", 1334),
        .init(77, "BOL", "Bolivia", "Bolivia", 1326),
        .init(78, "KOS", "Kosovo", "Kosovo", 1319),
        .init(79, "OMA", "Omán", "Oman", 1307),
        .init(80, "MNE", "Montenegro", "Montenegro", 1302),
        .init(81, "GUI", "Guinea", "Guinea", 1296),
        .init(82, "CUW", "Curazao", "Curaçao", 1286),
        .init(83, "SYR", "Siria", "Syria", 1283),
        .init(84, "GAB", "Gabón", "Gabon", 1273),
        .init(85, "BUL", "Bulgaria", "Bulgaria", 1272),
        .init(86, "NZL", "Nueva Zelanda", "New Zealand", 1270),
        .init(87, "ANG", "Angola", "Angola", 1266),
        .init(88, "HAI", "Haití", "Haiti", 1265),
        .init(89, "UGA", "Uganda", "Uganda", 1264),
        .init(90, "ZAM", "Zambia", "Zambia", 1256),
        .init(91, "CHN", "China", "China", 1255),
        .init(92, "BHR", "Baréin", "Bahrain", 1254),
        .init(93, "BEN", "Benín", "Benin", 1252),
        .init(94, "THA", "Tailandia", "Thailand", 1251),
        .init(95, "PLE", "Palestina", "Palestine", 1244),
        .init(96, "BLR", "Bielorrusia", "Belarus", 1243),
        .init(97, "GUA", "Guatemala", "Guatemala", 1239),
        .init(98, "LUX", "Luxemburgo", "Luxembourg", 1233),
        .init(99, "VIE", "Vietnam", "Vietnam", 1227),
        .init(100, "SLV", "El Salvador", "El Salvador", 1225),
        .init(101, "TJK", "Tayikistán", "Tajikistan", 1224),
        .init(102, "TRI", "Trinidad y Tobago", "Trinidad and Tobago", 1220),
        .init(103, "MOZ", "Mozambique", "Mozambique", 1219),
        .init(104, "MAD", "Madagascar", "Madagascar", 1203),
        .init(105, "EQG", "Guinea Ecuatorial", "Equatorial Guinea", 1195),
        .init(106, "KGZ", "República Kirguisa", "Kyrgyzstan", 1192),
        .init(107, "ARM", "Armenia", "Armenia", 1190),
        .init(108, "COM", "Comoras", "Comoros", 1188),
        .init(109, "KEN", "Kenia", "Kenya", 1185),
        .init(110, "LBY", "Libia", "Libya", 1182),
        .init(111, "KAZ", "Kazajstán", "Kazakhstan", 1181),
        .init(112, "TAN", "Tanzania", "Tanzania", 1180),
        .init(113, "MTN", "Mauritania", "Mauritania", 1177),
        .init(114, "NIG", "Níger", "Niger", 1175),
        .init(115, "LBN", "Líbano", "Lebanon", 1172),
        .init(116, "GAM", "Gambia", "The Gambia", 1160),
        .init(117, "SDN", "Sudán", "Sudan", 1157),
        .init(118, "IDN", "Indonesia", "Indonesia", 1157),
        .init(119, "TOG", "Togo", "Togo", 1153),
        .init(120, "PRK", "Corea del Norte", "North Korea", 1151),
        .init(121, "NAM", "Namibia", "Namibia", 1149),
        .init(122, "SLE", "Sierra Leona", "Sierra Leone", 1148),
        .init(123, "FRO", "Islas Feroe", "Faroe Islands", 1137),
        .init(124, "CYP", "Chipre", "Cyprus", 1133),
        .init(125, "SUR", "Surinam", "Suriname", 1132),
        .init(126, "AZE", "Azerbaiyán", "Azerbaijan", 1132),
        .init(127, "EST", "Estonia", "Estonia", 1131),
        .init(128, "RWA", "Ruanda", "Rwanda", 1127),
        .init(129, "MWI", "Malaui", "Malawi", 1122),
        .init(130, "ZIM", "Zimbabue", "Zimbabwe", 1120),
        .init(131, "NCA", "Nicaragua", "Nicaragua", 1115),
        .init(132, "GNB", "Guinea-Bissáu", "Guinea-Bissau", 1108),
        .init(133, "KUW", "Kuwait", "Kuwait", 1106),
        .init(134, "CGO", "Congo", "Republic of the Congo", 1106),
        .init(135, "PHI", "Filipinas", "Philippines", 1101),
        .init(136, "MAS", "Malasia", "Malaysia", 1086),
        .init(137, "LVA", "Letonia", "Latvia", 1086),
        .init(138, "IND", "India", "India", 1085),
        .init(139, "CTA", "República Centroafricana", "Central African Republic", 1081),
        .init(140, "LBR", "Liberia", "Liberia", 1080),
        .init(141, "TKM", "Turkmenistán", "Turkmenistan", 1079),
        .init(142, "BDI", "Burundi", "Burundi", 1078),
        .init(143, "ETH", "Etiopía", "Ethiopia", 1078),
        .init(144, "DOM", "República Dominicana", "Dominican Republic", 1076),
        .init(145, "YEM", "Yemen", "Yemen", 1065),
        .init(146, "LES", "Lesoto", "Lesotho", 1064),
        .init(147, "BOT", "Botsuana", "Botswana", 1064),
        .init(148, "SGP", "Singapur", "Singapore", 1058),
        .init(149, "LTU", "Lituania", "Lithuania", 1057),
        .init(150, "GUY", "Guyana", "Guyana", 1049),
        .init(151, "NCL", "Nueva Caledonia", "New Caledonia", 1037),
        .init(152, "SKN", "San Cristóbal y Nieves", "Saint Kitts and Nevis", 1036),
        .init(153, "SOL", "Islas Salomón", "Solomon Islands", 1032),
        .init(154, "PUR", "Puerto Rico", "Puerto Rico", 1024),
        .init(155, "FIJ", "Fiyi", "Fiji", 1024),
        .init(156, "HKG", "Hong Kong, China", "Hong Kong", 1024),
        .init(157, "TAH", "Tahití", "Tahiti", 1019),
        .init(158, "MYA", "Myanmar", "Myanmar", 1009),
        .init(159, "MDA", "Moldavia", "Moldova", 1008),
        .init(160, "VAN", "Vanuatu", "Vanuatu", 1003),
        .init(161, "MLT", "Malta", "Malta", 993),
        .init(162, "ATG", "Antigua y Barbuda", "Antigua and Barbuda", 987),
        .init(163, "GRN", "Granada", "Grenada", 982),
        .init(164, "CUB", "Cuba", "Cuba", 981),
        .init(165, "SWZ", "Esuatini", "Eswatini", 979),
        .init(166, "LCA", "Santa Lucía", "Saint Lucia", 977),
        .init(167, "BER", "Bermudas", "Bermuda", 975),
        .init(168, "PNG", "Papúa Nueva Guinea", "Papua New Guinea", 975),
        .init(169, "SSD", "Sudán del Sur", "South Sudan", 971),
        .init(170, "VIN", "San Vicente y las Granadinas", "Saint Vincent and the Grenadines", 968),
        .init(171, "AFG", "Afganistán", "Afghanistan", 968),
        .init(172, "AND", "Andorra", "Andorra", 946),
        .init(173, "MDV", "Maldivas", "Maldives", 944),
        .init(174, "TPE", "Chinese Taipei", "Chinese Taipei", 924),
        .init(175, "CAM", "Camboya", "Cambodia", 922),
        .init(176, "MSR", "Montserrat", "Montserrat", 917),
        .init(177, "NEP", "Nepal", "Nepal", 915),
        .init(178, "MRI", "Mauricio", "Mauritius", 911),
        .init(179, "BRB", "Barbados", "Barbados", 910),
        .init(180, "BLZ", "Belice", "Belize", 907),
        .init(181, "BAN", "Bangladesh", "Bangladesh", 903),
        .init(182, "DMA", "Dominica", "Dominica", 898),
        .init(183, "CHA", "Chad", "Chad", 897),
        .init(184, "ERI", "Eritrea", "Eritrea", 887),
        .init(185, "LAO", "Laos", "Laos", 885),
        .init(186, "COK", "Islas Cook", "Cook Islands", 878),
        .init(187, "SRI", "Sri Lanka", "Sri Lanka", 877),
        .init(188, "SAM", "Samoa", "Samoa", 876),
        .init(189, "ARU", "Aruba", "Aruba", 876),
        .init(190, "MNG", "Mongolia", "Mongolia", 874),
        .init(191, "ASA", "Samoa Estadounidense", "American Samoa", 872),
        .init(192, "BHU", "Bután", "Bhutan", 871),
        .init(193, "MAC", "Macao", "Macau", 858),
        .init(194, "BRU", "Brunéi Darussalam", "Brunei Darussalam", 858),
        .init(195, "STP", "Santo Tomé y Príncipe", "São Tomé and Príncipe", 855),
        .init(196, "DJI", "Yibuti", "Djibouti", 854),
        .init(197, "CAY", "Islas Caimán", "Cayman Islands", 850),
        .init(198, "PAK", "Pakistán", "Pakistan", 840),
        .init(199, "SOM", "Somalia", "Somalia", 839),
        .init(200, "TGA", "Tonga", "Tonga", 836),
        .init(201, "TLS", "Timor Oriental", "Timor-Leste", 831),
        .init(202, "GIB", "Gibraltar", "Gibraltar", 820),
        .init(203, "GUM", "Guam", "Guam", 820),
        .init(204, "SEY", "Seychelles", "Seychelles", 804),
        .init(205, "TCA", "Turcas y Caicos", "Turks and Caicos Islands", 804),
        .init(206, "LIE", "Liechtenstein", "Liechtenstein", 798),
        .init(207, "BAH", "Bahamas", "Bahamas", 787),
        .init(208, "VIR", "Islas Vírgenes Estadounidenses", "United States Virgin Islands", 780),
        .init(209, "VGB", "Islas Vírgenes Británicas", "British Virgin Islands", 777),
        .init(210, "AIA", "Anguila", "Anguilla", 760),
        .init(211, "SMR", "San Marino", "San Marino", 721),
    ]
}
