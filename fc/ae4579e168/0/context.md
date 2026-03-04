# Session Context

## User Prompts

### Prompt 1

Implement the following plan:

# Channel-Based Diarization Support

## Context

AudioCaptureKit captures mic (local speaker) and system audio (remote participants) but currently **mixes the mic into both stereo channels** (`Left = mic + system_L`, `Right = mic + system_R`). This makes downstream speaker diarization difficult: to run independent processing per speaker, you need access to clean channel-separated audio.

This feature adds:
1. A new delegate callback exposing **raw, full-quality ...

