import Foundation

/// Datos de ejemplo para ver y navegar la app sin cuenta.
/// Los eventos "en vivo" usan un stream HLS público de Apple, así que el
/// reproductor funciona de verdad (con su selector de calidad y pantalla completa).
enum DemoData {
    private static let live = AppConfig.demoStreamURL

    static let channels: [Channel] = [
        // Destacados / hero
        Channel(id: "e1", name: "ESPN F90 Argentina", subtitle: "ESPN F90",
                category: "Fútbol", descriptionText: "El programa de debate y análisis del fútbol.",
                startText: "Comenzó hace 27 min", progress: 0.30,
                isLive: true, isFeatured: true, streamURL: live),
        Channel(id: "e2", name: "Al Ain (UAE) vs. Al Nassr (KSA)", subtitle: "AFC Champions League Elite",
                category: "Fútbol", descriptionText: "Fase de grupos.",
                startText: "Comenzó hace 37 min", progress: 0.42,
                isLive: true, isFeatured: true, streamURL: live),
        Channel(id: "e3", name: "LDU Quito (ECU) vs. Palmeiras (BRA)", subtitle: "CONMEBOL Libertadores",
                category: "Fútbol", descriptionText: "4tos de final, vuelta.",
                startText: "16 sep · 6:45 p. m.", progress: nil,
                isLive: false, isFeatured: true),

        // Fútbol
        Channel(id: "f1", name: "Platense (ARG) vs. Fluminense (BRA)", subtitle: "CONMEBOL Libertadores",
                category: "Fútbol", startText: "6:45 p. m. – 9:00 p. m.", isLive: false),
        Channel(id: "f2", name: "Corinthians (BRA) vs. Estudiantes (ARG)", subtitle: "CONMEBOL Libertadores",
                category: "Fútbol", startText: "9:00 p. m. – 11:30 p. m.", isLive: false),
        Channel(id: "f3", name: "LaLiga en Vivo", subtitle: "LaLiga EA Sports",
                category: "Fútbol", startText: "Comenzó hace 12 min", isLive: true, streamURL: live),
        Channel(id: "f4", name: "Serie A", subtitle: "Calcio italiano",
                category: "Fútbol", startText: "Próximamente", isLive: false),

        // Tenis
        Channel(id: "t1", name: "SP Open / Quadra Central", subtitle: "WTA",
                category: "Tenis", startText: "Comenzó hace 2 h 58 min", isLive: true, streamURL: live),
        Channel(id: "t2", name: "SP Open / Quadra 1", subtitle: "WTA",
                category: "Tenis", startText: "Comenzó hace 2 h 57 min", isLive: true, streamURL: live),

        // Baloncesto
        Channel(id: "b1", name: "NBA League Pass", subtitle: "NBA",
                category: "Baloncesto", startText: "Comenzó hace 40 min", isLive: true, streamURL: live),
        Channel(id: "b2", name: "Playoffs — Juego 5", subtitle: "NBA",
                category: "Baloncesto", startText: "Próximamente", isLive: false),

        // Motor
        Channel(id: "m1", name: "Fórmula 1 — Práctica Libre", subtitle: "F1",
                category: "Deporte motor", startText: "Comenzó hace 8 min", isLive: true, streamURL: live),
        Channel(id: "m2", name: "MotoGP — Clasificación", subtitle: "MotoGP",
                category: "Motociclismo", startText: "Próximamente", isLive: false),

        // UFC / Boxeo
        Channel(id: "u1", name: "UFC Fight Night", subtitle: "UFC",
                category: "UFC", startText: "Próximamente", isLive: false),
        Channel(id: "x1", name: "Boxeo Estelar", subtitle: "Combate de campeonato",
                category: "Boxeo", startText: "Próximamente", isLive: false),

        // Otros
        Channel(id: "o1", name: "Patinaje Artístico", subtitle: "Juegos Suramericanos",
                category: "Otros", startText: "Comenzó hace 3 h 37 min", isLive: true, streamURL: live),
        Channel(id: "o2", name: "MLB Baseball", subtitle: "Grandes Ligas",
                category: "Béisbol", startText: "Próximamente", isLive: false),
        Channel(id: "o3", name: "SP Open / Quadra Central María", subtitle: "WTA",
                category: "Tenis", startText: "Comenzó hace 2 h 58 min", isLive: true, streamURL: live)
    ]
}
