using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace SampleApp.Converters;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool invert = parameter is string s && s == "Invert";
        bool val = value is bool b && b;
        if (invert) val = !val;
        return val ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => throw new NotSupportedException();
}
