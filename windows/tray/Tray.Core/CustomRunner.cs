using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>Why a runner folder was rejected, in words for the Runner menu.</summary>
public sealed class RunnerException(string message) : Exception(message);

/// <summary>
/// A runner from a folder of PNG frames and a <c>manifest.json</c> (docs/runners.md, the Mac's format and rules).
/// Frames are decoded when drawn, not kept: the icon cache holds the result.
/// </summary>
public sealed class CustomRunner : IRunnerArt
{
    private readonly Dictionary<RunnerPose, IReadOnlyList<string>> _frames;
    private readonly int _width;
    private readonly int _height;

    internal CustomRunner(
        string id, string name, string? author, bool template,
        Dictionary<RunnerPose, IReadOnlyList<string>> frames, int width, int height)
    {
        Id = id;
        Name = name;
        Author = author;
        IsTemplate = template;
        _frames = frames;
        _width = width;
        _height = height;
    }

    public string Id { get; }
    public string Name { get; }
    public string? Author { get; }
    public bool IsTemplate { get; }

    public int FrameCount(RunnerPose pose) => FramesOf(pose).Count;

    /// <summary>The frame scaled to fit the square slot (aspect kept, centred, high quality). A frame that cannot be read now is blank.</summary>
    public Bitmap Render(RunnerPose pose, int frame, int side)
    {
        var files = FramesOf(pose);
        var path = files[((frame % files.Count) + files.Count) % files.Count];
        var result = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        try
        {
            using var stream = new MemoryStream(File.ReadAllBytes(path));
            using var source = new Bitmap(stream);
            using var g = Graphics.FromImage(result);
            g.Clear(Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;

            var scale = Math.Min((float)side / _width, (float)side / _height);
            var w = _width * scale;
            var h = _height * scale;
            var target = new RectangleF((side - w) / 2f, (side - h) / 2f, w, h);
            using var attributes = new ImageAttributes();
            attributes.SetWrapMode(WrapMode.TileFlipXY); // no halo at the edges
            g.DrawImage(source, Rectangle.Round(target), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or ExternalException)
        {
            // the file changed or vanished after it was checked: show nothing for this frame
        }
        return result;
    }

    private IReadOnlyList<string> FramesOf(RunnerPose pose) =>
        _frames.TryGetValue(pose, out var own) ? own : _frames[RunnerPose.Running];
}

/// <summary>
/// Loads and validates a runner folder. Strict on purpose: a runner comes from someone else.
/// The rules are the Mac's (RunnerLoader in macos/BenchBar/Runners/RunnerPackage.swift) plus Windows ones
/// (device names such as CON, no reparse points).
/// </summary>
public static class RunnerLoader
{
    public const int PixelHeight = 36;
    public const int MinWidth = 10;
    public const int MaxWidth = 100;
    public const int MaxFrames = 30;
    public const int MaxBytes = 2 * 1024 * 1024;
    public const int MaxManifestBytes = 64 * 1024;
    public const string ManifestName = "manifest.json";

    private static readonly string[] PoseNames = ["sleeping", "starting", "running", "crashed", "alert", "unknown"];

    private static readonly HashSet<string> DeviceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>Loads the runner in <paramref name="folder"/>, or throws a <see cref="RunnerException"/> that says which rule broke.</summary>
    public static CustomRunner Load(string folder, string id)
    {
        if (BuiltInRunners.IsReserved(id))
            throw new RunnerException($"\"{id}\" is the name of a built in runner. Rename the folder.");
        if (IsReparsePoint(folder))
            throw new RunnerException("The runner folder is a link; links are not allowed.");

        // the folder first: no link is followed and nothing is read before the size and reparse rules hold
        CheckFolder(folder);
        var manifest = ReadManifest(folder);
        CheckStates(manifest);

        var frames = new Dictionary<RunnerPose, IReadOnlyList<string>>();
        (int Width, int Height)? size = null;
        foreach (var pose in Enum.GetValues<RunnerPose>())
        {
            if (!manifest.States.TryGetValue(PoseKey(pose), out var names)) continue;
            var files = new List<string>();
            foreach (var name in names)
            {
                var path = Path.Combine(folder, name);
                var (width, height) = CheckPng(path, name);
                if (size is { } first && first != (width, height)) throw new RunnerException($"{name} is not the same size as the other frames.");
                size = (width, height);
                files.Add(path);
            }
            frames[pose] = Order(files, manifest.PingPong);
        }
        var (w, h) = size ?? (PixelHeight, PixelHeight);
        return new CustomRunner(id, manifest.Name, manifest.Author, manifest.Template, frames, w, h);
    }

    internal static string PoseKey(RunnerPose pose) => pose.ToString().ToLowerInvariant();

    private sealed record Manifest(string Name, string? Author, bool Template, Dictionary<string, List<string>> States, bool PingPong);

    private static Manifest ReadManifest(string folder)
    {
        var path = Path.Combine(folder, ManifestName);
        if (!File.Exists(path)) throw new RunnerException("There is no manifest.json in the runner folder.");
        // the size is checked before a single byte is read
        if (new FileInfo(path).Length > MaxManifestBytes) throw new RunnerException("manifest.json could not be read: it is larger than 64 KB.");
        var bytes = File.ReadAllBytes(path);

        JsonObject root;
        try
        {
            var text = new UTF8Encoding(false).GetString(bytes).TrimStart('﻿');
            root = JsonStrict.Parse(text) as JsonObject ?? throw new RunnerException("manifest.json could not be read: it is not a JSON object.");
        }
        catch (Exception ex) when (ex is JsonException or ArgumentException)
        {
            // ArgumentException: a duplicate key
            throw new RunnerException("manifest.json could not be read: it is not valid JSON.");
        }

        var name = (RequiredString(root, "name") ?? "").Trim();
        if (name.Length is < 1 or > 40) throw new RunnerException("manifest.json could not be read: \"name\" must be 1 to 40 characters.");
        var author = root.ContainsKey("author") && root["author"] is not null ? RequiredString(root, "author") : null;
        if (!root.ContainsKey("template")) throw new RunnerException("manifest.json could not be read: \"template\" is missing.");
        if (root["template"] is not JsonValue t || !t.TryGetValue<bool>(out var template))
            throw new RunnerException("manifest.json could not be read: \"template\" has the wrong type.");

        var order = root["frame_order"] is null ? "forward" : RequiredString(root, "frame_order");
        if (order is not ("forward" or "ping_pong"))
            throw new RunnerException("manifest.json could not be read: \"frame_order\" must be forward or ping_pong.");

        if (!root.ContainsKey("states")) throw new RunnerException("manifest.json could not be read: \"states\" is missing.");
        if (root["states"] is not JsonObject statesNode)
            throw new RunnerException("manifest.json could not be read: \"states\" has the wrong type.");
        var states = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var (key, value) in statesNode)
        {
            if (value is not JsonArray array) throw new RunnerException($"manifest.json could not be read: \"states.{key}\" has the wrong type.");
            var list = new List<string>();
            foreach (var item in array)
            {
                if (item is not JsonValue v || !v.TryGetValue<string>(out var s))
                    throw new RunnerException($"manifest.json could not be read: \"states.{key}\" has the wrong type.");
                list.Add(s);
            }
            states[key] = list;
        }
        return new Manifest(name, author, template, states, order == "ping_pong");
    }

    private static string? RequiredString(JsonObject node, string key)
    {
        if (!node.ContainsKey(key) || node[key] is null) throw new RunnerException($"manifest.json could not be read: \"{key}\" is missing.");
        return node[key] is JsonValue v && v.TryGetValue<string>(out var s)
            ? s
            : throw new RunnerException($"manifest.json could not be read: \"{key}\" has the wrong type.");
    }

    private static void CheckStates(Manifest manifest)
    {
        foreach (var key in manifest.States.Keys)
        {
            if (!PoseNames.Contains(key))
                throw new RunnerException($"\"{key}\" is not a state. Use sleeping, starting, running, crashed, alert or unknown.");
        }
        if (!manifest.States.TryGetValue("running", out var running) || running.Count == 0)
            throw new RunnerException("The running state is required: every other state falls back to it.");
        foreach (var pose in PoseNames)
        {
            if (!manifest.States.TryGetValue(pose, out var names)) continue;
            if (names.Count == 0) throw new RunnerException($"The {pose} state lists no frames. Leave it out instead.");
            if (names.Count > MaxFrames) throw new RunnerException($"The {pose} state has {names.Count} frames; the limit is {MaxFrames}.");
            foreach (var name in names)
            {
                if (!IsSafeFileName(name))
                    throw new RunnerException($"\"{name}\" is not an allowed frame name: use a plain .png file name, no folders.");
            }
        }
    }

    /// <summary>A plain file name ending in .png: no folders, no "..", not hidden, no control characters, no device names.</summary>
    public static bool IsSafeFileName(string name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 100) return false;
        if (name.StartsWith('.') || !name.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return false;
        if (name.Any(c => c is '/' or '\\' or ':' or '<' or '>' or '"' or '|' or '?' or '*' || char.IsControl(c))) return false;
        var stem = name[..name.IndexOf('.')];
        return !DeviceNames.Contains(stem);
    }

    /// <summary>At most 2 MB over the whole folder, and no link anywhere in it.</summary>
    private static void CheckFolder(string folder)
    {
        long total = 0;
        var pending = new Stack<string>();
        pending.Push(folder);
        while (pending.Count > 0)
        {
            foreach (var entry in new DirectoryInfo(pending.Pop()).EnumerateFileSystemInfos())
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    throw new RunnerException($"\"{entry.Name}\" is a link; links are not allowed.");
                if (entry is DirectoryInfo dir) pending.Push(dir.FullName);
                else if (entry is FileInfo file) total += file.Length;
            }
        }
        if (total > MaxBytes) throw new RunnerException($"The runner is {total / 1024} KB; the limit is {MaxBytes / 1024 / 1024} MB.");
    }

    private static (int Width, int Height) CheckPng(string path, string name)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.Directory) || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new RunnerException($"{name} is listed in manifest.json but is not in the folder.");
        try
        {
            using var stream = new MemoryStream(File.ReadAllBytes(path));
            using var image = Image.FromStream(stream);
            if (image.RawFormat.Guid != ImageFormat.Png.Guid) throw new RunnerException($"{name} is not a PNG image.");
            if (image.Height != PixelHeight || image.Width is < MinWidth or > MaxWidth)
                throw new RunnerException($"{name} is {image.Width} x {image.Height} px; frames must be {PixelHeight} px tall and {MinWidth} to {MaxWidth} px wide.");
            return (image.Width, image.Height);
        }
        catch (Exception ex) when (ex is ArgumentException or OutOfMemoryException or ExternalException)
        {
            throw new RunnerException($"{name} is not a PNG image.");
        }
    }

    /// <summary>Forward: 1 2 3. Ping pong: 1 2 3 2, a back and forth loop from fewer frames.</summary>
    internal static IReadOnlyList<string> Order(List<string> files, bool pingPong) =>
        pingPong && files.Count > 2 ? [.. files, .. files.Skip(1).Take(files.Count - 2).Reverse()] : files;

    /// <summary>The folder name as an id: lower case, anything but letters, digits, <c>.</c>, <c>-</c> and <c>_</c> turned into <c>-</c>.</summary>
    public static string IdFor(string folderName) =>
        new(folderName.ToLowerInvariant().Select(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_' ? c : '-').ToArray());

    private static bool IsReparsePoint(string path) =>
        new DirectoryInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint);
}
