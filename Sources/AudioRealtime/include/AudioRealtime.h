#pragma once
#include <CoreAudio/CoreAudio.h>

typedef struct ULGainState ULGainState;
ULGainState * _Nullable ULGainCreate(float initialGain, double sampleRate);
void ULGainDestroy(ULGainState * _Nullable state);
void ULGainSet(ULGainState * _Nonnull state, float gain);
void ULGainRender(ULGainState * _Nullable state, const AudioBufferList * _Nullable input,
    AudioBufferList * _Nonnull output);
OSStatus ULGainIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context);
