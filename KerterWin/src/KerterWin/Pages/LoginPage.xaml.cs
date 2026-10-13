using KerterCore.Api;
using KerterWin.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace KerterWin.Pages;

public sealed partial class LoginPage : Page
{
    public LoginPage()
    {
        InitializeComponent();
        // Prellenamos con la última sesión guardada para no volver a teclear la contraseña.
        EmailBox.Text = AppServices.Auth.SavedEmail;
        PasswordBox.Password = AppServices.Auth.SavedPassword;
        if (AppServices.Auth.ErrorMessage is { } msg)
        {
            ErrorBar.Message = msg;
            ErrorBar.IsOpen = true;
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter) OnSignIn(sender, e);
    }

    private async void OnSignIn(object sender, RoutedEventArgs e)
    {
        ErrorBar.IsOpen = false;
        SignInButton.IsEnabled = false;
        Busy.Visibility = Visibility.Visible;
        await AppServices.Auth.LoginAsync(EmailBox.Text, PasswordBox.Password);
        Busy.Visibility = Visibility.Collapsed;
        SignInButton.IsEnabled = true;
        if (AppServices.Auth.State == AuthService.AuthState.SignedIn)
            App.Window.Navigate(typeof(EventsPage));
        else
        {
            ErrorBar.Message = AppServices.Auth.ErrorMessage ?? "No se pudo iniciar sesión.";
            ErrorBar.IsOpen = true;
        }
    }
}
