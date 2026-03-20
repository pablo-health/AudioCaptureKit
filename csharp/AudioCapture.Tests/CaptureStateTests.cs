using AudioCapture.Models;
using Xunit;

namespace AudioCapture.Tests;

public class CaptureStateTests
{
    [Theory]
    [InlineData(CaptureStateKind.Idle, CaptureStateKind.Configuring, true)]
    [InlineData(CaptureStateKind.Configuring, CaptureStateKind.Ready, true)]
    [InlineData(CaptureStateKind.Configuring, CaptureStateKind.Failed, true)]
    [InlineData(CaptureStateKind.Ready, CaptureStateKind.Capturing, true)]
    [InlineData(CaptureStateKind.Ready, CaptureStateKind.Failed, true)]
    [InlineData(CaptureStateKind.Capturing, CaptureStateKind.Paused, true)]
    [InlineData(CaptureStateKind.Capturing, CaptureStateKind.Stopping, true)]
    [InlineData(CaptureStateKind.Capturing, CaptureStateKind.Failed, true)]
    [InlineData(CaptureStateKind.Paused, CaptureStateKind.Capturing, true)]
    [InlineData(CaptureStateKind.Paused, CaptureStateKind.Stopping, true)]
    [InlineData(CaptureStateKind.Paused, CaptureStateKind.Failed, true)]
    [InlineData(CaptureStateKind.Stopping, CaptureStateKind.Completed, true)]
    [InlineData(CaptureStateKind.Stopping, CaptureStateKind.Failed, true)]
    [InlineData(CaptureStateKind.Completed, CaptureStateKind.Idle, true)]
    [InlineData(CaptureStateKind.Failed, CaptureStateKind.Idle, true)]
    public void ValidTransitions(CaptureStateKind from, CaptureStateKind to, bool expected)
    {
        var state = CreateState(from);
        Assert.Equal(expected, state.CanTransitionTo(to));
    }

    [Theory]
    [InlineData(CaptureStateKind.Idle, CaptureStateKind.Capturing)]
    [InlineData(CaptureStateKind.Idle, CaptureStateKind.Stopping)]
    [InlineData(CaptureStateKind.Ready, CaptureStateKind.Idle)]
    [InlineData(CaptureStateKind.Capturing, CaptureStateKind.Idle)]
    [InlineData(CaptureStateKind.Capturing, CaptureStateKind.Ready)]
    [InlineData(CaptureStateKind.Completed, CaptureStateKind.Capturing)]
    [InlineData(CaptureStateKind.Failed, CaptureStateKind.Capturing)]
    [InlineData(CaptureStateKind.Stopping, CaptureStateKind.Idle)]
    public void InvalidTransitions(CaptureStateKind from, CaptureStateKind to)
    {
        var state = CreateState(from);
        Assert.False(state.CanTransitionTo(to));
    }

    [Fact]
    public void CapturingState_HasDuration()
    {
        var state = CaptureState.Capturing(TimeSpan.FromSeconds(10));
        Assert.Equal(CaptureStateKind.Capturing, state.Kind);
        Assert.Equal(TimeSpan.FromSeconds(10), state.Duration);
    }

    [Fact]
    public void PausedState_HasDuration()
    {
        var state = CaptureState.Paused(TimeSpan.FromSeconds(5));
        Assert.Equal(CaptureStateKind.Paused, state.Kind);
        Assert.Equal(TimeSpan.FromSeconds(5), state.Duration);
    }

    [Fact]
    public void CompletedState_HasResult()
    {
        var result = new RecordingResult("test.wav", 10.0, null!, "abc", []);
        var state = CaptureState.Completed(result);
        Assert.Equal(CaptureStateKind.Completed, state.Kind);
        Assert.Same(result, state.Result);
    }

    [Fact]
    public void FailedState_HasError()
    {
        var error = CaptureException.DeviceNotAvailable();
        var state = CaptureState.Failed(error);
        Assert.Equal(CaptureStateKind.Failed, state.Kind);
        Assert.Same(error, state.Error);
    }

    private static CaptureState CreateState(CaptureStateKind kind) => kind switch
    {
        CaptureStateKind.Idle => CaptureState.Idle,
        CaptureStateKind.Configuring => CaptureState.Configuring,
        CaptureStateKind.Ready => CaptureState.Ready,
        CaptureStateKind.Capturing => CaptureState.Capturing(TimeSpan.Zero),
        CaptureStateKind.Paused => CaptureState.Paused(TimeSpan.Zero),
        CaptureStateKind.Stopping => CaptureState.Stopping,
        CaptureStateKind.Completed => CaptureState.Completed(new RecordingResult("", 0, null!, "", [])),
        CaptureStateKind.Failed => CaptureState.Failed(CaptureException.Unknown("test")),
        _ => throw new ArgumentOutOfRangeException(),
    };
}
