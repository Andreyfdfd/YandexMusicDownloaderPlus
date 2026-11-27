using System;
using System.IO;
using System.Linq;
using System.Windows;
using DownloaderPlus.Services;

namespace DownloaderPlus
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            if (e.Args.Any(a => string.Equals(a, "--self-test", StringComparison.OrdinalIgnoreCase)))
            {
                try
                {
                    string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
                    string script = Path.Combine(root, "YandexMusicDownloader.ps1");
                    if (!File.Exists(script))
                        throw new FileNotFoundException("PowerShell backend is missing.", script);

                    string appData = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                        "YandexMusicDownloaderPlus");
                    Directory.CreateDirectory(appData);
                    string probe = Path.Combine(appData, "gui-self-test-" + Guid.NewGuid().ToString("N") + ".dpapi");
                    try
                    {
                        TokenVault.ProtectAndWrite(probe, "DownloaderPlus-self-test");
                        string roundTrip = TokenVault.ReadAndUnprotect(probe);
                        if (!string.Equals(roundTrip, "DownloaderPlus-self-test", StringComparison.Ordinal))
                            throw new InvalidOperationException("DPAPI round-trip did not preserve the test value.");
                    }
                    finally
                    {
                        if (File.Exists(probe)) File.Delete(probe);
                    }
                    Shutdown(0);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine(ex);
                    Shutdown(1);
                }
                return;
            }

            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
    }
}
