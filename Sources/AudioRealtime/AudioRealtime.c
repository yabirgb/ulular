#include "AudioRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct MTGainState {
    _Atomic(float) target;
    float current;
    float step;
};

static float clampGain(float gain) {
    return isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 0;
}

MTGainState *MTGainCreate(float gain, double sampleRate) {
    MTGainState *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    atomic_init(&state->target, clampGain(gain));
    // Never start louder than requested. Ramp up from silence to avoid a start click.
    state->current = 0;
    state->step = 1.0f / (float)(fmax(1, sampleRate * 0.005));
    if (!atomic_is_lock_free(&state->target)) { free(state); return NULL; }
    return state;
}

void MTGainDestroy(MTGainState *state) { free(state); }
void MTGainSet(MTGainState *state, float gain) {
    atomic_store_explicit(&state->target, clampGain(gain), memory_order_relaxed);
}

// Supports stereo float32, interleaved or planar. No allocation, locks, or logging
// on the audio thread. Missing input is silence, never stale output memory.
void MTGainRender(MTGainState *state, const AudioBufferList *input, AudioBufferList *output) {
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        if (output->mBuffers[b].mData)
            memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    if (!state || !input) return;
    const float *source[2] = {0};
    UInt32 stride[2] = {0}, frames[2] = {0};
    UInt32 channel = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers && channel < 2; b++) {
        AudioBuffer buffer = input->mBuffers[b];
        for (UInt32 c = 0; c < buffer.mNumberChannels && channel < 2; c++, channel++) {
            if (buffer.mData) source[channel] = (const float *)buffer.mData + c;
            stride[channel] = buffer.mNumberChannels;
            frames[channel] = buffer.mNumberChannels ? buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels) : 0;
        }
    }
    float *destination[2] = {0};
    UInt32 outStride[2] = {0}, outFrames[2] = {0};
    channel = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers && channel < 2; b++) {
        AudioBuffer buffer = output->mBuffers[b];
        for (UInt32 c = 0; c < buffer.mNumberChannels && channel < 2; c++, channel++) {
            if (buffer.mData) destination[channel] = (float *)buffer.mData + c;
            outStride[channel] = buffer.mNumberChannels;
            outFrames[channel] = buffer.mNumberChannels ? buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels) : 0;
        }
    }
    float target = atomic_load_explicit(&state->target, memory_order_relaxed);
    UInt32 count = outFrames[0] > outFrames[1] ? outFrames[0] : outFrames[1];
    for (UInt32 frame = 0; frame < count; frame++) {
        float delta = target - state->current;
        state->current += fminf(state->step, fmaxf(-state->step, delta));
        for (UInt32 c = 0; c < 2; c++) {
            if (source[c] && destination[c] && frame < frames[c] && frame < outFrames[c])
                destination[c][frame * outStride[c]] = source[c][frame * stride[c]] * state->current;
        }
    }
}

OSStatus MTGainIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    MTGainRender(context, input, output);
    return noErr;
}
