using System.Text.Json;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The Appearance setting: follow Windows, or force light or dark.</summary>
public enum AppearanceMode { System, Light, Dark }

/// <summary>
/// <c>%LOCALAPPDATA%\BenchBar\config.json</c>, shared with the shim. The shim owns <c>distro</c> and <c>cli_path</c>;
/// the tray owns a <c>tray</c> object (<c>appearance</c>, <c>runner</c>, <c>notifications</c>). Save re-reads the file
/// from disk and replaces only the <c>tray</c> object, so whatever the shim wrote since the tray started
/// (<c>adopt-distro</c> sets <c>distro</c>) is never reverted; the write is atomic. <see cref="Distro"/> is read from
/// the file again whenever its write time changes. Read with <see cref="JsonNode"/>, so no reflection serializer is needed.
/// </summary>
public sealed class TrayConfig
{
    public const string DefaultRunnerId = "bench";

    private bool _corrupt;
    private bool _unreadable;
    private string? _distro;
    private string? _cliPath;
    private (DateTime Written, long Length)? _stamp;
    private readonly object _gate = new();

    private TrayConfig(string path) => Path = path;

    public string Path { get; }

    public static string DefaultPath { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "config.json");

    /// <summary>
    /// The shim's <c>distro</c> key; null when absent. The tray only reads it, and re-reads the file only when its
    /// write time or size changed, so no I/O beyond one stat while it is unchanged.
    /// </summary>
    public string? Distro
    {
        get
        {
            lock (_gate)
            {
                try
                {
                    var info = new FileInfo(Path);
                    (DateTime, long)? stamp = info.Exists ? (info.LastWriteTimeUtc, info.Length) : null;
                    if (stamp == _stamp) return _distro;
                    _stamp = stamp;
                    var root = (stamp is null ? null : ParseRoot(File.ReadAllText(Path))) ?? [];
                    _distro = stamp is null ? null : ReadString(root, "distro");
                    _cliPath = stamp is null ? null : ReadString(root, "cli_path");
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // keep the last known value; try again next time
                    _stamp = null;
                }
                return _distro;
            }
        }
    }

    /// <summary>The shim's <c>cli_path</c> key (the Linux CLI it calls); null when absent. Read only, like <see cref="Distro"/>.</summary>
    public string? CliPath
    {
        get
        {
            _ = Distro; // one read of the file fills both
            lock (_gate) return _cliPath;
        }
    }

    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;

    public string RunnerId { get; set; } = DefaultRunnerId;

    public bool Notifications { get; set; } = true;

    /// <summary>The editor Open in Editor starts: <c>code</c> (VS Code), <c>cursor</c> or <c>insiders</c>.</summary>
    public string Editor { get; set; } = EditorKind.DefaultId;

    /// <summary>Look for a newer release when the BenchBar window opens (once in a few hours). Off: only the menu item asks.</summary>
    public bool CheckForUpdates { get; set; } = true;

    /// <summary>The person closed the first run wizard with Cancel: it no longer opens by itself at launch.</summary>
    public bool WizardDismissed { get; set; }

    /// <summary>The person closed the beta banner at the top of the BenchBar window; it stays away from then on.</summary>
    public bool BetaBannerDismissed { get; set; }

    /// <summary>True when the file existed but was not valid JSON; Save then keeps it as <c>config.json.bad</c> first.</summary>
    public bool WasCorrupt => _corrupt;

    /// <summary>True when the file could not be read at all (locked, no access): Save then refuses to write.</summary>
    public bool Unreadable => _unreadable;

    /// <summary>Reads the file. A missing folder or file, an empty file and a UTF-8 BOM are all fine; bad JSON gives the defaults.</summary>
    public static TrayConfig Load(string? path = null)
    {
        var config = new TrayConfig(path ?? DefaultPath);
        string text;
        try
        {
            if (!File.Exists(config.Path)) return config;
            text = File.ReadAllText(config.Path); // drops a BOM
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            config._unreadable = true;
            return config;
        }

        if (string.IsNullOrWhiteSpace(text)) return config;
        var root = ParseRoot(text);
        if (root is null)
        {
            config._corrupt = true;
            return config;
        }

        if (root["tray"] is JsonObject tray)
        {
            config.Appearance = ParseAppearance(ReadString(tray, "appearance"));
            config.RunnerId = ReadString(tray, "runner") is { Length: > 0 } id ? id : DefaultRunnerId;
            if (tray["notifications"] is JsonValue v && v.TryGetValue<bool>(out var on)) config.Notifications = on;
            config.Editor = EditorKind.Normalize(ReadString(tray, "editor"));
            if (tray["check_for_updates"] is JsonValue u && u.TryGetValue<bool>(out var check)) config.CheckForUpdates = check;
            if (tray["wizard_dismissed"] is JsonValue w && w.TryGetValue<bool>(out var dismissed)) config.WizardDismissed = dismissed;
            if (tray["beta_banner_dismissed"] is JsonValue bb && bb.TryGetValue<bool>(out var betaDismissed)) config.BetaBannerDismissed = betaDismissed;
        }
        return config;
    }

    /// <summary>
    /// Replaces the file with the temp copy. Windows refuses the replace while another process has the target
    /// open without delete sharing (an antivirus scan, the search indexer, the shim reading it), for a moment:
    /// a few short retries instead of losing the write.
    /// </summary>
    private static void ReplaceWithRetry(string temp, string path)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                File.Move(temp, path, overwrite: true);
                return;
            }
            catch (Exception ex) when (attempt < 10 && ex is UnauthorizedAccessException or IOException)
            {
                Thread.Sleep(20 * attempt);
            }
        }
    }

    /// <summary>
    /// Writes the <c>tray</c> object into the file as it is on disk now: a temp file in the same folder, then a move over
    /// the old one. Throws <see cref="IOException"/> without writing when the file cannot be read (the shim's keys would be lost).
    /// </summary>
    public void Save()
    {
        if (_unreadable) throw new IOException("config.json could not be read, so it was not overwritten: " + Path);

        var dir = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        JsonObject root = [];
        if (File.Exists(Path))
        {
            string text;
            try
            {
                text = File.ReadAllText(Path);
            }
            catch (UnauthorizedAccessException ex)
            {
                throw new IOException("config.json could not be read, so it was not overwritten: " + Path, ex);
            }
            if (!string.IsNullOrWhiteSpace(text))
            {
                if (ParseRoot(text) is { } disk) root = disk;
                else File.Copy(Path, Path + ".bad", overwrite: true); // not valid JSON: keep it before it is replaced
            }
        }

        var tray = root["tray"] as JsonObject ?? new JsonObject();
        tray["appearance"] = AppearanceText(Appearance);
        tray["runner"] = RunnerId;
        tray["notifications"] = Notifications;
        tray["editor"] = EditorKind.Normalize(Editor);
        tray["check_for_updates"] = CheckForUpdates;
        tray["wizard_dismissed"] = WizardDismissed;
        tray["beta_banner_dismissed"] = BetaBannerDismissed;
        root["tray"] = tray;

        var temp = Path + "." + Environment.ProcessId + ".tmp";
        try
        {
            using (var stream = File.Create(temp))
            using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
                root.WriteTo(writer);
            ReplaceWithRetry(temp, Path);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
        _corrupt = false;
    }

    /// <summary>The root object, or null when the text is not a JSON object. A duplicate key is invalid JSON here too.</summary>
    private static JsonObject? ParseRoot(string text)
    {
        try
        {
            return JsonStrict.Parse(text.TrimStart('﻿')) as JsonObject;
        }
        catch (Exception ex) when (ex is JsonException or ArgumentException)
        {
            return null;
        }
    }

    public static AppearanceMode ParseAppearance(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "light" => AppearanceMode.Light,
        "dark" => AppearanceMode.Dark,
        _ => AppearanceMode.System,
    };

    public static string AppearanceText(AppearanceMode mode) => mode switch
    {
        AppearanceMode.Light => "light",
        AppearanceMode.Dark => "dark",
        _ => "system",
    };

    private static string? ReadString(JsonObject node, string key) =>
        node[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
}

/// <summary>
/// <see cref="JsonNode.Parse(string, JsonNodeOptions?, JsonDocumentOptions)"/> accepts a duplicate key and only fails
/// later, on first access. This walks the tree once so the failure (an <see cref="ArgumentException"/>) happens here.
/// </summary>
internal static class JsonStrict
{
    public static JsonNode? Parse(string text)
    {
        var node = JsonNode.Parse(text);
        if (node is not null) Touch(node);
        return node;
    }

    private static void Touch(JsonNode node)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var pair in obj)
                {
                    if (pair.Value is not null) Touch(pair.Value);
                }
                break;
            case JsonArray array:
                foreach (var item in array)
                {
                    if (item is not null) Touch(item);
                }
                break;
        }
    }
}
