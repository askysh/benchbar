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
                    _distro = stamp is null ? null : ReadString(ParseRoot(File.ReadAllText(Path)) ?? [], "distro");
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

    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;

    public string RunnerId { get; set; } = DefaultRunnerId;

    public bool Notifications { get; set; } = true;

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
