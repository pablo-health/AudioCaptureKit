using System.Text.Json.Serialization;

namespace AudioCapture.Models;

/// <summary>
/// Metadata persisted alongside a recording. Serializable to JSON.
/// </summary>
public sealed record RecordingMetadata(
    Guid Id,
    double DurationSecs,
    string FilePath,
    string Checksum,
    bool IsEncrypted,
    DateTime CreatedAt,
    AudioTrack[] Tracks,
    string? EncryptionAlgorithm,
    string? EncryptionKeyId,
    ChannelLayout ChannelLayout)
{
    [JsonPropertyName("id")]
    public Guid Id { get; init; } = Id;

    [JsonPropertyName("duration_secs")]
    public double DurationSecs { get; init; } = DurationSecs;

    [JsonPropertyName("file_path")]
    public string FilePath { get; init; } = FilePath;

    [JsonPropertyName("checksum")]
    public string Checksum { get; init; } = Checksum;

    [JsonPropertyName("is_encrypted")]
    public bool IsEncrypted { get; init; } = IsEncrypted;

    [JsonPropertyName("created_at")]
    public DateTime CreatedAt { get; init; } = CreatedAt;

    [JsonPropertyName("tracks")]
    public AudioTrack[] Tracks { get; init; } = Tracks;

    [JsonPropertyName("encryption_algorithm")]
    public string? EncryptionAlgorithm { get; init; } = EncryptionAlgorithm;

    [JsonPropertyName("encryption_key_id")]
    public string? EncryptionKeyId { get; init; } = EncryptionKeyId;

    [JsonPropertyName("channel_layout")]
    public ChannelLayout ChannelLayout { get; init; } = ChannelLayout;
}
