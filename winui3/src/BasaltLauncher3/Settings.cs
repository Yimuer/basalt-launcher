using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BasaltLauncher3;

/// <summary>
/// Preferences in %LOCALAPPDATA%\BasaltLauncher\settings.json - the same file and the same
/// key names the PowerShell/WPF launcher uses (closeToTray, theme, material). Unknown keys
/// (for example the WPF launcher's startTrayHintShown) are carried through untouched, so the
/// two launchers can coexist without erasing each other's state.
/// </summary>
public sealed class LauncherSettings
{
    public bool CloseToTray { get; set; } = true;
    public string Theme { get; set; } = "system";      // system | light | dark
    public string Material { get; set; } = "mica";     // mica | micaalt | acrylic | opaque

    private JsonObject _doc;

    public static string Directory_ => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BasaltLauncher");
    public static string FilePath => Path.Combine(Directory_, "settings.json");

    private LauncherSettings(JsonObject doc) { _doc = doc; }

    public static LauncherSettings Load()
    {
        JsonObject doc = new();
        try
        {
            string text = File.ReadAllText(FilePath);
            JsonNode? node = JsonNode.Parse(text);
            if (node is JsonObject parsed) { doc = parsed; }
        }
        catch (Exception) { /* missing or corrupt file starts from defaults */ }

        LauncherSettings s = new(doc);
        s.CloseToTray = ReadBool(doc, "closeToTray", true);
        s.Theme = ReadString(doc, "theme", "system");
        s.Material = MapMaterial(ReadString(doc, "material", "mica"));
        return s;
    }

    /// <summary>
    /// The WPF launcher's vocabulary differs. opaque is shared; wallpaper meant "tinted by the
    /// desktop", which in WinUI is Mica. Anything unrecognised falls back to Mica rather than
    /// being guessed into a different material.
    /// </summary>
    private static string MapMaterial(string value) => value.ToLowerInvariant() switch
    {
        "opaque" or "none" => "none",
        "mica" => "mica",
        "micaalt" or "mica-alt" or "micaalt2" => "micaalt",
        "acrylic" or "desktopacrylic" => "acrylic",
        "wallpaper" => "mica",
        _ => "mica",
    };

    public string MaterialTagForUi => Material;

    public void Save()
    {
        try
        {
            _doc["closeToTray"] = CloseToTray;
            _doc["theme"] = Theme;
            _doc["material"] = Material == "none" ? "opaque" : Material;
            Directory.CreateDirectory(Directory_);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, _doc.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception) { /* losing a preference write must not take the window down */ }
    }

    private static bool ReadBool(JsonObject doc, string key, bool fallback)
    {
        try { JsonNode? n = doc[key]; return n is not null && n.GetValue<bool>(); }
        catch (Exception) { return fallback; }
    }

    private static string ReadString(JsonObject doc, string key, string fallback)
    {
        try
        {
            JsonNode? n = doc[key];
            if (n is null) { return fallback; }
            string v = n.GetValue<string>();
            return string.IsNullOrWhiteSpace(v) ? fallback : v;
        }
        catch (Exception) { return fallback; }
    }
}