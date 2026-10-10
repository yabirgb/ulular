#include "AudioRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct ULGainState {
    _Atomic(float) target;
    float current;
    float step;
};

static float clampGain(float gain) {
    return isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 0;
}

ULGainState *ULGainCreate(float gain, double sampleRate) {
    ULGainState *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    atomic_init(&state->target, clampGain(gain));
    // Never start louder than requested. Ramp up from silence to avoid a start click.
    state->current = 0;
    state->step = 1.0f / (float)(fmax(1, sampleRate * 0.005));
    if (!atomic_is_lock_free(&state->target)) { free(state); return NULL; }
    return state;
}

void ULGainDestroy(ULGainState *state) { free(state); }
void ULGainSet(ULGainState *state, float gain) {
    atomic_store_explicit(&state->target, clampGain(gain), memory_order_relaxed);
}

// Zeroes only the output the gain pass did not write: tail frames, channels without
// input, channels beyond the first two, and any trailing partial-frame bytes.
static void zeroUncovered(AudioBufferList *output, const UInt32 covered[2]) {
    UInt32 channel = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer buffer = output->mBuffers[b];
        UInt32 n = buffer.mNumberChannels;
        if (!buffer.mData) { channel += n; continue; }
        if (n == 0) { memset(buffer.mData, 0, buffer.mDataByteSize); continue; }
        UInt32 frameBytes = (UInt32)(sizeof(float) * n);
        UInt32 frames = buffer.mDataByteSize / frameBytes;
        UInt32 first = 0, last = 0;
        for (UInt32 c = 0; c < n; c++) {
            UInt32 slot = channel + c;
            UInt32 s = slot < 2 ? covered[slot] : 0;
            if (c == 0) first = last = s;
            if (s < first) first = s;
            if (s > last) last = s;
        }
        char *bytes = (char *)buffer.mData;
        if (first == last) {
            size_t offset = (size_t)first * frameBytes;
            if (offset < buffer.mDataByteSize) memset(bytes + offset, 0, buffer.mDataByteSize - offset);
        } else {
            float *samples = (float *)buffer.mData;
            for (UInt32 c = 0; c < n; c++) {
                UInt32 slot = channel + c;
                UInt32 s = slot < 2 ? covered[slot] : 0;
                for (UInt32 frame = s; frame < frames; frame++) samples[(size_t)frame * n + c] = 0;
            }
            size_t used = (size_t)frames * frameBytes;
            if (used < buffer.mDataByteSize) memset(bytes + used, 0, buffer.mDataByteSize - used);
        }
        channel += n;
    }
}

// Supports stereo float32, interleaved or planar. No allocation, locks, or logging
// on the audio thread. Missing input is silence, never stale output memory.
// Every output byte is written exactly once: gain-scaled samples where input exists,
// zeros everywhere else.
void ULGainRender(ULGainState *state, const AudioBufferList *input, AudioBufferList *output) {
    const float *source[2] = {0};
    UInt32 stride[2] = {0}, frames[2] = {0};
    UInt32 channel = 0;
    for (UInt32 b = 0; input && b < input->mNumberBuffers && channel < 2; b++) {
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
    // Frames each channel can actually write: the shorter of input and output.
    UInt32 covered[2] = {0};
    if (state && input) {
        for (UInt32 c = 0; c < 2; c++) {
            if (source[c] && destination[c]) covered[c] = frames[c] < outFrames[c] ? frames[c] : outFrames[c];
        }
    }
    if (state && input) {
        float target = atomic_load_explicit(&state->target, memory_order_relaxed);
        float current = state->current, step = state->step;
        UInt32 count = outFrames[0] > outFrames[1] ? outFrames[0] : outFrames[1];
        UInt32 common = covered[0] < covered[1] ? covered[0] : covered[1];
        const float *s0 = source[0], *s1 = source[1];
        float *d0 = destination[0], *d1 = destination[1];
        UInt32 is0 = stride[0], is1 = stride[1], os0 = outStride[0], os1 = outStride[1];
        UInt32 frame = 0;
        // Both channels present: no per-sample bounds checks.
        for (; frame < common; frame++) {
            current += fminf(step, fmaxf(-step, target - current));
            d0[(size_t)frame * os0] = s0[(size_t)frame * is0] * current;
            d1[(size_t)frame * os1] = s1[(size_t)frame * is1] * current;
        }
        // Remainder: the ramp keeps advancing while at most one channel still has data.
        for (; frame < count; frame++) {
            current += fminf(step, fmaxf(-step, target - current));
            if (frame < covered[0]) d0[(size_t)frame * os0] = s0[(size_t)frame * is0] * current;
            if (frame < covered[1]) d1[(size_t)frame * os1] = s1[(size_t)frame * is1] * current;
        }
        state->current = current;
    }
    zeroUncovered(output, covered);
}

OSStatus ULGainIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    ULGainRender(context, input, output);
    return noErr;
}
