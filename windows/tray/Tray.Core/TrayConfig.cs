using System.Text.Json;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The Appearance setting: follow Windows, or force light or dark.</summary>
public enum AppearanceMode { System, Light, Dark }

/// <summary>
/// <c>%LOCALAPPDATA%\BenchBar\config.json</c>, shared with the shim. The shim owns <c>distro</c> and <c>cli_path</c>;
/// the tray owns a <c>tray</c> object (<c>appearance</c>, <c>runner</c>, <c>notifications</c>). Save keeps every
/// key it does not know, at the top level and inside <c>tray</c>, and replaces the file atomically.
/// Read with <see cref="JsonNode"/>, so no reflection serializer is needed.
/// </summary>
public sealed class TrayConfig
{
    public const string DefaultRunnerId = "bench";

    private JsonObject _root = new();
    private bool _corrupt;

    private TrayConfig(string path) => Path = path;

    public string Path { get; }

    public static string DefaultPath { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "config.json");

    /// <summary>The shim's <c>distro</c> key; null when absent. The tray only reads it.</summary>
    public string? Distro { get; private set; }

    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;

    public string RunnerId { get; set; } = DefaultRunnerId;

    public bool Notifications { get; set; } = true;

    /// <summary>True when the file existed but was not valid JSON; Save then keeps it as <c>config.json.bad</c> first.</summary>
    public bool WasCorrupt => _corrupt;

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
            return config;
        }

        if (string.IsNullOrWhiteSpace(text)) return config;
        try
        {
            if (JsonNode.Parse(text.TrimStart('﻿')) is JsonObject root) config._root = root;
            else config._corrupt = true;
        }
        catch (JsonException)
        {
            config._corrupt = true;
            return config;
        }

        config.Distro = ReadString(config._root, "distro");
        if (config._root["tray"] is JsonObject tray)
        {
            config.Appearance = ParseAppearance(ReadString(tray, "appearance"));
            config.RunnerId = ReadString(tray, "runner") is { Length: > 0 } id ? id : DefaultRunnerId;
            if (tray["notifications"] is JsonValue v && v.TryGetValue<bool>(out var on)) config.Notifications = on;
        }
        return config;
    }

    /// <summary>Writes the file: a temp file in the same folder, then a move over the old one.</summary>
    public void Save()
    {
        var dir = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        if (_corrupt && File.Exists(Path))
        {
            File.Copy(Path, Path + ".bad", overwrite: true);
            _corrupt = false;
        }

        var tray = _root["tray"] as JsonObject ?? new JsonObject();
        tray["appearance"] = AppearanceText(Appearance);
        tray["runner"] = RunnerId;
        tray["notifications"] = Notifications;
        _root["tray"] = tray;

        var temp = Path + "." + Environment.ProcessId + ".tmp";
        try
        {
            using (var stream = File.Create(temp))
            using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
                _root.WriteTo(writer);
            File.Move(temp, Path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
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
