namespace KerterCore.Api;

/// Almacén de secretos (en Windows, cifrado con DPAPI).
public interface ISecretStore
{
    string? Get(string key);
    void Set(string key, string value);
    void Remove(string key);
}

/// Sesión del usuario: login, token guardado y reinicio de sesión automático.
public sealed class AuthService
{
    public enum AuthState { SignedOut, Authenticating, SignedIn }

    private const string TokenKey = "kerter.token", EmailKey = "kerter.savedEmail", PasswordKey = "kerter.savedPassword";
    private const string AutoLoginDisabledKey = "kerter.autoLoginDisabled";

    private readonly KerterApi _api;
    private readonly ISecretStore _store;
    private Task<bool>? _renewing;

    public AuthState State { get; private set; } = AuthState.SignedOut;
    public string? ErrorMessage { get; private set; }
    public string SavedEmail => _store.Get(EmailKey) ?? "";
    public string SavedPassword => _store.Get(PasswordKey) ?? "";
    public event Action? Changed;

    private bool CanAutoLogin => _store.Get(AutoLoginDisabledKey) != "1" && SavedEmail.Length > 0 && SavedPassword.Length > 0;

    public AuthService(KerterApi api, ISecretStore store)
    {
        _api = api;
        _store = store;
        if (_store.Get(TokenKey) is { Length: > 0 } token)
        {
            api.AuthToken = token;
            State = AuthState.SignedIn; // si caducó, se renueva solo (RenewSessionAsync)
        }
    }

    /// Hay credenciales guardadas y no se cerró sesión a mano: entrar sin pedir nada.
    public bool ShouldAutoLogin => State == AuthState.SignedOut && CanAutoLogin;

    public async Task LoginAsync(string email, string password)
    {
        email = email.Trim();
        if (email.Length == 0 || password.Length == 0)
        {
            Fail("Introduce tu correo y contraseña.");
            return;
        }
        ErrorMessage = null;
        State = AuthState.Authenticating;
        Changed?.Invoke();
        try
        {
            await AuthenticateAsync(email, password);
            State = AuthState.SignedIn;
        }
        catch (Exception e)
        {
            Fail(e.Message);
            return;
        }
        Changed?.Invoke();
    }

    /// El servidor dio la sesión por caducada (401): se vuelve a entrar con lo guardado.
    /// Devuelve si hay sesión nueva, para reintentar lo que falló.
    public Task<bool> RenewSessionAsync()
    {
        if (State != AuthState.SignedIn || !CanAutoLogin) { ExpireSession(); return Task.FromResult(false); }
        return _renewing ??= RenewCoreAsync();
    }

    private async Task<bool> RenewCoreAsync()
    {
        try
        {
            await AuthenticateAsync(SavedEmail, SavedPassword);
            return true;
        }
        catch (Exception e)
        {
            ErrorMessage = e.Message;
            ExpireSession();
            return false;
        }
        finally { _renewing = null; }
    }

    private async Task AuthenticateAsync(string email, string password)
    {
        var (token, _) = await _api.LoginAsync(email, password);
        if (string.IsNullOrEmpty(token)) throw new ApiException(null, "El servidor no devolvió un token de sesión.");
        _store.Set(TokenKey, token);
        _store.Set(EmailKey, email);
        _store.Set(PasswordKey, password);
        _store.Remove(AutoLoginDisabledKey);
        _api.AuthToken = token;
    }

    /// "Cerrar sesión" a mano: al volver a abrir no se entra solo.
    public void SignOut()
    {
        _store.Set(AutoLoginDisabledKey, "1");
        Clear();
    }

    /// Sesión caducada sin poder renovarla: al login, sin desactivar la entrada automática.
    public void ExpireSession() => Clear();

    private void Clear()
    {
        _store.Remove(TokenKey);
        _api.AuthToken = null;
        State = AuthState.SignedOut;
        Changed?.Invoke();
    }

    private void Fail(string message)
    {
        ErrorMessage = message;
        State = AuthState.SignedOut;
        Changed?.Invoke();
    }
}
