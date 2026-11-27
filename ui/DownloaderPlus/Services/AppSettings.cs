using System;
using System.IO;
using System.Runtime.Serialization;
using System.Xml;

namespace DownloaderPlus.Services
{
    [DataContract]
    internal sealed class AppSettings
    {
        [DataMember] public string SourceUrl { get; set; }
        [DataMember] public string MusicPath { get; set; }
        [DataMember] public string ExportPath { get; set; }
        [DataMember] public string Quality { get; set; }
        [DataMember] public string Lyrics { get; set; }
        [DataMember] public bool DelayRequests { get; set; }
        [DataMember] public bool AutoRetry { get; set; }
        [DataMember] public bool AutoFailover { get; set; }
        [DataMember] public bool AllowBrowserFallback { get; set; }
        [DataMember] public string Browser { get; set; }

        public static string SettingsPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "YandexMusicDownloaderPlus",
                    "ui-settings.xml");
            }
        }

        public static AppSettings CreateDefault()
        {
            return new AppSettings
            {
                SourceUrl = "",
                MusicPath = ReadMusicPath(),
                ExportPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                    "YandexMusicBackups"),
                Quality = "aac",
                Lyrics = "0",
                DelayRequests = false,
                AutoRetry = true,
                AutoFailover = true,
                AllowBrowserFallback = false,
                Browser = "chrome"
            };
        }

        public static AppSettings Load()
        {
            if (!File.Exists(SettingsPath))
                return CreateDefault();

            try
            {
                using (var stream = File.OpenRead(SettingsPath))
                    return (AppSettings)new DataContractSerializer(typeof(AppSettings)).ReadObject(stream) ?? CreateDefault();
            }
            catch
            {
                return CreateDefault();
            }
        }

        public void Save()
        {
            string path = SettingsPath;
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var stream = File.Create(temp))
                    new DataContractSerializer(typeof(AppSettings)).WriteObject(stream, this);
                if (File.Exists(path))
                    File.Replace(temp, path, null);
                else
                    File.Move(temp, path);
            }
            finally
            {
                if (File.Exists(temp)) File.Delete(temp);
            }
        }

        public static string ReadMusicPath()
        {
            try
            {
                string config = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "YandexMusicDownloaderPlus",
                    "music-path.txt");
                if (File.Exists(config))
                {
                    string value = File.ReadAllText(config).Trim();
                    if (!string.IsNullOrWhiteSpace(value)) return value;
                }
            }
            catch { }

            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Music");
        }

        public void SaveMusicPath()
        {
            string config = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "YandexMusicDownloaderPlus",
                "music-path.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(config));
            File.WriteAllText(config, (MusicPath ?? "").Trim() + Environment.NewLine);
        }
    }
}
