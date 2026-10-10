using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace BenchBar.Tray.Harness;

/// <summary>Minimal PNG writer (8 bit RGB) so the harness needs no imaging package.</summary>
internal static class Png
{
    private static readonly uint[] CrcTable = BuildTable();

    private static uint[] BuildTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    private static uint Crc(byte[] type, byte[] data)
    {
        uint c = 0xFFFFFFFFu;
        foreach (byte b in type) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        foreach (byte b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }

    private static void Chunk(Stream s, string name, byte[] data)
    {
        byte[] type = Encoding.ASCII.GetBytes(name);
        byte[] buf = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(buf, (uint)data.Length);
        s.Write(buf);
        s.Write(type);
        s.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(buf, Crc(type, data));
        s.Write(buf);
    }

    /// <summary>Writes a top down BGRA buffer as an opaque RGB PNG.</summary>
    public static void WriteBgra(string path, int width, int height, byte[] bgra)
    {
        var raw = new byte[(width * 3 + 1) * height];
        int o = 0;
        for (int y = 0; y < height; y++)
        {
            raw[o++] = 0;
            int i = y * width * 4;
            for (int x = 0; x < width; x++, i += 4)
            {
                raw[o++] = bgra[i + 2];
                raw[o++] = bgra[i + 1];
                raw[o++] = bgra[i];
            }
        }

        using var compressed = new MemoryStream();
        using (var z = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
            z.Write(raw);

        var header = new byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(0), (uint)width);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(4), (uint)height);
        header[8] = 8;
        header[9] = 2;

        using var file = File.Create(path);
        file.Write(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
        Chunk(file, "IHDR", header);
        Chunk(file, "IDAT", compressed.ToArray());
        Chunk(file, "IEND", Array.Empty<byte>());
    }
}
