using KerterCore.Api;

namespace KerterWin.Services;

/// Servicios compartidos de la app (sin contenedor de DI: es una app pequeña).
public static class AppServices
{
    public static readonly KerterApi Api = new();
    public static readonly AuthService Auth = new(Api, new DpapiSecretStore());
    public static readonly EventsService Events = new(Api, Auth);
    public static readonly AppSettings Settings = AppSettings.Load();
}
