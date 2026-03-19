using AudioCapture.Interfaces;
using AudioCapture.Storage;

namespace SampleApp.Services;

/// <summary>
/// Demo encryptor with a hardcoded 32-byte key — matches macOS DemoEncryptor.swift.
/// NOT FOR PRODUCTION USE.
/// </summary>
public sealed class DemoEncryptor : ICaptureEncryptor
{
    private static readonly byte[] DemoKey =
    [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    ];

    private readonly AesGcmEncryptor _inner = new(DemoKey);

    public byte[] Encrypt(byte[] data) => _inner.Encrypt(data);

    public Dictionary<string, string> KeyMetadata => new()
    {
        ["keyId"] = "demo-key-v1",
        ["algorithm"] = Algorithm,
        ["warning"] = "DEMO KEY — NOT FOR PRODUCTION",
    };

    public string Algorithm => "AES-256-GCM";
}
