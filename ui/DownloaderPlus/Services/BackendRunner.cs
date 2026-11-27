using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace DownloaderPlus.Services
{
    internal sealed class BackendRunner : IDisposable
    {
        private readonly object sync = new object();
        private Process process;
        private string cancelFile;

        public bool IsRunning
        {
            get
            {
                lock (sync)
                    return process != null && !process.HasExited;
            }
        }

        public void Start(
            string applicationRoot,
            string action,
            string sourceUrl,
            string outputDirectory,
            string logPath,
            AppSettings settings,
            Action<string> onOutput,
            Action<int> onExit)
        {
            lock (sync)
            {
                if (process != null && !process.HasExited)
                    throw new InvalidOperationException("Загрузчик уже выполняется.");

                string script = Path.Combine(applicationRoot, "YandexMusicDownloader.ps1");
                if (!File.Exists(script))
                    throw new FileNotFoundException("PowerShell backend не найден.", script);

                cancelFile = Path.Combine(Path.GetTempPath(), "ymdp-cancel-" + Guid.NewGuid().ToString("N") + ".flag");
                var start = new ProcessStartInfo
                {
                    FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                    Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script),
                    WorkingDirectory = applicationRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                var env = start.EnvironmentVariables;
                env["YMDPLUS_GUI_MODE"] = "1";
                env["YMDPLUS_GUI_ACTION"] = action;
                env["YMDPLUS_GUI_SOURCE_URL"] = sourceUrl ?? "";
                env["YMDPLUS_GUI_OUTPUT_DIR"] = outputDirectory ?? "";
                env["YMDPLUS_GUI_LOG_PATH"] = logPath ?? "";
                env["YMDPLUS_GUI_QUALITY"] = settings.Quality ?? "aac";
                env["YMDPLUS_GUI_LYRICS"] = settings.Lyrics ?? "0";
                env["YMDPLUS_GUI_DELAY"] = settings.DelayRequests ? "1" : "0";
                env["YMDPLUS_GUI_AUTO_RETRY"] = settings.AutoRetry ? "1" : "0";
                env["YMDPLUS_GUI_AUTO_FAILOVER"] = settings.AutoFailover ? "1" : "0";
                env["YMDPLUS_GUI_ALLOW_YTDLP"] = settings.AllowBrowserFallback ? "1" : "0";
                env["YMDPLUS_GUI_BROWSER"] = settings.Browser ?? "chrome";
                env["YMDPLUS_GUI_CANCEL_FILE"] = cancelFile;

                process = new Process { StartInfo = start, EnableRaisingEvents = true };
                process.OutputDataReceived += (s, e) =>
                {
                    if (e.Data != null) onOutput?.Invoke(e.Data);
                };
                process.ErrorDataReceived += (s, e) =>
                {
                    if (e.Data != null) onOutput?.Invoke(e.Data);
                };
                process.Exited += (s, e) =>
                {
                    int code = 1;
                    try { code = process.ExitCode; } catch { }
                    try { onExit?.Invoke(code); } finally
                    {
                        lock (sync)
                        {
                            try { process.Dispose(); } catch { }
                            process = null;
                            if (!string.IsNullOrWhiteSpace(cancelFile) && File.Exists(cancelFile))
                                try { File.Delete(cancelFile); } catch { }
                            cancelFile = null;
                        }
                    }
                };

                if (!process.Start())
                    throw new InvalidOperationException("Не удалось запустить PowerShell backend.");

                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
        }

        public void Cancel()
        {
            Process current;
            string marker;
            lock (sync)
            {
                current = process;
                marker = cancelFile;
                if (current == null || current.HasExited) return;
                if (!string.IsNullOrWhiteSpace(marker))
                {
                    try { File.WriteAllText(marker, "cancel"); } catch { }
                }
            }

            int processId;
            try { processId = current.Id; }
            catch { return; }

            Task.Run(async () =>
            {
                await Task.Delay(3500).ConfigureAwait(false);
                try
                {
                    using (var check = Process.GetProcessById(processId))
                    {
                        if (check.HasExited) return;
                    }

                    var killer = new ProcessStartInfo
                    {
                        FileName = "taskkill.exe",
                        Arguments = "/PID " + processId + " /T /F",
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };
                    using (var taskkill = Process.Start(killer))
                        taskkill?.WaitForExit(3000);
                }
                catch { }
            });
        }

        private static string Quote(string value)
        {
            // Windows file names cannot contain quotes; wrapping is sufficient.
            // Backslashes must not be doubled in a raw CreateProcess command line.
            return "\"" + (value ?? "") + "\"";
        }

        public void Dispose()
        {
            Cancel();
            lock (sync)
            {
                try { process?.Dispose(); } catch { }
                process = null;
            }
        }
    }
}
