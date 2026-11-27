using DownloaderPlus.Services;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace DownloaderPlus
{
    public partial class MainWindow : Window
    {
        private readonly AppSettings settings;
        private readonly BackendRunner runner = new BackendRunner();
        private readonly string applicationRoot;
        private bool closing;
        private bool browserConsentForCurrentRun;

        private sealed class LogEntry
        {
            public string FullPath { get; set; }
            public string DisplayName { get; set; }
        }

        public MainWindow()
        {
            InitializeComponent();

            applicationRoot = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            settings = AppSettings.Load();

            SourceUrlBox.Text = settings.SourceUrl ?? "";
            ExportSourceBox.Text = settings.SourceUrl ?? "";
            MusicFolderBox.Text = settings.MusicPath ?? "";
            SettingsMusicFolderBox.Text = settings.MusicPath ?? "";
            ExportFolderBox.Text = settings.ExportPath ?? "";
            SelectByTag(QualityBox, settings.Quality ?? "aac");
            SelectByTag(LyricsBox, settings.Lyrics ?? "0");
            SelectByTag(BrowserBox, settings.Browser ?? "chrome");
            DelayCheck.IsChecked = settings.DelayRequests;
            AutoRetryCheck.IsChecked = settings.AutoRetry;
            AutoFailoverCheck.IsChecked = settings.AutoFailover;
            BrowserFallbackCheck.IsChecked = settings.AllowBrowserFallback;

            UpdateTokenStatus();
            RefreshLogs();
            SetStatus("Готов к работе", false);
            Closing += MainWindow_Closing;
        }

        private static void SelectByTag(ComboBox combo, string tag)
        {
            foreach (ComboBoxItem item in combo.Items)
            {
                if (string.Equals(Convert.ToString(item.Tag), tag, StringComparison.OrdinalIgnoreCase))
                {
                    combo.SelectedItem = item;
                    return;
                }
            }
            if (combo.Items.Count > 0) combo.SelectedIndex = 0;
        }

        private static string SelectedTag(ComboBox combo, string fallback)
        {
            var item = combo.SelectedItem as ComboBoxItem;
            return item == null ? fallback : Convert.ToString(item.Tag);
        }

        private void CaptureSettings()
        {
            settings.SourceUrl = SourceUrlBox.Text.Trim();
            settings.MusicPath = MusicFolderBox.Text.Trim();
            settings.ExportPath = ExportFolderBox.Text.Trim();
            settings.Quality = SelectedTag(QualityBox, "aac");
            settings.Lyrics = SelectedTag(LyricsBox, "0");
            settings.DelayRequests = DelayCheck.IsChecked == true;
            settings.AutoRetry = AutoRetryCheck.IsChecked == true;
            settings.AutoFailover = AutoFailoverCheck.IsChecked == true;
            settings.AllowBrowserFallback = BrowserFallbackCheck.IsChecked == true;
            settings.Browser = SelectedTag(BrowserBox, "chrome");
            settings.Save();
            if (!string.IsNullOrWhiteSpace(settings.MusicPath))
                settings.SaveMusicPath();
        }

        private void SetStatus(string message, bool busy)
        {
            SidebarStatus.Text = message;
            FooterStatus.Text = message;
            StatusDot.Fill = busy
                ? new SolidColorBrush(Color.FromRgb(251, 191, 36))
                : new SolidColorBrush(Color.FromRgb(52, 211, 153));
            DownloadButton.IsEnabled = !busy;
            ExportButton.IsEnabled = !busy;
            RetryButton.IsEnabled = !busy;
            CancelButton.IsEnabled = busy;
        }

        private void ShowPage(int index, string title, string subtitle, Button selectedButton)
        {
            WorkspaceTabs.SelectedIndex = index;
            PageTitle.Text = title;
            PageSubtitle.Text = subtitle;
            foreach (var button in FindVisualChildren<Button>(this).Where(b => b.Name.StartsWith("Nav", StringComparison.Ordinal)))
                button.Background = Brushes.Transparent;
            if (selectedButton != null)
                selectedButton.Background = new SolidColorBrush(Color.FromRgb(45, 35, 74));
        }

        private static IEnumerable<T> FindVisualChildren<T>(DependencyObject parent) where T : DependencyObject
        {
            if (parent == null) yield break;
            int count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent);
            for (int i = 0; i < count; i++)
            {
                DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
                if (child is T typed) yield return typed;
                foreach (T descendant in FindVisualChildren<T>(child)) yield return descendant;
            }
        }

        private void NavDownload_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(0, "Загрузка музыки", "Скачивай плейлисты и альбомы в свою музыкальную библиотеку.", NavDownload);
        }

        private void NavExport_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(1, "Экспорт библиотеки", "Сохрани список композиций в форматах для резервного копирования и переноса.", sender as Button);
        }

        private void NavRecovery_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(2, "Восстановление", "Продолжай незавершённые запуски и восстанавливай проблемные композиции.", sender as Button);
            RefreshLogs();
        }

        private void NavLogs_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(3, "Журналы и отчёты", "История операций, диагностика и пофайловые результаты.", sender as Button);
            RefreshLogs();
        }

        private void NavSettings_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(4, "Настройки", "Токен, пути и параметры работы Downloader Plus.", sender as Button);
        }

        private void BrowseMusic_Click(object sender, RoutedEventArgs e)
        {
            string path = ChooseFolder(MusicFolderBox.Text);
            if (path != null)
            {
                MusicFolderBox.Text = path;
                SettingsMusicFolderBox.Text = path;
            }
        }

        private void BrowseSettingsMusic_Click(object sender, RoutedEventArgs e)
        {
            string path = ChooseFolder(SettingsMusicFolderBox.Text);
            if (path != null)
            {
                SettingsMusicFolderBox.Text = path;
                MusicFolderBox.Text = path;
            }
        }

        private void BrowseExport_Click(object sender, RoutedEventArgs e)
        {
            string path = ChooseFolder(ExportFolderBox.Text);
            if (path != null) ExportFolderBox.Text = path;
        }

        private static string ChooseFolder(string initial)
        {
            using (var dialog = new Forms.FolderBrowserDialog())
            {
                dialog.Description = "Выбери папку";
                dialog.ShowNewFolderButton = true;
                if (!string.IsNullOrWhiteSpace(initial) && Directory.Exists(initial))
                    dialog.SelectedPath = initial;
                return dialog.ShowDialog() == Forms.DialogResult.OK ? dialog.SelectedPath : null;
            }
        }

        private void SaveToken_Click(object sender, RoutedEventArgs e)
        {
            string token = TokenBox.Password;
            if (string.IsNullOrWhiteSpace(token))
            {
                MessageBox.Show(this, "Введи токен Яндекс Музыки в поле выше.", "Токен не указан",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            try
            {
                TokenVault.Save(token);
                TokenBox.Clear();
                UpdateTokenStatus();
                MessageBox.Show(this, "Токен сохранён в профиле текущего пользователя Windows с помощью DPAPI.",
                    "Настройки сохранены", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Не удалось сохранить токен: " + ex.Message,
                    "Ошибка DPAPI", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void DeleteToken_Click(object sender, RoutedEventArgs e)
        {
            if (MessageBox.Show(this, "Удалить сохранённый токен? Для следующей загрузки понадобится ввести его заново.",
                "Подтверждение", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                return;

            try
            {
                TokenVault.Delete();
                TokenBox.Clear();
                UpdateTokenStatus();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Не удалось удалить токен: " + ex.Message,
                    "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void UpdateTokenStatus()
        {
            bool exists = false;
            try { exists = TokenVault.HasSavedToken; } catch { }
            TokenStatus.Text = exists
                ? "Токен сохранён и зашифрован для текущего пользователя Windows."
                : "Токен пока не настроен. Введи его и нажми «Сохранить токен».";
            TokenStatus.Foreground = exists
                ? (Brush)FindResource("SuccessBrush")
                : (Brush)FindResource("WarningBrush");
        }

        private void SaveSettings_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                MusicFolderBox.Text = SettingsMusicFolderBox.Text;
                CaptureSettings();
                UpdateTokenStatus();
                SetStatus("Настройки сохранены", false);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Не удалось сохранить настройки: " + ex.Message,
                    "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private bool EnsureToken()
        {
            if (TokenVault.HasSavedToken) return true;
            MessageBox.Show(this, "Сначала открой раздел «Настройки», введи токен Яндекс Музыки и сохрани его.",
                "Нужен токен", MessageBoxButton.OK, MessageBoxImage.Information);
            NavSettings_Click(NavSettings, new RoutedEventArgs());
            return false;
        }

        private void Download_Click(object sender, RoutedEventArgs e)
        {
            string source = SourceUrlBox.Text.Trim();
            string musicPath = MusicFolderBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(source))
            {
                MessageBox.Show(this, "Вставь ссылку на плейлист, альбом, исполнителя или трек.",
                    "Не указана ссылка", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (string.IsNullOrWhiteSpace(musicPath))
            {
                MessageBox.Show(this, "Укажи папку для музыкальной библиотеки.",
                    "Не указана папка", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (!EnsureToken()) return;

            CaptureSettings();
            if (settings.AllowBrowserFallback)
            {
                var consent = MessageBox.Show(this,
                    "При неудаче первых двух backend-модулей программа сможет попробовать yt-dlp с cookies выбранного браузера. Это передаст локальному процессу доступ к текущей браузерной сессии Яндекса. Разрешить этот резервный способ для текущего запуска?",
                    "Разрешение на использование браузерной сессии",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                browserConsentForCurrentRun = consent == MessageBoxResult.Yes;
            }
            else browserConsentForCurrentRun = false;

            StartBackend("download", source, musicPath, null);
        }

        private void Export_Click(object sender, RoutedEventArgs e)
        {
            string source = ExportSourceBox.Text.Trim();
            string path = ExportFolderBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(source))
            {
                MessageBox.Show(this, "Вставь ссылку на источник.", "Не указана ссылка",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (!EnsureToken()) return;

            CaptureSettings();
            StartBackend("export", source, path, null);
        }

        private void Retry_Click(object sender, RoutedEventArgs e)
        {
            var item = RecoveryLogsList.SelectedItem as LogEntry;
            if (item == null || !File.Exists(item.FullPath))
            {
                MessageBox.Show(this, "Выбери журнал предыдущего запуска.", "Журнал не выбран",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (!EnsureToken()) return;

            CaptureSettings();
            if (settings.AllowBrowserFallback)
            {
                var consent = MessageBox.Show(this,
                    "Разрешить yt-dlp использовать cookies выбранного браузера, если первые два backend-модуля не смогут восстановить трек?",
                    "Разрешение на использование браузерной сессии",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                browserConsentForCurrentRun = consent == MessageBoxResult.Yes;
            }
            else browserConsentForCurrentRun = false;

            StartBackend("retry", settings.MusicPath, settings.MusicPath, item.FullPath);
        }

        private void StartBackend(string action, string source, string outputPath, string logPath)
        {
            if (runner.IsRunning) return;

            try
            {
                LiveOutputBox.Clear();
                DownloadProgress.Value = 0;
                DownloadProgress.IsIndeterminate = true;
                ProgressCaption.Text = "Подготовка…";
                DownloadStatus.Text = action == "export" ? "Экспорт списка композиций…" :
                    action == "retry" ? "Восстановление треков…" : "Загрузка музыки…";
                SetStatus("Выполняется", true);
                WorkspaceTabs.SelectedIndex = 0;
                PageTitle.Text = action == "export" ? "Экспорт библиотеки" :
                    action == "retry" ? "Восстановление" : "Загрузка музыки";

                runner.Start(
                    applicationRoot,
                    action,
                    source,
                    outputPath,
                    logPath,
                    settings,
                    AppendOutput,
                    HandleBackendExit);
            }
            catch (Exception ex)
            {
                DownloadProgress.IsIndeterminate = false;
                SetStatus("Ошибка запуска", false);
                MessageBox.Show(this, "Не удалось запустить backend: " + ex.Message,
                    "Ошибка запуска", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void AppendOutput(string line)
        {
            if (closing) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (closing) return;
                LiveOutputBox.AppendText(line + Environment.NewLine);
                LiveOutputBox.ScrollToEnd();

                Match match = Regex.Match(line ?? "", @"\[(\d+)\s*/\s*(\d+)\]");
                if (match.Success)
                {
                    int current, total;
                    if (int.TryParse(match.Groups[1].Value, out current) &&
                        int.TryParse(match.Groups[2].Value, out total) && total > 0)
                    {
                        DownloadProgress.IsIndeterminate = false;
                        DownloadProgress.Value = Math.Min(100.0, current * 100.0 / total);
                        ProgressCaption.Text = current + " из " + total + " позиций источника";
                    }
                }
            }), DispatcherPriority.Background);
        }

        private void HandleBackendExit(int exitCode)
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (closing) return;
                DownloadProgress.IsIndeterminate = false;
                DownloadProgress.Value = exitCode == 0 ? 100 : DownloadProgress.Value;
                DownloadStatus.Text = exitCode == 0 ? "Операция завершена" : "Операция завершилась с ошибкой";
                ProgressCaption.Text = exitCode == 0
                    ? "Готово. Журналы и отчёты обновлены."
                    : "Код завершения: " + exitCode + ". Проверь журнал для подробностей.";
                SetStatus(exitCode == 0 ? "Готово" : "Завершено с ошибками", false);
                RefreshLogs();
            }), DispatcherPriority.Normal);
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            if (!runner.IsRunning) return;
            DownloadStatus.Text = "Запрашивается отмена…";
            ProgressCaption.Text = "Уже завершённые композиции сохраняются; текущий процесс будет остановлен.";
            runner.Cancel();
        }

        private void RefreshLogs_Click(object sender, RoutedEventArgs e)
        {
            RefreshLogs();
        }

        private void RefreshLogs()
        {
            string logsDirectory = Path.Combine(applicationRoot, "logs");
            Directory.CreateDirectory(logsDirectory);

            var all = Directory.GetFiles(logsDirectory)
                .Select(p => new FileInfo(p))
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .Take(250)
                .Select(f => new LogEntry
                {
                    FullPath = f.FullName,
                    DisplayName = f.LastWriteTime.ToString("yyyy-MM-dd HH:mm") + "   " + f.Name
                }).ToList();

            AllLogsList.ItemsSource = all;
            var recoverable = all.Where(item =>
                Path.GetFileName(item.FullPath).StartsWith("download-", StringComparison.OrdinalIgnoreCase) &&
                item.FullPath.EndsWith(".log", StringComparison.OrdinalIgnoreCase)).ToList();
            RecoveryLogsList.ItemsSource = recoverable;
            if (RecoveryLogsList.Items.Count > 0 && RecoveryLogsList.SelectedIndex < 0)
                RecoveryLogsList.SelectedIndex = 0;
        }

        private void OpenLogsFolder_Click(object sender, RoutedEventArgs e)
        {
            string logsDirectory = Path.Combine(applicationRoot, "logs");
            Directory.CreateDirectory(logsDirectory);
            Process.Start(new ProcessStartInfo { FileName = logsDirectory, UseShellExecute = true });
        }

        private void OpenSelectedLog_Click(object sender, RoutedEventArgs e)
        {
            var item = AllLogsList.SelectedItem as LogEntry;
            if (item == null || !File.Exists(item.FullPath))
            {
                MessageBox.Show(this, "Выбери файл журнала или отчёта.", "Файл не выбран",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            Process.Start(new ProcessStartInfo { FileName = item.FullPath, UseShellExecute = true });
        }

        private void MainWindow_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            closing = true;
            runner.Dispose();
        }
    }
}
