#pragma once
#include <CoreAudio/CoreAudio.h>

typedef struct MTGainState MTGainState;
MTGainState * _Nullable MTGainCreate(float initialGain, double sampleRate);
void MTGainDestroy(MTGainState * _Nullable state);
void MTGainSet(MTGainState * _Nonnull state, float gain);
void MTGainRender(MTGainState * _Nullable state, const AudioBufferList * _Nullable input,
    AudioBufferList * _Nonnull output);
OSStatus MTGainIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context);
