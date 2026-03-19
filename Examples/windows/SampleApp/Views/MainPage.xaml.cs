using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using SampleApp.ViewModels;

namespace SampleApp.Views;

public sealed partial class MainPage : Page
{
    private readonly RecordingViewModel _vm;

    public MainPage()
    {
        InitializeComponent();
        _vm = App.Services.GetRequiredService<RecordingViewModel>();
        _vm.PropertyChanged += OnViewModelPropertyChanged;

        Loaded += async (_, _) =>
        {
            try
            {
                await _vm.LoadDevicesAsync();
                PopulateMicDropdown();
            }
            catch { }

            _vm.RefreshRecordings();
            UpdateRecordingsList();
        };
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(RecordingViewModel.State):
                UpdateStateUI();
                break;
            case nameof(RecordingViewModel.Duration):
                DurationText.Text = _vm.Duration;
                break;
            case nameof(RecordingViewModel.MicLevel):
                MicMeterFill.Height = _vm.MicLevel * 128;
                break;
            case nameof(RecordingViewModel.SystemLevel):
                SystemMeterFill.Height = _vm.SystemLevel * 128;
                break;
            case nameof(RecordingViewModel.ErrorMessage):
                if (_vm.ErrorMessage != null)
                {
                    ErrorBanner.Message = _vm.ErrorMessage;
                    ErrorBanner.IsOpen = true;
                }
                else
                {
                    ErrorBanner.IsOpen = false;
                }
                break;
            case nameof(RecordingViewModel.MicLevelText):
            case nameof(RecordingViewModel.SystemLevelText):
                LevelDebugText.Text = $"mic: {_vm.MicLevelText}  ·  sys: {_vm.SystemLevelText}";
                break;
        }
    }

    private void UpdateStateUI()
    {
        var state = _vm.State;
        StateLabel.Text = state;

        // Button visibility
        bool idle = state is "Idle" or "Failed";
        bool capturing = state == "Capturing";
        bool paused = state == "Paused";
        bool busy = state is "Configuring" or "Ready" or "Stopping";

        RecordButton.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        PauseButton.Visibility = capturing ? Visibility.Visible : Visibility.Collapsed;
        ResumeButton.Visibility = paused ? Visibility.Visible : Visibility.Collapsed;
        StopButton.Visibility = (capturing || paused) ? Visibility.Visible : Visibility.Collapsed;

        if (busy)
        {
            RecordButton.Visibility = Visibility.Collapsed;
            PauseButton.Visibility = Visibility.Collapsed;
            ResumeButton.Visibility = Visibility.Collapsed;
            StopButton.Visibility = Visibility.Collapsed;
        }

        // Debug text visibility
        LevelDebugText.Visibility = (capturing || paused) ? Visibility.Visible : Visibility.Collapsed;

        // Disable settings during recording
        bool active = _vm.IsActive;
        MicDropdown.IsEnabled = !active;
        MixingDropdown.IsEnabled = !active;
        EncryptionToggle.IsEnabled = !active;
        RawPcmToggle.IsEnabled = !active;
        MicToggle.IsEnabled = !active;
        SystemToggle.IsEnabled = !active;

        UpdateRecordingsList();
    }

    private void UpdateRecordingsList()
    {
        if (_vm.Recordings.Count > 0)
        {
            EmptyListText.Visibility = Visibility.Collapsed;
            RecordingsList.Visibility = Visibility.Visible;
            RecordingsList.ItemsSource = _vm.Recordings;
        }
        else
        {
            EmptyListText.Visibility = Visibility.Visible;
            RecordingsList.Visibility = Visibility.Collapsed;
        }
    }

    private void PopulateMicDropdown()
    {
        MicDropdown.Items.Clear();
        MicDropdown.Items.Add(new ComboBoxItem { Content = "System Default", Tag = (string?)null });
        foreach (var mic in _vm.AvailableMics)
        {
            var suffix = mic.IsDefault ? " (Default)" : "";
            MicDropdown.Items.Add(new ComboBoxItem { Content = $"{mic.Name}{suffix}", Tag = mic.Id });
        }
        MicDropdown.SelectedIndex = 0;
    }

    // Event handlers
    private async void OnRecordClick(object sender, RoutedEventArgs e) =>
        await _vm.StartRecordingCommand.ExecuteAsync(null);

    private void OnPauseClick(object sender, RoutedEventArgs e) =>
        _vm.PauseRecordingCommand.Execute(null);

    private void OnResumeClick(object sender, RoutedEventArgs e) =>
        _vm.ResumeRecordingCommand.Execute(null);

    private async void OnStopClick(object sender, RoutedEventArgs e) =>
        await _vm.StopRecordingCommand.ExecuteAsync(null);

    private void OnPlayClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: RecordingInfo info })
            _vm.OpenRecordingCommand.Execute(info);
    }

    private void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: RecordingInfo info })
        {
            _vm.DeleteRecordingCommand.Execute(info);
            UpdateRecordingsList();
        }
    }

    private void OnMicSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MicDropdown.SelectedItem is ComboBoxItem item)
            _vm.SelectedMicId = item.Tag as string;
    }

    private void OnMixingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (MixingDropdown.SelectedItem is ComboBoxItem item)
        {
            _vm.MixingStrategy = item.Tag as string ?? "Blended";
            MixingDescription.Text = _vm.MixingStrategy == "Separated"
                ? "L = mic only, R = (system_L + system_R) / 2"
                : "L = mic + system_L, R = mic + system_R";
        }
    }

    private void OnRawPcmToggled(object sender, RoutedEventArgs e) =>
        _vm.ExportRawPcm = RawPcmToggle.IsOn;

    private void OnEncryptionToggled(object sender, RoutedEventArgs e) =>
        _vm.EncryptionEnabled = EncryptionToggle.IsOn;

    private void OnMicToggled(object sender, RoutedEventArgs e) =>
        _vm.EnableMic = MicToggle.IsOn;

    private void OnSystemToggled(object sender, RoutedEventArgs e) =>
        _vm.EnableSystem = SystemToggle.IsOn;
}
