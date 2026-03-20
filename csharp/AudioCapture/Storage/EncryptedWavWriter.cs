using System.Security.Cryptography;
using AudioCapture.Interfaces;
using AudioCapture.Models;

namespace AudioCapture.Storage;

/// <summary>
/// Writes WAV files with optional AES-256-GCM encryption.
/// Format matches Swift EncryptedFileWriter exactly:
///   [44-byte WAV header (unencrypted)]
///   [Chunk: 4-byte LE length | nonce | ciphertext | tag] ...
/// </summary>
public sealed class EncryptedWavWriter : IDisposable
{
    private readonly string _filePath;
    private readonly ICaptureEncryptor? _encryptor;
    private FileStream? _stream;
    private long _totalBytesWritten;
    private bool _isOpen;

    public EncryptedWavWriter(string filePath, ICaptureEncryptor? encryptor = null)
    {
        _filePath = filePath;
        _encryptor = encryptor;
    }

    public long BytesWritten => _totalBytesWritten;

    /// <summary>
    /// Opens the file and writes a 44-byte WAV header with dataSize=0 (patched on close).
    /// </summary>
    public void Open(CaptureConfiguration config)
    {
        if (_isOpen) return;

        var dir = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        _stream = new FileStream(_filePath, FileMode.Create, FileAccess.Write, FileShare.None);

        var header = GenerateWavHeader(
            sampleRate: (uint)config.SampleRate,
            bitDepth: (ushort)config.BitDepth,
            channels: (ushort)config.Channels,
            dataSize: 0);

        _stream.Write(header);
        _totalBytesWritten = header.Length;
        _isOpen = true;
    }

    /// <summary>
    /// Writes audio data. If encrypted, writes as [4-byte length][sealed box].
    /// </summary>
    public void Write(byte[] data)
    {
        if (!_isOpen || _stream == null)
            throw new CaptureException(CaptureErrorKind.StorageError, "File is not open for writing");

        if (_encryptor != null)
        {
            var encrypted = _encryptor.Encrypt(data);
            var lengthBytes = BitConverter.GetBytes((uint)encrypted.Length);
            if (!BitConverter.IsLittleEndian)
                Array.Reverse(lengthBytes);

            _stream.Write(lengthBytes);
            _stream.Write(encrypted);
            _totalBytesWritten += 4 + encrypted.Length;
        }
        else
        {
            _stream.Write(data);
            _totalBytesWritten += data.Length;
        }
    }

    /// <summary>
    /// Patches the WAV header with correct sizes and computes SHA-256 checksum.
    /// </summary>
    public string Close()
    {
        if (!_isOpen || _stream == null)
            throw new CaptureException(CaptureErrorKind.StorageError, "File is not open");

        var dataSize = _totalBytesWritten - 44;

        // Patch RIFF chunk size at offset 4
        _stream.Seek(4, SeekOrigin.Begin);
        WriteUInt32LE(_stream, (uint)(_totalBytesWritten - 8));

        // Patch data sub-chunk size at offset 40
        _stream.Seek(40, SeekOrigin.Begin);
        WriteUInt32LE(_stream, (uint)dataSize);

        _stream.Flush();
        _stream.Dispose();
        _stream = null;
        _isOpen = false;

        return ComputeChecksum(_filePath);
    }

    public void Dispose()
    {
        if (_isOpen && _stream != null)
        {
            try { Close(); } catch { /* best effort */ }
        }
        _stream?.Dispose();
    }

    /// <summary>
    /// Generates a standard 44-byte WAV header (RIFF/WAVE PCM format).
    /// </summary>
    public static byte[] GenerateWavHeader(uint sampleRate, ushort bitDepth, ushort channels, uint dataSize)
    {
        var header = new byte[44];
        var byteRate = sampleRate * channels * bitDepth / 8u;
        var blockAlign = (ushort)(channels * bitDepth / 8);
        var chunkSize = 36 + dataSize;

        using var ms = new MemoryStream(header);
        using var w = new BinaryWriter(ms);

        // RIFF chunk descriptor
        w.Write("RIFF"u8);
        w.Write(chunkSize);          // offset 4
        w.Write("WAVE"u8);

        // fmt sub-chunk
        w.Write("fmt "u8);
        w.Write(16u);                // sub-chunk size (PCM)
        w.Write((ushort)1);          // audio format (PCM)
        w.Write(channels);           // offset 22
        w.Write(sampleRate);         // offset 24
        w.Write(byteRate);           // offset 28
        w.Write(blockAlign);         // offset 32
        w.Write(bitDepth);           // offset 34

        // data sub-chunk
        w.Write("data"u8);
        w.Write(dataSize);           // offset 40

        return header;
    }

    private static void WriteUInt32LE(Stream stream, uint value)
    {
        Span<byte> buf = stackalloc byte[4];
        BitConverter.TryWriteBytes(buf, value);
        if (!BitConverter.IsLittleEndian)
            buf.Reverse();
        stream.Write(buf);
    }

    private static string ComputeChecksum(string filePath)
    {
        using var stream = File.OpenRead(filePath);
        var hash = SHA256.HashData(stream);
        return Convert.ToHexStringLower(hash);
    }
}
