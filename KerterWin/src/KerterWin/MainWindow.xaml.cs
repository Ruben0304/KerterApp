using KerterCore.Api;
using KerterWin.Pages;
using KerterWin.Services;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace KerterWin;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "kerter.ico"));
        Closed += (_, _) => PlayerPage.Shutdown();
    }

    /// Entra solo si hay sesión (o credenciales guardadas); si no, al login.
    public async Task StartAsync()
    {
        var auth = AppServices.Auth;
        if (auth.ShouldAutoLogin)
        {
            await auth.LoginAsync(auth.SavedEmail, auth.SavedPassword);
        }
        Navigate(auth.State == AuthService.AuthState.SignedIn ? typeof(EventsPage) : typeof(LoginPage));
    }

    public void Navigate(Type page, object? parameter = null) =>
        RootFrame.Navigate(page, parameter, new DrillInNavigationTransitionInfo());

    public void GoBack()
    {
        if (RootFrame.CanGoBack) RootFrame.GoBack();
    }

    public bool IsFullscreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    /// Pantalla completa: sin barra de título.
    public void SetFullscreen(bool on)
    {
        AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Default);
        TitleBarArea.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
    }
}
