using AudioCapture.Interfaces;
using AudioCapture.Models;

namespace AudioCapture.Storage;

/// <summary>
/// Writes one sidecar stream: an opaque sequence of payload chunks, either as-is or,
/// with an encryptor, framed as <c>[4-byte LE length][nonce|ciphertext|tag]</c> per
/// chunk (the same framing the mixed WAV uses and the macOS writer produces).
///
/// <para><b>Format-agnostic by design.</b> The writer knows nothing about PCM, sample
/// rates or channel counts. Whatever the caller hands it — raw PCM today, a
/// self-framing compressed payload tomorrow — is written as a chunk. Anything that
/// changes the <i>audio</i> (padding, resampling) belongs upstream, in the sample
/// domain, before the bytes reach this class.</para>
///
/// <para><b>Append.</b> Because every encrypted chunk is self-delimiting and sealed
/// with its own nonce, two writers that append to the same file one after the other
/// produce a single stream a reader decrypts end to end. Opening for append first
/// repairs a torn tail — a final chunk cut short by a crash or a killed process —
/// by truncating back to the last complete frame, so the new chunks start on a frame
/// boundary instead of inheriting a desynced length prefix.</para>
///
/// <para><b>Threading.</b> Writes and close are serialized internally; a write after
/// close is a silent no-op, which is what lets a capture callback that races a stop
/// drop its last chunk instead of writing into a disposed stream.</para>
/// </summary>
public sealed class SidecarStreamWriter : IDisposable
{
    // AES-GCM nonce + tag. A frame shorter than this cannot be a sealed chunk.
    private const int MinSealedFrameLength = 12 + 16;

    private readonly object _lock = new();
    private readonly ICaptureEncryptor? _encryptor;
    private FileStream? _stream;
    private bool _closed;

    /// <summary>The file this writer appends to or created.</summary>
    public string FilePath { get; }

    /// <summary>Bytes this writer put on disk (framing included), excluding any pre-existing content.</summary>
    public long BytesWritten
    {
        get { lock (_lock) return _bytesWritten; }
    }

    /// <summary>Bytes discarded from a torn tail when the file was opened for append.</summary>
    public long RepairedTailBytes { get; }

    private long _bytesWritten;

    /// <param name="filePath">Sidecar path.</param>
    /// <param name="encryptor">Seals each chunk when set; plaintext chunks are written raw otherwise.</param>
    /// <param name="append">
    /// Continue an existing file instead of truncating it. A missing file is created.
    /// </param>
    /// <param name="plaintextAlignment">
    /// Plaintext only: the unit an appended file must end on (e.g. the PCM block align),
    /// so a torn trailing partial unit is dropped before appending. The writer does not
    /// interpret the bytes; the caller states the unit. 1 disables the repair.
    /// </param>
    public SidecarStreamWriter(
        string filePath,
        ICaptureEncryptor? encryptor = null,
        bool append = false,
        int plaintextAlignment = 1)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(plaintextAlignment);

        FilePath = filePath;
        _encryptor = encryptor;

        var dir = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        if (append && File.Exists(filePath))
        {
            _stream = new FileStream(filePath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
            var validLength = encryptor != null
                ? FindLastCompleteFrameEnd(_stream)
                : _stream.Length - (_stream.Length % plaintextAlignment);
            RepairedTailBytes = _stream.Length - validLength;
            if (RepairedTailBytes > 0)
                _stream.SetLength(validLength);
            _stream.Seek(0, SeekOrigin.End);
        }
        else
        {
            _stream = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.Read);
        }
    }

    /// <summary>Writes one chunk. Encrypted output lands as a single frame or not at all.</summary>
    public void Write(ReadOnlySpan<byte> payload)
    {
        if (payload.IsEmpty) return;

        if (_encryptor != null)
        {
            // Seal outside the lock — it is the slow part and touches no stream.
            var sealedChunk = _encryptor.Encrypt(payload.ToArray());
            Span<byte> lengthBytes = stackalloc byte[4];
            BitConverter.TryWriteBytes(lengthBytes, (uint)sealedChunk.Length);
            if (!BitConverter.IsLittleEndian)
                lengthBytes.Reverse();

            lock (_lock)
            {
                if (_closed || _stream == null) return;
                _stream.Write(lengthBytes);
                _stream.Write(sealedChunk);
                _bytesWritten += 4 + sealedChunk.Length;
            }
        }
        else
        {
            lock (_lock)
            {
                if (_closed || _stream == null) return;
                _stream.Write(payload);
                _bytesWritten += payload.Length;
            }
        }
    }

    /// <summary>Flushes and closes the file. Later writes are ignored.</summary>
    public void Close()
    {
        lock (_lock)
        {
            if (_closed) return;
            _closed = true;
            try
            {
                _stream?.Flush();
            }
            finally
            {
                _stream?.Dispose();
                _stream = null;
            }
        }
    }

    public void Dispose() => Close();

    /// <summary>
    /// Walks the length prefixes from the start and returns the offset just past the
    /// last frame that is fully present. Anything after it is a torn write.
    /// </summary>
    private static long FindLastCompleteFrameEnd(FileStream stream)
    {
        var length = stream.Length;
        long offset = 0;
        Span<byte> prefix = stackalloc byte[4];

        stream.Seek(0, SeekOrigin.Begin);
        while (offset + 4 <= length)
        {
            stream.ReadExactly(prefix);
            if (!BitConverter.IsLittleEndian)
                prefix.Reverse();
            var frameLength = BitConverter.ToUInt32(prefix);

            if (frameLength < MinSealedFrameLength || offset + 4 + frameLength > length)
                break;

            offset += 4 + frameLength;
            stream.Seek(offset, SeekOrigin.Begin);
        }
        return offset;
    }

    /// <summary>
    /// Reads an encrypted sidecar back as one plaintext stream, decrypting each frame
    /// in order. Throws <see cref="CaptureException"/> on a torn or undecryptable frame.
    /// </summary>
    /// <param name="filePath">An encrypted sidecar.</param>
    /// <param name="decrypt">Opens one sealed frame (<c>nonce|ciphertext|tag</c>).</param>
    public static byte[] ReadEncrypted(string filePath, Func<byte[], byte[]> decrypt)
    {
        ArgumentNullException.ThrowIfNull(decrypt);
        var bytes = File.ReadAllBytes(filePath);
        using var output = new MemoryStream();
        var offset = 0;
        while (offset < bytes.Length)
        {
            if (offset + 4 > bytes.Length)
                throw CaptureException.StorageError($"Torn length prefix at offset {offset}");
            var frameLength = (int)BitConverter.ToUInt32(bytes, offset);
            offset += 4;
            if (frameLength < MinSealedFrameLength || offset + frameLength > bytes.Length)
                throw CaptureException.StorageError($"Torn frame at offset {offset - 4}");
            output.Write(decrypt(bytes[offset..(offset + frameLength)]));
            offset += frameLength;
        }
        return output.ToArray();
    }
}
