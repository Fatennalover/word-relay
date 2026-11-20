using System.Diagnostics;
using System.Reflection;

namespace WordRelay;

internal static class Program
{
    internal static double Time => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    internal static Stream Asset(string name) =>
        Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
        ?? throw new InvalidDataException($"Missing resource: {name}");

    internal static string WordList(string name)
    {
        using var reader = new StreamReader(Asset(name));
        return reader.ReadToEnd();
    }

    [STAThread]
    private static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new RelayWindow());
    }
}
