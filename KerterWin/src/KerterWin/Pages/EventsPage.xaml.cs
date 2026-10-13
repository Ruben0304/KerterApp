using KerterCore.Api;
using KerterCore.Models;
using KerterCore.Strikeout;
using KerterWin.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace KerterWin.Pages;

public sealed partial class EventsPage : Page
{
    private const string AllSports = "Todos";
    private List<LiveEvent> _events = [];
    private string _sport = AllSports;
    private CancellationTokenSource? _cts;

    public EventsPage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Required;
        BoosterSwitch.IsOn = AppServices.Settings.ConnectionBooster;
        Loaded += async (_, _) => { if (_events.Count == 0) await LoadAsync(); };
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await LoadAsync();

    private async Task LoadAsync()
    {
        _cts?.Cancel();
        var cts = _cts = new CancellationTokenSource();
        ErrorBar.IsOpen = false;
        Busy.IsActive = true;
        RefreshButton.IsEnabled = false;
        try
        {
            _events = await AppServices.Events.LoadAsync(cts.Token);
            Render();
            // Strikeout tarda más: la cartelera ya está pintada y se completa después.
            _events = await AppServices.Events.AttachStrikeoutAsync(_events, cts.Token);
            Render();
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e)
        {
            if (AppServices.Auth.State == AuthService.AuthState.SignedOut)
            {
                App.Window.Navigate(typeof(LoginPage));
                return;
            }
            ErrorBar.Message = e.Message;
            ErrorBar.IsOpen = true;
        }
        finally
        {
            if (_cts == cts)
            {
                Busy.IsActive = false;
                RefreshButton.IsEnabled = true;
            }
        }
    }

    private void OnBoosterToggled(object sender, RoutedEventArgs e)
    {
        AppServices.Settings.ConnectionBooster = BoosterSwitch.IsOn;
        AppServices.Settings.Save();
    }

    private void OnSignOut(object sender, RoutedEventArgs e)
    {
        AppServices.Auth.SignOut();
        _events = [];
        App.Window.Navigate(typeof(LoginPage));
    }

    // MARK: Pintado

    private static bool IsLive(LiveEvent e) =>
        e.ScheduledStart is { } s && DateTime.Now >= s && DateTime.Now < s.AddHours(3);

    private static bool IsFinished(LiveEvent e) => e.ScheduledStart is { } s && DateTime.Now >= s.AddHours(3);

    private void Render()
    {
        SubtitleText.Text = $"{DateTime.Now:dddd d 'de' MMMM}";
        RenderChips();

        var visible = _events.Where(e => _sport == AllSports || e.Sport == _sport).ToList();
        Sections.Children.Clear();
        EmptyText.Visibility = visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        void Section(string title, IEnumerable<LiveEvent> list, bool live = false)
        {
            var items = list.ToList();
            if (items.Count == 0) return;
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (live) header.Children.Add(new Ellipse { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center, Fill = (Brush)Application.Current.Resources["LiveBrush"] });
            header.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
            Sections.Children.Add(header);
            Sections.Children.Add(new ItemsRepeater
            {
                Layout = new UniformGridLayout
                {
                    MinItemWidth = 340, MinItemHeight = 138, MinRowSpacing = 12, MinColumnSpacing = 12,
                    ItemsStretch = UniformGridLayoutItemsStretch.Fill,
                },
                ItemsSource = items.Select(Card).ToList(),
            });
        }

        Section("En vivo ahora", visible.Where(IsLive).OrderBy(e => e.ScheduledStart), live: true);
        Section("Próximos", visible.Where(e => !IsLive(e) && !IsFinished(e)).OrderBy(e => e.ScheduledStart ?? DateTime.MaxValue));
        Section("Finalizados", visible.Where(IsFinished).OrderByDescending(e => e.ScheduledStart));
    }

    private void RenderChips()
    {
        var sports = _events.Select(e => e.Sport).Where(s => s != null).Cast<string>().Distinct()
            .OrderBy(s => Array.IndexOf(SportsFilter.AllSports, s)).Prepend(AllSports).ToList();
        if (!sports.Contains(_sport)) _sport = AllSports;
        SportChips.Children.Clear();
        foreach (var sport in sports)
        {
            var chip = new ToggleButton { Content = sport, IsChecked = sport == _sport, CornerRadius = new CornerRadius(16), Padding = new Thickness(14, 5, 14, 6) };
            chip.Click += (_, _) => { _sport = sport; Render(); };
            SportChips.Children.Add(chip);
        }
    }

    private UIElement Card(LiveEvent ev)
    {
        var live = IsLive(ev);
        var grid = new Grid { RowSpacing = 8 };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Fila superior: liga y hora / EN VIVO.
        var top = new Grid();
        top.Children.Add(new TextBlock
        {
            Text = ev.League ?? ev.Sport ?? "", Foreground = (Brush)Application.Current.Resources["MutedBrush"],
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 0, 70, 0),
        });
        var time = new TextBlock
        {
            Text = live ? "EN VIVO" : ev.ScheduledStart?.ToString("HH:mm") ?? ev.Time ?? "",
            FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Right,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };
        if (live) time.Foreground = (Brush)Application.Current.Resources["LiveBrush"];
        top.Children.Add(time);
        grid.Children.Add(top);

        // Centro: escudos y nombres.
        var teams = new Grid { ColumnSpacing = 10 };
        teams.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        teams.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        teams.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        if (ev.Home.Length > 0)
        {
            names.Children.Add(TeamName(ev.Home));
            names.Children.Add(new TextBlock { Text = "vs", Foreground = (Brush)Application.Current.Resources["MutedBrush"], HorizontalAlignment = HorizontalAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
            names.Children.Add(TeamName(ev.Away));
        }
        else names.Children.Add(TeamName(ev.Away));
        Grid.SetColumn(names, 1);
        teams.Children.Add(Crest(ev.HomeLogo));
        teams.Children.Add(names);
        var away = Crest(ev.AwayLogo);
        Grid.SetColumn(away, 2);
        teams.Children.Add(away);
        Grid.SetRow(teams, 1);
        grid.Children.Add(teams);

        // Pie: cuántas formas de verlo.
        var kerter = ev.Channels.Count(c => !StrikeoutChannels.IsStrikeout(c));
        var strike = ev.Channels.Any(StrikeoutChannels.IsStrikeout);
        var footer = new TextBlock
        {
            Text = $"{kerter} canal{(kerter == 1 ? "" : "es")}{(strike ? " · Strikeout" : "")}",
            Foreground = (Brush)Application.Current.Resources["MutedBrush"],
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);

        var normal = (Brush)Application.Current.Resources["CardBrush"];
        var hover = (Brush)Application.Current.Resources["CardHoverBrush"];
        var card = new Border
        {
            Background = normal, CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 12, 16, 12), Child = grid,
            BorderBrush = live ? (Brush)Application.Current.Resources["LiveBrush"] : new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(live ? 1 : 0),
        };
        card.PointerEntered += (_, _) => card.Background = hover;
        card.PointerExited += (_, _) => card.Background = normal;
        card.Tapped += async (_, _) => await PickChannelAsync(ev);
        return card;
    }

    private static TextBlock TeamName(string name) => new()
    {
        Text = name, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis,
    };

    private static UIElement Crest(Uri? url)
    {
        var img = new Image { Width = 48, Height = 48, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center };
        if (url != null) img.Source = new BitmapImage(url) { DecodePixelWidth = 96 };
        return img;
    }

    // MARK: Elegir canal

    /// "Dónde ver": canales de Kerter (Kerter+ y mejor calidad primero) y los streams de Strikeout.
    private async Task PickChannelAsync(LiveEvent ev)
    {
        var events = AppServices.Events;
        var options = new List<PlayOption>();
        foreach (var c in ev.Channels.Where(c => !StrikeoutChannels.IsStrikeout(c))
                     .OrderByDescending(c => c.IsKerterPlus).ThenByDescending(c => c.QualityRank))
            if (events.ChannelFor(c) is { StreamUrl: not null } ch) options.Add(new PlayOption(c.Name, ch));

        foreach (var sc in ev.Channels.Where(StrikeoutChannels.IsStrikeout))
        {
            var streams = events.Strikeout.StreamsFor(sc);
            foreach (var s in streams)
                options.Add(new PlayOption($"Strikeout · {s.Label}", events.Strikeout.ChannelFor(s, streams, sc.Name)));
        }

        var list = new StackPanel { Spacing = 6, MinWidth = 360 };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = ev.Title, CloseButtonText = "Cancelar",
            Content = new ScrollViewer { MaxHeight = 420, Content = list },
        };
        if (options.Count == 0)
            list.Children.Add(new TextBlock { Text = "Este partido no tiene canales reproducibles todavía.", TextWrapping = TextWrapping.Wrap });
        PlayOption? picked = null;
        foreach (var option in options)
        {
            var button = new Button { Content = option.Label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(14, 10, 14, 10) };
            button.Click += (_, _) => { picked = option; dialog.Hide(); };
            list.Children.Add(button);
        }
        await dialog.ShowAsync();
        if (picked != null)
            App.Window.Navigate(typeof(PlayerPage), new PlayRequest(picked.Channel, ev.Title, options));
    }
}
