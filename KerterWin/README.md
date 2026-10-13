# KerterWin

Versión Windows (WinUI 3 + LibVLC) de KerterApp, solo canales y reproducción: los partidos del día que
trae Kerter+, más los streams de Strikeout, con el mismo proxy de grabación.

- `src/KerterCore` – lógica (API, login, cartelera, Strikeout, proxies). Multiplataforma; se prueba en Mac.
- `src/KerterCore.Tests` – tests (`dotnet test`).
- `src/KerterWin` – interfaz WinUI 3 (solo compila en Windows).

Compilar en Windows con .NET 8 SDK: `.\build.ps1` → `publish\KerterWin.exe`.

## Estado (primera versión, sin probar en Windows)

La lógica (`KerterCore`) está probada en macOS (25 tests). La interfaz WinUI (`KerterWin`) **nunca se ha compilado**:
su compilador de XAML solo existe en Windows, así que pueden salir errores en el primer build.

### Qué falta
- [ ] Primer build en Windows (`build.ps1` o el workflow de GitHub Actions) y corregir errores de compilación/XAML.
- [ ] Probar login, cartelera del día y emparejado con Strikeout con un partido real en vivo.
- [ ] Probar reproducción: HLS de Kerter con el proxy de grabación, Strikeout con el proxy de cabeceras.
- [ ] Margen/buffer: `ReportPlayhead` se calcula con el tiempo de LibVLC (`PlayerPage.OnTick`); verificar que coincide
      con la línea de tiempo del proxy. VLC no tiene el equivalente a `configuredTimeOffsetFromLive` de AVPlayer.
- [ ] DASH cifrado con ClearKey y HLS con DRM: solo mejor esfuerzo (opciones `:cenc-decryption-key`); sin verificar.
- [ ] Icono: es el de la app de Mac; falta el pulido final (tamaños múltiples en el .ico).
- [ ] Fuera de alcance a propósito: alineaciones, estadísticas, competiciones, ESPN, Chromecast.
