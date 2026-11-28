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
        private bool returnToFailedTracksAfterSingleRetry;
        private int failedSearchOffset;

        private sealed class FailedTrack
        {
            public string TrackTitle { get; set; }
            public string Artists { get; set; }
            public string AlbumTitle { get; set; }
            public string TrackUrl { get; set; }
            public string RelativeBasePath { get; set; }
            public string Details { get; set; }
            public string DisplayName { get; set; }
            public string TrackKey { get; set; }
        }

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
            if (!string.IsNullOrWhiteSpace(AppSettings.LastLoadWarning))
            {
                MessageBox.Show(this, AppSettings.LastLoadWarning, "Восстановление настроек",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }

            SourceUrlBox.Text = settings.SourceUrl ?? "";
            ExportSourceBox.Text = settings.SourceUrl ?? "";
            SourceUrlBox.TextChanged += SourceUrlBox_TextChanged;
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

        private void SourceUrlBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            // Persist the playlist/source URL as the user edits it, so it survives
            // closing the app or an in-place installer update without requiring a download.
            settings.SourceUrl = SourceUrlBox.Text.Trim();
            try
            {
                settings.Save();
            }
            catch (Exception ex)
            {
                SetStatus("Не удалось автоматически сохранить ссылку", false);
                Debug.WriteLine("Source URL autosave failed: " + ex);
            }
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

        private void NavFailedTracks_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(3, "Неудачные треки", "Список проблемных композиций: повторная загрузка по одной или всем сразу.", sender as Button);
            RefreshLogs();
            RefreshFailedTracks();
        }

        private void NavLogs_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(4, "Журналы и отчёты", "История операций, диагностика и пофайловые результаты.", sender as Button);
            RefreshLogs();
        }

        private void NavSettings_Click(object sender, RoutedEventArgs e)
        {
            ShowPage(5, "Настройки", "Токен, пути и параметры работы Downloader Plus.", sender as Button);
        }

        private void FailedRunCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            failedSearchOffset = 0;
            if (FailedRunCombo == null || FailedTracksList == null) return;
            RefreshFailedTracks();
        }

        private void RefreshFailedTracks_Click(object sender, RoutedEventArgs e)
        {
            RefreshLogs();
            RefreshFailedTracks();
        }

        private sealed class ParsedUnavailable
        {
            public int TrackIndex { get; set; }
            public string TrackTitle { get; set; }
            public string Artists { get; set; }
        }

        private static string NormalizeLegacyConsoleMojibake(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            // Undo UTF-8 bytes interpreted as CP866, then saved as UTF-8.
            try
            {
                byte[] cp866Bytes = Encoding.GetEncoding(866).GetBytes(text);
                string repaired = Encoding.UTF8.GetString(cp866Bytes);
                if (repaired.Contains("не доступен для скачивания") || repaired.Contains("недоступен для скачивания"))
                    return repaired;
            }
            catch { }
            return text;
        }

        private static List<ParsedUnavailable> ParseUnavailableTracksFromLog(string text)
        {
            var result = new List<ParsedUnavailable>();
            if (string.IsNullOrWhiteSpace(text)) return result;
            var pattern = new Regex(@"^\s*\[(?<index>\d+)\s*/\s*\d+\]\s*(?:Трек\s+)?(?<track>.+?)\s+(?:не\s+доступен|недоступен|недоступна|недоступно)\s+для\s+скачивания\s*$",
                RegexOptions.IgnoreCase | RegexOptions.Multiline | RegexOptions.CultureInvariant);
            foreach (Match match in pattern.Matches(text))
            {
                string track = match.Groups["track"].Value.Trim();
                int index;
                if (!int.TryParse(match.Groups["index"].Value, out index) || string.IsNullOrWhiteSpace(track)) continue;
                string artists = "";
                string title = track;
                int separator = track.IndexOf(" - ", StringComparison.Ordinal);
                if (separator > 0)
                {
                    artists = track.Substring(0, separator).Trim();
                    title = track.Substring(separator + 3).Trim();
                }
                result.Add(new ParsedUnavailable { TrackIndex = index, TrackTitle = title, Artists = artists });
            }
            return result.GroupBy(x => x.TrackIndex + "|" + x.TrackTitle, StringComparer.OrdinalIgnoreCase)
                .Select(g => g.First()).OrderBy(x => x.TrackIndex).ToList();
        }

        private static List<string> ParseCsvLine(string line)
        {
            var fields = new List<string>();
            var current = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < (line ?? "").Length; i++)
            {
                char ch = line[i];
                if (ch == '"')
                {
                    if (quoted && i + 1 < line.Length && line[i + 1] == '"') { current.Append('"'); i++; }
                    else quoted = !quoted;
                }
                else if (ch == ',' && !quoted) { fields.Add(current.ToString()); current.Clear(); }
                else current.Append(ch);
            }
            fields.Add(current.ToString());
            return fields;
        }

        private static List<Dictionary<string, string>> ReadCsv(string path)
        {
            var rows = new List<Dictionary<string, string>>();
            if (!File.Exists(path)) return rows;
            var lines = File.ReadAllLines(path, Encoding.UTF8);
            if (lines.Length < 2) return rows;
            var headers = ParseCsvLine(lines[0]);
            for (int i = 1; i < lines.Length; i++)
            {
                if (string.IsNullOrWhiteSpace(lines[i])) continue;
                var values = ParseCsvLine(lines[i]);
                var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int h = 0; h < headers.Count; h++) row[headers[h]] = h < values.Count ? values[h] : "";
                rows.Add(row);
            }
            return rows;
        }

        private static string CsvValue(Dictionary<string, string> row, string key)
        {
            string value;
            return row != null && row.TryGetValue(key, out value) ? value : "";
        }

        private bool TrackFileExists(FailedTrack track)
        {
            if (track == null || string.IsNullOrWhiteSpace(track.RelativeBasePath)) return false;
            string basePath = Path.Combine(settings.MusicPath ?? "", track.RelativeBasePath.Replace('/', Path.DirectorySeparatorChar));
            foreach (string ext in new[] { ".m4a", ".mp3", ".flac", ".aac", ".ogg", ".opus", ".wav" })
                if (File.Exists(basePath + ext)) return true;
            return false;
        }

        private void RefreshFailedTracks()
        {
            var selectedRun = FailedRunCombo.SelectedItem as LogEntry;
            if (selectedRun == null)
            {
                FailedTracksList.ItemsSource = null;
                FailedTracksSummary.Text = "Нет журналов загрузки для выбора.";
                RetryFailedAllButton.IsEnabled = false;
                SearchFailedAllButton.IsEnabled = false;
                RetryFailedSelectedButton.IsEnabled = false;
                SearchFailedSelectedButton.IsEnabled = false;
                return;
            }

            string stamp = Regex.Match(Path.GetFileName(selectedRun.FullPath), @"^download-(\d{8}-\d{6})\.log$", RegexOptions.IgnoreCase).Groups[1].Value;
            if (string.IsNullOrWhiteSpace(stamp))
            {
                FailedTracksList.ItemsSource = null;
                FailedTracksSummary.Text = "Не удалось определить дату выбранного запуска.";
                RetryFailedAllButton.IsEnabled = false;
                SearchFailedAllButton.IsEnabled = false;
                RetryFailedSelectedButton.IsEnabled = false;
                SearchFailedSelectedButton.IsEnabled = false;
                return;
            }

            string logsDir = Path.Combine(applicationRoot, "logs");
            var failures = new Dictionary<string, FailedTrack>(StringComparer.OrdinalIgnoreCase);
            string reportPath = Path.Combine(logsDir, "library-status-" + stamp + ".csv");
            foreach (var row in ReadCsv(reportPath))
            {
                if (!string.Equals(CsvValue(row, "Category"), "Не удалось скачать", StringComparison.OrdinalIgnoreCase)) continue;
                string url = CsvValue(row, "TrackUrl");
                string title = CsvValue(row, "TrackTitle");
                if (string.IsNullOrWhiteSpace(title)) continue;
                var item = new FailedTrack { TrackTitle = title, Artists = CsvValue(row, "Artists"), AlbumTitle = CsvValue(row, "AlbumTitle"), TrackUrl = url, RelativeBasePath = CsvValue(row, "RelativeBasePath"), Details = CsvValue(row, "Details"), TrackKey = CsvValue(row, "TrackKey") };
                string key = !string.IsNullOrWhiteSpace(item.TrackKey) ? item.TrackKey : (!string.IsNullOrWhiteSpace(url) ? url : title + "|" + item.Artists);
                if (!failures.ContainsKey(key)) failures[key] = item;
            }

            string queuePath = Path.Combine(logsDir, "retry-queue-" + stamp + ".csv");
            foreach (var row in ReadCsv(queuePath))
            {
                string url = CsvValue(row, "TrackUrl");
                string title = CsvValue(row, "TrackTitle");
                if (string.IsNullOrWhiteSpace(url) || string.IsNullOrWhiteSpace(title)) continue;
                var item = new FailedTrack { TrackTitle = title, Artists = CsvValue(row, "Artists"), AlbumTitle = CsvValue(row, "AlbumTitle"), TrackUrl = url, RelativeBasePath = CsvValue(row, "RelativeBasePath"), Details = CsvValue(row, "Details"), TrackKey = CsvValue(row, "TrackKey") };
                string key = string.IsNullOrWhiteSpace(item.TrackKey) ? url : item.TrackKey;
                if (!failures.ContainsKey(key)) failures[key] = item;
            }

            // If structured reports are missing or incomplete, parse the run log as a fallback.
            // PowerShell may have captured Python UTF-8 output through the legacy CP866 console
            // code page, leaving UTF-8 text represented as CP866 mojibake inside a UTF-8 log.
            string downloadLogPath = selectedRun.FullPath;
            string logText = File.Exists(downloadLogPath) ? File.ReadAllText(downloadLogPath, Encoding.UTF8) : "";
            string normalizedLogText = NormalizeLegacyConsoleMojibake(logText);
            var logEntries = ParseUnavailableTracksFromLog(normalizedLogText);
            foreach (var parsed in logEntries)
            {
                string key = "log:" + parsed.TrackIndex + "|" + parsed.TrackTitle;
                if (!failures.ContainsKey(key))
                    failures[key] = new FailedTrack
                    {
                        TrackTitle = parsed.TrackTitle,
                        Artists = parsed.Artists,
                        TrackUrl = "",
                        Details = "Недоступен по данным журнала (позиция " + parsed.TrackIndex + ")"
                    };
            }

            string recoveryPath = Path.Combine(logsDir, "recovery-results-" + stamp + ".csv");
            var recovered = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in ReadCsv(recoveryPath))
            {
                string key = CsvValue(row, "TrackKey");
                if (string.IsNullOrWhiteSpace(key)) key = CsvValue(row, "TrackId");
                if (string.Equals(CsvValue(row, "Status"), "Успешно восстановлен", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(key))
                    recovered.Add(key);
            }
            var visible = failures.Values.Where(t => !recovered.Contains(t.TrackKey ?? "") && !TrackFileExists(t))
                .Select(t => { t.DisplayName = (string.IsNullOrWhiteSpace(t.Artists) ? "" : t.Artists + " — ") + t.TrackTitle + (string.IsNullOrWhiteSpace(t.Details) ? "" : "  |  " + t.Details); return t; })
                .OrderBy(t => t.Artists).ThenBy(t => t.TrackTitle).ToList();
            FailedTracksList.ItemsSource = visible;
            bool reportExists = File.Exists(reportPath) || File.Exists(queuePath);
            FailedTracksSummary.Text = visible.Count == 0
                ? (logEntries.Count > 0
                    ? "Найдено в журнале " + logEntries.Count + " недоступных позиций, но они не попали в список после проверки наличия файлов/восстановлений."
                    : "Не найдено неудачных треков. Проверены отчёты и основной журнал; если формат журнала не распознан, сообщи об этом.")
                : "Неудачных/не подтверждённых композиций: " + visible.Count
                    + (reportExists ? " (отчёты и журнал)" : " (восстановлено из основного журнала)");
            RetryFailedAllButton.IsEnabled = visible.Count > 0;
            SearchFailedAllButton.IsEnabled = visible.Count > 0;
        }

        private void FailedTracksList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var selectedTrack = FailedTracksList.SelectedItem as FailedTrack;
            bool selected = selectedTrack != null;
            RetryFailedSelectedButton.IsEnabled = selected && !string.IsNullOrWhiteSpace(selectedTrack.TrackUrl);
            SearchFailedSelectedButton.IsEnabled = selected;
            SearchFailedAllButton.IsEnabled = FailedTracksList.Items.Count > 0;
        }

        private void SearchFailedAll_Click(object sender, RoutedEventArgs e)
        {
            var tracks = FailedTracksList.Items.Cast<FailedTrack>().ToList();
            if (tracks.Count == 0) return;
            if (failedSearchOffset >= tracks.Count) failedSearchOffset = 0;
            int start = failedSearchOffset;
            int openCount = Math.Min(10, tracks.Count - start);
            string prompt = "Открыть веб-поиск по " + openCount + " композициям в отдельных вкладках браузера?";
            if (tracks.Count > openCount) prompt += Environment.NewLine + "Остальные треки будут доступны следующей группой при повторном нажатии.";
            if (MessageBox.Show(this, prompt, "Массовый поиск", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            try
            {
                for (int i = start; i < start + openCount; i++)
                {
                    var track = tracks[i];
                    string query = ((track.Artists ?? "") + " " + (track.TrackTitle ?? "") + " official audio").Trim();
                    string url = "https://www.google.com/search?q=" + Uri.EscapeDataString(query);
                    Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
                    if (i + 1 < start + openCount) System.Threading.Thread.Sleep(150);
                }
                failedSearchOffset = (start + openCount) % tracks.Count;
                FailedTracksSummary.Text = "Открыто поисков " + openCount + ". Следующая группа начинается с трека " + (failedSearchOffset + 1) + " из " + tracks.Count + ".";
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Не удалось открыть пакет поисковых запросов: " + ex.Message, "Ошибка", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void RetryFailedSelected_Click(object sender, RoutedEventArgs e)
        {
            var track = FailedTracksList.SelectedItem as FailedTrack;
            if (track == null) return;
            if (string.IsNullOrWhiteSpace(track.TrackUrl)) { MessageBox.Show(this, "Для этой позиции не удалось определить ссылку трека. Можно использовать веб-поиск или восстановление всего запуска.", "Ссылка отсутствует", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (runner.IsRunning) { MessageBox.Show(this, "Сначала дождись завершения текущей операции.", "Backend занят", MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (!EnsureToken()) return;
            CaptureSettings();
            if (settings.AllowBrowserFallback)
            {
                var consent = MessageBox.Show(this, "Разрешить yt-dlp использовать cookies выбранного браузера для этой повторной попытки? Это может дать локальному процессу доступ к браузерной сессии.", "Согласие на браузерную сессию", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                browserConsentForCurrentRun = consent == MessageBoxResult.Yes;
            } else browserConsentForCurrentRun = false;
            returnToFailedTracksAfterSingleRetry = true;
            StartBackend("download", track.TrackUrl, settings.MusicPath, null);
        }

        private void RetryFailedAll_Click(object sender, RoutedEventArgs e)
        {
            var selectedRun = FailedRunCombo.SelectedItem as LogEntry;
            if (selectedRun == null || runner.IsRunning) return;
            if (!EnsureToken()) return;
            CaptureSettings();
            if (settings.AllowBrowserFallback)
            {
                var consent = MessageBox.Show(this, "Разрешить yt-dlp использовать cookies выбранного браузера для восстановления всех неудачных треков?", "Согласие на браузерную сессию", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                browserConsentForCurrentRun = consent == MessageBoxResult.Yes;
            } else browserConsentForCurrentRun = false;
            StartBackend("retry", settings.MusicPath, settings.MusicPath, selectedRun.FullPath);
        }

        private void SearchFailedSelected_Click(object sender, RoutedEventArgs e)
        {
            var track = FailedTracksList.SelectedItem as FailedTrack;
            if (track == null) return;
            string query = ((track.Artists ?? "") + " " + (track.TrackTitle ?? "") + " official music").Trim();
            string url = "https://www.google.com/search?q=" + Uri.EscapeDataString(query);
            try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(this, "Не удалось открыть поиск: " + ex.Message, "Ошибка", MessageBoxButton.OK, MessageBoxImage.Warning); }
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

        private void UpdateDownloader_Click(object sender, RoutedEventArgs e)
        {
            if (runner.IsRunning)
            {
                MessageBox.Show(this, "Сначала дождись завершения текущей операции.", "Backend занят",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            try
            {
                CaptureSettings();
                StartBackend("update", "", settings.MusicPath, null);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Не удалось запустить обновление: " + ex.Message,
                    "Ошибка обновления", MessageBoxButton.OK, MessageBoxImage.Error);
            }
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

            SourceUrlBox.Text = source;
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
                    action == "retry" ? "Восстановление треков…" :
                    action == "update" ? "Обновление основного загрузчика…" : "Загрузка музыки…";
                SetStatus("Выполняется", true);
                WorkspaceTabs.SelectedIndex = action == "update" ? 5 : action == "retry" ? WorkspaceTabs.SelectedIndex : 0;
                PageTitle.Text = action == "export" ? "Экспорт библиотеки" :
                    action == "retry" ? (WorkspaceTabs.SelectedIndex == 3 ? "Неудачные треки" : "Восстановление") :
                    action == "update" ? "Настройки и обновления" : "Загрузка музыки";

                var runSettings = new AppSettings
                {
                    SourceUrl = settings.SourceUrl,
                    MusicPath = settings.MusicPath,
                    ExportPath = settings.ExportPath,
                    Quality = settings.Quality,
                    Lyrics = settings.Lyrics,
                    DelayRequests = settings.DelayRequests,
                    AutoRetry = settings.AutoRetry,
                    AutoFailover = settings.AutoFailover,
                    AllowBrowserFallback = browserConsentForCurrentRun,
                    Browser = settings.Browser
                };

                runner.Start(
                    applicationRoot,
                    action,
                    source,
                    outputPath,
                    logPath,
                    runSettings,
                    AppendOutput,
                    HandleBackendExit);
            }
            catch (Exception ex)
            {
                DownloadProgress.IsIndeterminate = false;
                SetStatus("Ошибка запуска", false);
                returnToFailedTracksAfterSingleRetry = false;
                MessageBox.Show(this, "Не удалось запустить backend: " + ex.Message,
                    "Ошибка запуска", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void Window_SizeChanged(object sender, SizeChangedEventArgs e)
        {
            if (LiveOutputBox == null) return;
            LiveOutputBox.Height = Math.Max(230.0, Math.Min(460.0, ActualHeight * 0.38));
        }

        private void AppendOutput(string line)
        {
            if (closing) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (closing) return;
                LiveOutputBox.AppendText(line + Environment.NewLine);
                LiveOutputBox.ScrollToEnd();

                Match trackMatch = Regex.Match(line ?? "", @"^\s*\[(?<current>\d+)\s*/\s*(?<total>\d+)\]\s*(?:Трек\s+)?(?<track>.+)$");
                if (trackMatch.Success && CurrentTrackText != null)
                    CurrentTrackText.Text = "Сейчас: " + trackMatch.Groups["current"].Value + "/" + trackMatch.Groups["total"].Value + " — " + trackMatch.Groups["track"].Value;

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
                if (returnToFailedTracksAfterSingleRetry)
                {
                    returnToFailedTracksAfterSingleRetry = false;
                    ShowPage(3, "Неудачные треки", "Список проблемных композиций: повторная загрузка по одной или всем сразу.", NavFailedTracks);
                    RefreshFailedTracks();
                }
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
            if (FailedRunCombo != null)
            {
                var previous = FailedRunCombo.SelectedItem as LogEntry;
                string previousPath = previous == null ? null : previous.FullPath;
                FailedRunCombo.ItemsSource = recoverable;
                if (!string.IsNullOrWhiteSpace(previousPath))
                    FailedRunCombo.SelectedItem = recoverable.FirstOrDefault(x => x.FullPath == previousPath);
                if (FailedRunCombo.SelectedIndex < 0 && FailedRunCombo.Items.Count > 0)
                    FailedRunCombo.SelectedIndex = 0;
                RefreshFailedTracks();
            }
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
            // Final save of all fields on exit; the source URL is also autosaved while editing.
            try { CaptureSettings(); }
            catch (Exception ex) { Debug.WriteLine("Final settings save failed: " + ex); }
            closing = true;
            runner.Dispose();
        }
    }
}
