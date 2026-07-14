#import "./include/just_audio/SpectrumTap.h"
#import <Accelerate/Accelerate.h>
#import <MediaToolbox/MediaToolbox.h>

// Power of two, and the same window the Android side captures, so both platforms
// hand Dart comparable resolution.
#define kFFTSize 1024
#define kLog2N 10
#define kBinCount (kFFTSize / 2)

@implementation SpectrumTap {
    BetterEventChannel *_channel;
    MTAudioProcessingTapRef _tap;
    __weak AVPlayerItem *_item;
    // The item whose tracks are still loading; guards against a stale async attach.
    __weak AVPlayerItem *_pendingItem;

    FFTSetup _fftSetup;
    float *_window;
    float *_windowed;
    float *_real;
    float *_imag;
    float *_magnitudes;

    // Samples accumulate here until there are enough for one transform.
    float *_pending;
    int _pendingCount;

    double _sampleRate;
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
    _pendingCount = 0;

    vDSP_hann_window(_window, kFFTSize, vDSP_HANN_NORM);
    return self;
}

- (void)dispose {
    [self detach];
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
    _window = _windowed = _real = _imag = _magnitudes = _pending = NULL;
}

- (void)dealloc {
    [self dispose];
}

- (void)detach {
    AVPlayerItem *item = _item;
    if (item) item.audioMix = nil;
    _item = nil;
    _pendingItem = nil;
    if (_tap) {
        CFRelease(_tap);
        _tap = NULL;
    }
}

- (void)attachToItem:(AVPlayerItem *)item {
    if (!item || item == _item || item == _pendingItem) return;
    _pendingItem = item;

    // Loading an asset's tracks reaches out to the network, so it must never be
    // asked for synchronously: -tracksWithMediaType: would block whatever thread
    // we are on, and we are called from KVO on the main thread.
    AVAsset *asset = item.asset;
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            // Another item became current while we were loading; that one wins.
            if (self->_pendingItem != item) return;
            self->_pendingItem = nil;

            NSError *error = nil;
            if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) return;

            // An HLS asset exposes no audio tracks to hang a mix off. Nothing to do,
            // and no point failing loudly: the visualizer just stays empty.
            AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            if (!track) return;

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
        NSLog(@"SpectrumTap: could not create tap (%d)", (int)status);
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
    [self consume:bufferListInOut frames:(int)numberFrames];
}

#pragma mark - Analysis

- (void)prepareWithSampleRate:(double)sampleRate {
    _sampleRate = sampleRate > 0 ? sampleRate : 44100;
    _pendingCount = 0;
}

/// Runs on the realtime audio thread. Keep it allocation-free.
- (void)consume:(AudioBufferList *)bufferList frames:(int)frames {
    if (![_channel hasListener] || bufferList->mNumberBuffers == 0 || frames <= 0) return;

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
            [self transformAndSend];
            _pendingCount = 0;
        }
    }
}

- (void)transformAndSend {
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

    NSData *data = [NSData dataWithBytes:_magnitudes length:kBinCount * sizeof(float)];
    double sampleRate = _sampleRate;
    BetterEventChannel *channel = _channel;
    dispatch_async(dispatch_get_main_queue(), ^{
        [channel sendEvent:@{
            @"magnitudes" : [FlutterStandardTypedData typedDataWithFloat32:data],
            @"sampleRate" : @((int)sampleRate),
        }];
    });
}

@end
