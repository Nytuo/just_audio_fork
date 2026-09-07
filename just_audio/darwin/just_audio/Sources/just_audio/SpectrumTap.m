#import "./include/just_audio/SpectrumTap.h"
#import <Accelerate/Accelerate.h>
#import <MediaToolbox/MediaToolbox.h>
#import <os/log.h>
#import <stdatomic.h>
#import <math.h>
#import <string.h>

// Power of two, and the same window the Android side captures, so both platforms
// hand Dart comparable resolution.
#define kFFTSize 1024
#define kLog2N 10
#define kBinCount (kFFTSize / 2)

// The audio thread produces frames at sampleRate / kFFTSize (~43 Hz at 44.1 kHz).
// Nothing redraws faster than the display, so the publisher just samples whatever
// the newest one is.
#define kPublishHz 60

// Must match the Dart-side darwinEqualizerCenterFrequencies list exactly (same
// order, same count) — this native array is the only place these frequencies
// take effect; the Dart list only describes them to the UI.
static const double kEQCenterFrequencies[] = {
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
};
#define kEQBandCount ((int)(sizeof(kEQCenterFrequencies) / sizeof(kEQCenterFrequencies[0])))
#define kEQQ 1.0
// vDSP_biquad requires a delay buffer of 2*sections+2 floats per channel.
#define kEQDelayLength (2 * kEQBandCount + 2)
// Provisioned generously above stereo; anything beyond this many channels in
// a single buffer list silently skips equalization for the extra channels.
#define kEQMaxChannels 8

static os_log_t spectrumLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.ryanheise.just_audio", "spectrum");
    });
    return log;
}

@implementation SpectrumTap {
    BetterEventChannel *_channel;
    MTAudioProcessingTapRef _tap;
    __weak AVPlayerItem *_item;
    // Generation of the newest attach attempt, so an async track load that lands
    // after a newer attempt started knows it is stale.
    NSUInteger _generation;

    FFTSetup _fftSetup;
    float *_window;
    float *_windowed;
    float *_real;
    float *_imag;
    float *_magnitudes;

    // Samples accumulate here until there are enough for one transform.
    float *_pending;
    int _pendingCount;

    // Seqlock: the audio thread writes the newest magnitudes into _snapshot and
    // bumps _snapshotSeq on either side of the write (odd while writing); the
    // publisher copies them out on the main queue and retries if the sequence
    // moved under it. Lets the realtime thread hand a frame over without
    // allocating, locking, or enqueueing work.
    float *_snapshot;
    atomic_uint _snapshotSeq;
    atomic_int _snapshotSampleRate;
    unsigned int _publishedSeq;

    dispatch_source_t _publishTimer;
    float *_publishBuffer;

    double _sampleRate;

    // Equalizer state. The realtime thread only ever atomically loads
    // _eqEnabled/_eqSetup and reads/writes _eqDelay (which it alone touches);
    // every other equalizer ivar is written from whichever thread the
    // platform channel call lands on (never the audio thread).
    atomic_bool _eqEnabled;
    float _eqBandGains[kEQBandCount];
    _Atomic(vDSP_biquad_Setup) _eqSetup;
    float *_eqDelay[kEQMaxChannels];
}

- (instancetype)initWithEventChannel:(BetterEventChannel *)channel {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _channel = channel;
    _sampleRate = 44100;

    _fftSetup = vDSP_create_fftsetup(kLog2N, kFFTRadix2);
    _window = calloc(kFFTSize, sizeof(float));
    _windowed = calloc(kFFTSize, sizeof(float));
    _real = calloc(kBinCount, sizeof(float));
    _imag = calloc(kBinCount, sizeof(float));
    _magnitudes = calloc(kBinCount, sizeof(float));
    _pending = calloc(kFFTSize, sizeof(float));
    _snapshot = calloc(kBinCount, sizeof(float));
    _publishBuffer = calloc(kBinCount, sizeof(float));
    _pendingCount = 0;
    _publishedSeq = 0;
    atomic_init(&_snapshotSeq, 0);
    atomic_init(&_snapshotSampleRate, 44100);

    vDSP_hann_window(_window, kFFTSize, vDSP_HANN_NORM);

    atomic_init(&_eqEnabled, false);
    memset(_eqBandGains, 0, sizeof(_eqBandGains));
    atomic_init(&_eqSetup, (vDSP_biquad_Setup)NULL);
    for (int i = 0; i < kEQMaxChannels; i++) {
        _eqDelay[i] = calloc(kEQDelayLength, sizeof(float));
    }
    return self;
}

- (void)dispose {
    [self detach];
    [self stopPublishing];
    if (_fftSetup) {
        vDSP_destroy_fftsetup(_fftSetup);
        _fftSetup = NULL;
    }
    free(_window);
    free(_windowed);
    free(_real);
    free(_imag);
    free(_magnitudes);
    free(_pending);
    free(_snapshot);
    free(_publishBuffer);
    _window = _windowed = _real = _imag = _magnitudes = _pending = NULL;
    _snapshot = _publishBuffer = NULL;

    vDSP_biquad_Setup setup = atomic_load_explicit(&_eqSetup, memory_order_acquire);
    if (setup) {
        vDSP_biquad_DestroySetup(setup);
        atomic_store_explicit(&_eqSetup, (vDSP_biquad_Setup)NULL, memory_order_release);
    }
    for (int i = 0; i < kEQMaxChannels; i++) {
        free(_eqDelay[i]);
        _eqDelay[i] = NULL;
    }
}

- (void)dealloc {
    [self dispose];
}

- (void)detach {
    [self stopPublishing];
    AVPlayerItem *item = _item;
    if (item) item.audioMix = nil;
    _item = nil;
    if (_tap) {
        CFRelease(_tap);
        _tap = NULL;
    }
}

- (void)attachToItem:(AVPlayerItem *)item {
    // The mix is already live on this very item; reinstalling would only drop
    // frames.
    if (!item || item == _item) return;

    const NSUInteger generation = ++_generation;

    // Loading an asset's tracks reaches out to the network, so it must never be
    // asked for synchronously: -tracksWithMediaType: would block whatever thread
    // we are on, and we are called from KVO on the main thread.
    AVAsset *asset = item.asset;
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            // A newer attach superseded this one while the tracks were loading.
            if (self->_generation != generation) return;

            NSError *error = nil;
            if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) {
                os_log_info(spectrumLog(), "tracks did not load: %{public}@", error);
                return;
            }

            // No audio track to hang a mix off. Either this is an HLS asset, where a
            // mix cannot attach at all, or a remote file whose tracks are not known
            // yet — in which case the readyToPlay KVO drives another attach later.
            // _item stays nil so that retry is not mistaken for an install.
            AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            if (!track) {
                os_log_info(spectrumLog(), "no audio track yet; waiting for a later attach");
                return;
            }

            [self installTapForTrack:track onItem:item];
        });
    }];
}

- (void)installTapForTrack:(AVAssetTrack *)track onItem:(AVPlayerItem *)item {
    [self detach];

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge void *)self;
    callbacks.init = tapInit;
    callbacks.finalize = tapFinalize;
    callbacks.prepare = tapPrepare;
    callbacks.unprepare = tapUnprepare;
    callbacks.process = tapProcess;

    MTAudioProcessingTapRef tap;
    OSStatus status = MTAudioProcessingTapCreate(
        kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    if (status != noErr) {
        os_log_error(spectrumLog(), "could not create tap (%d)", (int)status);
        return;
    }

    AVMutableAudioMixInputParameters *params =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    params.audioTapProcessor = tap;

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;

    _tap = tap;
    _item = item;
    os_log_info(spectrumLog(), "tap installed on track %d", (int)track.trackID);

    [self startPublishing];
}

#pragma mark - Publishing

/// Ships whatever the audio thread produced most recently, up to kPublishHz times
/// a second, from the main queue. The realtime thread never touches the channel,
/// never allocates, and never enqueues work of its own.
- (void)startPublishing {
    if (_publishTimer) return;

    _publishTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_publishTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / kPublishHz,
                              NSEC_PER_SEC / (kPublishHz * 2));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_publishTimer, ^{
        [weakSelf publishLatestFrame];
    });
    dispatch_resume(_publishTimer);
}

- (void)stopPublishing {
    if (!_publishTimer) return;
    dispatch_source_cancel(_publishTimer);
    _publishTimer = nil;
}

- (void)publishLatestFrame {
    if (!_snapshot || ![_channel hasListener]) return;

    // Seqlock read: an even sequence that did not move across the copy means the
    // audio thread was not mid-write, so the frame we hold is coherent.
    unsigned int before = 0, after = 0;
    for (int attempt = 0; attempt < 4; attempt++) {
        before = atomic_load_explicit(&_snapshotSeq, memory_order_acquire);
        if (before & 1u) continue;  // a write is in flight
        if (before == _publishedSeq) return;  // nothing new since the last send
        memcpy(_publishBuffer, _snapshot, kBinCount * sizeof(float));
        after = atomic_load_explicit(&_snapshotSeq, memory_order_acquire);
        if (before == after) break;
    }
    if (before != after || (before & 1u)) return;  // torn read; the next tick is 16 ms away

    _publishedSeq = before;

    NSData *data = [NSData dataWithBytes:_publishBuffer length:kBinCount * sizeof(float)];
    [_channel sendEvent:@{
        @"magnitudes" : [FlutterStandardTypedData typedDataWithFloat32:data],
        @"sampleRate" : @(atomic_load_explicit(&_snapshotSampleRate, memory_order_relaxed)),
    }];
}

#pragma mark - Tap callbacks

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = clientInfo;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {}

static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                       const AudioStreamBasicDescription *format) {
    SpectrumTap *self = (__bridge SpectrumTap *)MTAudioProcessingTapGetStorage(tap);
    [self prepareWithSampleRate:format->mSampleRate];
}

static void tapUnprepare(MTAudioProcessingTapRef tap) {}

static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                       MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                       CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    // Always pull the audio through, or playback goes silent.
    OSStatus status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (status != noErr) return;

    SpectrumTap *self = (__bridge SpectrumTap *)MTAudioProcessingTapGetStorage(tap);
    // Equalize first so the spectrum (and the audible output) reflect the
    // filtered signal — bufferListInOut is what MTAudioProcessingTap actually
    // hands onward to the renderer.
    [self applyEqualizerToBufferList:bufferListInOut];
    [self consume:bufferListInOut frames:(int)numberFrames];
}

#pragma mark - Equalizer

- (void)setEqualizerEnabled:(BOOL)enabled {
    if (enabled && atomic_load_explicit(&_eqSetup, memory_order_acquire) == NULL) {
        // First-ever enable with no coefficients built yet (e.g. gains were
        // never touched and are still all zero) — build a flat setup so
        // enabling doesn't silently do nothing.
        [self rebuildEqualizerSetup];
    }
    atomic_store_explicit(&_eqEnabled, enabled, memory_order_release);
}

- (void)setEqualizerBandGain:(NSInteger)bandIndex gainDecibels:(float)gain {
    if (bandIndex < 0 || bandIndex >= kEQBandCount) return;
    _eqBandGains[bandIndex] = gain;
    [self rebuildEqualizerSetup];
}

/// Recomputes all band coefficients (Audio EQ Cookbook peaking filter) and
/// atomically swaps them in. Never called from the realtime thread; the old
/// setup is freed after a short grace period so an in-flight tapProcess call
/// that already loaded the old pointer has time to finish with it.
- (void)rebuildEqualizerSetup {
    double coeffs[5 * kEQBandCount];
    double fs = _sampleRate > 0 ? _sampleRate : 44100;
    for (int i = 0; i < kEQBandCount; i++) {
        double f0 = kEQCenterFrequencies[i];
        double gainDb = _eqBandGains[i];
        double A = pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * M_PI * f0 / fs;
        double alpha = sin(w0) / (2.0 * kEQQ);
        double cosw0 = cos(w0);

        double b0 = 1.0 + alpha * A;
        double b1 = -2.0 * cosw0;
        double b2 = 1.0 - alpha * A;
        double a0 = 1.0 + alpha / A;
        double a1 = -2.0 * cosw0;
        double a2 = 1.0 - alpha / A;

        coeffs[i * 5 + 0] = b0 / a0;
        coeffs[i * 5 + 1] = b1 / a0;
        coeffs[i * 5 + 2] = b2 / a0;
        coeffs[i * 5 + 3] = a1 / a0;
        coeffs[i * 5 + 4] = a2 / a0;
    }

    vDSP_biquad_Setup newSetup = vDSP_biquad_CreateSetup(coeffs, kEQBandCount);
    if (!newSetup) {
        os_log_error(spectrumLog(), "failed to build equalizer setup");
        return;
    }

    vDSP_biquad_Setup oldSetup =
        atomic_exchange_explicit(&_eqSetup, newSetup, memory_order_acq_rel);
    if (oldSetup) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            vDSP_biquad_DestroySetup(oldSetup);
        });
    }
}

/// Runs on the realtime audio thread. Filters every channel of [bufferList]
/// in place, cascading all bands per channel via one vDSP_biquad_Setup.
/// Allocation-free: coefficients and delay buffers are prebuilt elsewhere.
- (void)applyEqualizerToBufferList:(AudioBufferList *)bufferList {
    if (!atomic_load_explicit(&_eqEnabled, memory_order_acquire)) return;
    vDSP_biquad_Setup setup = atomic_load_explicit(&_eqSetup, memory_order_acquire);
    if (!setup) return;

    int channelCursor = 0;
    for (UInt32 b = 0; b < bufferList->mNumberBuffers; b++) {
        AudioBuffer *buf = &bufferList->mBuffers[b];
        float *data = (float *)buf->mData;
        if (!data || buf->mNumberChannels == 0) continue;
        UInt32 channels = buf->mNumberChannels;
        UInt32 samplesPerChannel = (buf->mDataByteSize / (UInt32)sizeof(float)) / channels;
        if (samplesPerChannel == 0) continue;
        for (UInt32 ch = 0; ch < channels; ch++) {
            if (channelCursor >= kEQMaxChannels) return;
            float *delay = _eqDelay[channelCursor++];
            vDSP_biquad(setup, delay, data + ch, (vDSP_Stride)channels, data + ch,
                        (vDSP_Stride)channels, samplesPerChannel);
        }
    }
}

#pragma mark - Analysis

- (void)prepareWithSampleRate:(double)sampleRate {
    _sampleRate = sampleRate > 0 ? sampleRate : 44100;
    _pendingCount = 0;
    atomic_store_explicit(&_snapshotSampleRate, (int)_sampleRate, memory_order_relaxed);
    os_log_info(spectrumLog(), "tap prepared at %d Hz", (int)_sampleRate);
}

/// Runs on the realtime audio thread. Allocation-free, lock-free, and it hands no
/// work to another queue: everything here has to finish inside the render
/// deadline, or playback breaks up.
- (void)consume:(AudioBufferList *)bufferList frames:(int)frames {
    if (!_snapshot || ![_channel hasListener] || bufferList->mNumberBuffers == 0 || frames <= 0) return;

    const float *samples = (const float *)bufferList->mBuffers[0].mData;
    if (!samples) return;

    int consumed = 0;
    while (consumed < frames) {
        const int room = kFFTSize - _pendingCount;
        const int take = MIN(room, frames - consumed);
        memcpy(_pending + _pendingCount, samples + consumed, take * sizeof(float));
        _pendingCount += take;
        consumed += take;

        if (_pendingCount == kFFTSize) {
            [self transformIntoSnapshot];
            _pendingCount = 0;
        }
    }
}

- (void)transformIntoSnapshot {
    vDSP_vmul(_pending, 1, _window, 1, _windowed, 1, kFFTSize);

    DSPSplitComplex split = {.realp = _real, .imagp = _imag};
    vDSP_ctoz((const DSPComplex *)_windowed, 2, &split, 1, kBinCount);
    vDSP_fft_zrip(_fftSetup, &split, 1, kLog2N, kFFTDirection_Forward);

    // zrip packs DC and Nyquist into imagp[0]/realp[0]; the DC term is not a band
    // anyone wants to look at, so drop it rather than let it tower over the curve.
    split.imagp[0] = 0.0f;

    vDSP_zvabs(&split, 1, _magnitudes, 1, kBinCount);

    // zrip returns twice the true magnitude, and a Hann window halves the
    // amplitude of what it passes; the two cancel, leaving 1/kFFTSize.
    float scale = 2.0f / (float)kFFTSize;
    vDSP_vsmul(_magnitudes, 1, &scale, _magnitudes, 1, kBinCount);

    float low = 0.0f, high = 1.0f;
    vDSP_vclip(_magnitudes, 1, &low, &high, _magnitudes, 1, kBinCount);

    // Odd sequence while the buffer is inconsistent, even once it is whole again.
    atomic_fetch_add_explicit(&_snapshotSeq, 1, memory_order_release);
    memcpy(_snapshot, _magnitudes, kBinCount * sizeof(float));
    atomic_fetch_add_explicit(&_snapshotSeq, 1, memory_order_release);
}

@end
