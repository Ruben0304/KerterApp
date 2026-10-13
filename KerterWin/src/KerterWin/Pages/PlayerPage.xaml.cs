using KerterCore.Models;
using KerterCore.Playback;
using KerterCore.Proxy;
using KerterCore.Strikeout;
using KerterWin.Services;
using LibVLCSharp.Platforms.Windows;
using LibVLCSharp.Shared;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace KerterWin.Pages;

public sealed partial class PlayerPage : Page
{
    // LibVLC se crea una sola vez (ligado al VideoView, que se conserva con NavigationCacheMode).
    private static LibVLC? _libVlc;
    private static MediaPlayer? _player;
    private static PlayerPage? _current;
    private readonly TaskCompletionSource _ready = new();

    private PlayRequest? _request;
    private Channel? _channel;
    private CancellationTokenSource? _playCts;
    private int _generation;
    private int _retries;
    private LiveProxy? _live;
    private HeaderProxy? _headerProxy;
    private long _timeBase = -1;
    private bool _userPaused;
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(500) };

    public PlayerPage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Required;
        _current = this;
        VolumeSlider.Value = AppServices.Settings.Volume;
        _hideTimer.Tick += (_, _) => HideControls();
        _tick.Tick += (_, _) => OnTick();

        AddShortcut(VirtualKey.Space, () => OnPlayPause(this, null!));
        AddShortcut(VirtualKey.F, () => OnFullscreen(this, null!));
        AddShortcut(VirtualKey.M, () => OnMute(this, null!));
        AddShortcut(VirtualKey.Escape, () =>
        {
            if (App.Window.IsFullscreen) OnFullscreen(this, null!);
            else OnBack(this, null!);
        });
    }

    private void AddShortcut(VirtualKey key, Action action)
    {
        var accel = new KeyboardAccelerator { Key = key };
        accel.Invoked += (_, e) => { action(); e.Handled = true; };
        Root.KeyboardAccelerators.Add(accel);
    }

    // MARK: Ciclo de vida

    private void OnVideoInitialized(object sender, InitializedEventArgs e)
    {
        Core.Initialize();
        _libVlc = new LibVLC(enableDebugLogs: false, e.SwapChainOptions);
        _player = new MediaPlayer(_libVlc);
        _player.Playing += (_, _) => RunUI(() => { Spinner.IsActive = false; PlayPauseIcon.Glyph = ""; _retries = 0; });
        _player.Paused += (_, _) => RunUI(() => PlayPauseIcon.Glyph = "");
        _player.Buffering += (_, a) => RunUI(() => Spinner.IsActive = a.Cache < 100f);
        _player.EncounteredError += (_, _) => RunUI(OnPlaybackError);
        _player.EndReached += (_, _) => RunUI(OnPlaybackError);
        Video.MediaPlayer = _player;
        _player.Volume = (int)AppServices.Settings.Volume;
        _ready.TrySetResult();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not PlayRequest request) return;
        _request = request;
        TitleText.Text = request.Title;
        BuildChannelList();
        ShowControls();
        await _ready.Task;
        await StartAsync(request.Channel);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _ = StopAsync();
        _hideTimer.Stop();
        _tick.Stop();
        if (App.Window.IsFullscreen) App.Window.SetFullscreen(false);
    }

    /// Al cerrar la ventana: libera VLC y los proxies.
    public static void Shutdown()
    {
        _current?._playCts?.Cancel();
        _current?._live?.Stop();
        _current?._headerProxy?.Dispose();
        _player?.Stop();
        _player?.Dispose();
        _libVlc?.Dispose();
    }

    // MARK: Reproducción

    private void BuildChannelList()
    {
        ChannelsList.Children.Clear();
        foreach (var option in _request?.Options ?? [])
        {
            var button = new Button { Content = option.Label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += async (_, _) =>
            {
                ChannelsFlyout.Hide();
                await StartAsync(option.Channel);
            };
            ChannelsList.Children.Add(button);
        }
        ChannelsButton.Visibility = ChannelsList.Children.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task StartAsync(Channel channel)
    {
        await StopAsync();
        var generation = ++_generation;
        var cts = _playCts = new CancellationTokenSource();
        var ct = cts.Token;
        _channel = channel;
        _timeBase = -1;
        _userPaused = false;
        ChannelText.Text = channel.Name;
        MessagePanel.Visibility = Visibility.Collapsed;
        SourceDownBanner.Visibility = Visibility.Collapsed;
        StatusText.Text = "";
        QualityButton.Visibility = Visibility.Collapsed;
        Spinner.IsActive = true;

        try
        {
            var url = channel.StreamUrl ?? throw new InvalidOperationException("El canal no tiene dirección de reproducción.");
            var options = new List<string> { ":network-caching=3000" };

            if (channel.IsStrikeout)
            {
                // El CDN exige Referer/Origin del embed; la sesión se renueva cada 5 minutos.
                var native = await NativeStream.ResolveAsync(url, ct);
                if (ct.IsCancellationRequested) return;
                _headerProxy = new HeaderProxy(native.Headers);
                url = _headerProxy.Wrap(native.MasterUrl);
                _ = RefreshLoop(native, ct);
            }
            else if (channel.IsDash || channel.HasDrm)
            {
                // Cifrado ClearKey: se le pasa la clave al motor (mejor esfuerzo, según la build de VLC).
                if (channel.HasDrm)
                {
                    var okKid = KerterCore.Util.DrmKeys.Bytes(channel.DrmKeyId) is { Length: 16 };
                    var okKey = KerterCore.Util.DrmKeys.Bytes(channel.DrmKey) is { Length: 16 };
                    if (!okKid || !okKey)
                        throw new InvalidOperationException("Este canal viene cifrado pero el servidor no mandó una clave válida.");
                    options.Add($":cenc-decryption-key={channel.DrmKey}");
                    options.Add($":decryption-key={channel.DrmKey}");
                }
            }
            else if (AppServices.Settings.ConnectionBooster)
            {
                // HLS en abierto: se graba en local con varias conexiones y VLC lee de ahí.
                var started = await LiveProxy.StartAsync(url, null, s => RunUI(() => OnProxyStatus(s)), ct);
                if (ct.IsCancellationRequested) { started?.Stop(); return; }
                if (started?.LocalUrl is { } local)
                {
                    _live = started;
                    url = local;
                    BuildQualityMenu(started);
                }
                else started?.Stop();
            }

            if (generation != _generation) return;
            using var media = new Media(_libVlc!, url);
            foreach (var o in options) media.AddOption(o);
            _player!.Play(media);
            _tick.Start();
        }
        catch (OperationCanceledException) { }
        catch (NativeException ex)
        {
            ShowMessage(ex.Reason switch
            {
                NativeError.NotStarted => $"El partido empieza a las {ex.StartsAt?.ToLocalTime():HH:mm}. Vuelve a intentarlo entonces.",
                NativeError.Offline => "Este stream está apagado. Prueba con otro de la lista de canales.",
                _ => $"No se pudo abrir el stream de Strikeout: {ex.Message}",
            });
        }
        catch (Exception ex)
        {
            ShowMessage(ex.Message);
        }
    }

    private async Task RefreshLoop(NativeStream native, CancellationToken ct)
    {
        // Sin renovar la sesión, el servidor deja de dar la clave AES a los pocos minutos.
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(270), ct);
                await native.RefreshAsync(ct);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception) { }
        }
    }

    private async Task StopAsync()
    {
        _playCts?.Cancel();
        _tick.Stop();
        _generation++;
        var live = _live;
        var header = _headerProxy;
        _live = null;
        _headerProxy = null;
        if (_player is { } p) await Task.Run(() => p.Stop());
        live?.Stop();
        header?.Dispose();
        Spinner.IsActive = false;
    }

    private async void OnPlaybackError()
    {
        if (_channel is null || _playCts is null || _playCts.IsCancellationRequested) return;
        // Un directo que se corta: se reconecta unas cuantas veces antes de rendirse.
        if (_retries++ < 3)
        {
            Spinner.IsActive = true;
            await Task.Delay(2000);
            if (_channel != null) await StartAsync(_channel);
        }
        else ShowMessage("Se perdió la conexión con el canal.");
    }

    private void ShowMessage(string text)
    {
        Spinner.IsActive = false;
        MessageText.Text = text;
        MessagePanel.Visibility = Visibility.Visible;
        ShowControls();
    }

    private async void OnRetry(object sender, RoutedEventArgs e)
    {
        _retries = 0;
        if (_channel != null) await StartAsync(_channel);
    }

    // MARK: Estado del proxy

    private void OnProxyStatus(LiveProxy.Status s)
    {
        SourceDownBanner.Visibility = s.SourceDown ? Visibility.Visible : Visibility.Collapsed;
        var parts = new List<string>();
        if (s.Height > 0) parts.Add($"{s.Height}p");
        parts.Add($"Margen {s.BufferAhead:0} s");
        if (s.Throughput is { } bps) parts.Add($"{bps / 1_000_000:0.0} Mb/s");
        if (s.LostSegments > 0) parts.Add($"{s.LostSegments} perdidos");
        StatusText.Text = string.Join(" · ", parts);
    }

    private void BuildQualityMenu(LiveProxy proxy)
    {
        QualityMenu.Items.Clear();
        var auto = new ToggleMenuFlyoutItem { Text = "Automática", IsChecked = true };
        var items = new List<ToggleMenuFlyoutItem> { auto };
        auto.Click += (_, _) => Select(auto, null);
        QualityMenu.Items.Add(auto);
        for (var i = 0; i < proxy.Variants.Count; i++)
        {
            var level = i;
            var v = proxy.Variants[i];
            if (v.Height <= 0) continue;
            var item = new ToggleMenuFlyoutItem { Text = $"{v.Height}p" };
            item.Click += (_, _) => Select(item, level);
            items.Add(item);
            QualityMenu.Items.Add(item);
        }
        QualityButton.Visibility = items.Count > 2 ? Visibility.Visible : Visibility.Collapsed;

        void Select(ToggleMenuFlyoutItem chosen, int? level)
        {
            foreach (var it in items) it.IsChecked = it == chosen;
            proxy.SetManualLevel(level);
        }
    }

    /// Le dice al grabador por dónde va la reproducción (margen, qué conservar).
    private void OnTick()
    {
        if (_live == null || _player == null || !_player.IsPlaying) return;
        var time = _player.Time;
        if (time <= 0) return;
        if (_timeBase < 0) _timeBase = time;
        _live.ReportPlayhead(_live.TimelineOrigin + TimeSpan.FromMilliseconds(time - _timeBase));
    }

    // MARK: Controles

    private void OnPlayPause(object sender, RoutedEventArgs e)
    {
        if (_player == null) return;
        // En directo, pausar deja que el grabador junte colchón.
        _userPaused = _player.IsPlaying;
        _player.SetPause(_player.IsPlaying);
        ShowControls();
    }

    private void OnMute(object sender, RoutedEventArgs e)
    {
        if (_player == null) return;
        _player.Mute = !_player.Mute;
        MuteIcon.Glyph = _player.Mute ? "" : "";
    }

    private void OnVolumeChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_player != null) _player.Volume = (int)e.NewValue;
        AppServices.Settings.Volume = e.NewValue;
    }

    private void OnFullscreen(object sender, RoutedEventArgs e)
    {
        var on = !App.Window.IsFullscreen;
        App.Window.SetFullscreen(on);
        FullscreenIcon.Glyph = on ? "" : "";
        AppServices.Settings.Save();
    }

    private void OnBack(object sender, RoutedEventArgs e) => App.Window.GoBack();

    private void OnRootTapped(object sender, TappedRoutedEventArgs e) { }

    private void OnRootDoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => OnFullscreen(sender, e);

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e) => ShowControls();

    private void ShowControls()
    {
        Controls.Visibility = Visibility.Visible;
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void HideControls()
    {
        _hideTimer.Stop();
        // No se ocultan con un menú abierto, en pausa ni con un mensaje de error.
        if (_userPaused || MessagePanel.Visibility == Visibility.Visible || ChannelsFlyout.IsOpen) return;
        Controls.Visibility = Visibility.Collapsed;
    }

    private void RunUI(Action action) => DispatcherQueue.TryEnqueue(() => action());
}
