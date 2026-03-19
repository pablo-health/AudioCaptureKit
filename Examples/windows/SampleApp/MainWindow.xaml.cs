using Microsoft.UI.Xaml;

namespace SampleApp;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
    }
}
