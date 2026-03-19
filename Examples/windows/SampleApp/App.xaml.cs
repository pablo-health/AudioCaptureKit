using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using SampleApp.ViewModels;

namespace SampleApp;

public partial class App : Application
{
    public static IServiceProvider Services { get; private set; } = null!;

    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var services = new ServiceCollection();
        services.AddSingleton(DispatcherQueue.GetForCurrentThread());
        services.AddSingleton<RecordingViewModel>();
        Services = services.BuildServiceProvider();

        _window = new MainWindow();
        _window.Activate();
    }
}
