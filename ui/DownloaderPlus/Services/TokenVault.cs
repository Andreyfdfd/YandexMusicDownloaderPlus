using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace DownloaderPlus.Services
{
    internal static class TokenVault
    {
        public static string TokenPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "YandexMusicDownloaderPlus",
                    "token.dpapi");
            }
        }

        public static bool HasSavedToken
        {
            get { return File.Exists(TokenPath) && !string.IsNullOrWhiteSpace(File.ReadAllText(TokenPath).Trim()); }
        }

        public static void Save(string token)
        {
            if (string.IsNullOrWhiteSpace(token))
                throw new ArgumentException("Введите токен Яндекс Музыки.", nameof(token));
            ProtectAndWrite(TokenPath, token.Trim());
        }

        public static void Delete()
        {
            if (File.Exists(TokenPath))
                File.Delete(TokenPath);
        }

        public static string Load()
        {
            return ReadAndUnprotect(TokenPath);
        }

        internal static void ProtectAndWrite(string path, string value)
        {
            byte[] clear = Encoding.Unicode.GetBytes(value ?? string.Empty);
            byte[] protectedBytes = null;
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                protectedBytes = ProtectedData.Protect(clear, null, DataProtectionScope.CurrentUser);
                string hex = BitConverter.ToString(protectedBytes).Replace("-", string.Empty).ToLowerInvariant();
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(temporary, hex, Encoding.ASCII);
                if (File.Exists(path))
                    File.Replace(temporary, path, null);
                else
                    File.Move(temporary, path);
            }
            finally
            {
                Array.Clear(clear, 0, clear.Length);
                if (protectedBytes != null) Array.Clear(protectedBytes, 0, protectedBytes.Length);
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }

        internal static string ReadAndUnprotect(string path)
        {
            if (!File.Exists(path))
                throw new FileNotFoundException("Сохранённый токен не найден.", path);
            string hex = File.ReadAllText(path, Encoding.ASCII).Trim();
            if (hex.Length == 0 || hex.Length % 2 != 0)
                throw new FormatException("Файл токена пуст или повреждён.");

            byte[] encrypted = new byte[hex.Length / 2];
            byte[] clear = null;
            try
            {
                for (int i = 0; i < encrypted.Length; i++)
                    encrypted[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);

                clear = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
                return Encoding.Unicode.GetString(clear).TrimEnd('\0');
            }
            finally
            {
                Array.Clear(encrypted, 0, encrypted.Length);
                if (clear != null) Array.Clear(clear, 0, clear.Length);
            }
        }
    }
}
