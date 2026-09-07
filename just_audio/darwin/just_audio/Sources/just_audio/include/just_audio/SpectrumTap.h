#import <AVFoundation/AVFoundation.h>
#import "./BetterEventChannel.h"

/// Streams FFT magnitudes of the audio actually being played, and optionally
/// applies a 10-band graphic equalizer, by hanging a single MTAudioProcessingTap
/// off the player item's audio mix.
///
/// This is the only way to see or modify the samples on Darwin: AVQueuePlayer
/// renders the audio itself and exposes no output tap, and AVFoundation only
/// allows one audio-mix tap per player item — so equalization and spectrum
/// analysis share this one tap rather than each installing their own. Note
/// that an audio mix cannot be attached to an HLS stream — [attachToItem:]
/// simply does nothing there, and no spectrum events are sent (nor is the
/// equalizer applied).
///
/// The FFT is skipped entirely while nothing is listening on the event channel,
/// so an app that never shows a visualizer pays nothing for this. The
/// equalizer likewise does no filtering work while disabled.
@interface SpectrumTap : NSObject

/// [channel] is shared between players, so events carry no player id: only the
/// player that is actually rendering audio produces any.
- (instancetype)initWithEventChannel:(BetterEventChannel *)channel;

/// Installs the tap on [item]. Safe to call repeatedly for the same item.
- (void)attachToItem:(AVPlayerItem *)item;

- (void)dispose;

#pragma mark - Equalizer

/// Enables or disables the equalizer. Disabled by default. While disabled,
/// audio passes through unfiltered at negligible cost.
- (void)setEqualizerEnabled:(BOOL)enabled;

/// Sets the gain, in decibels, of the equalizer band at [bandIndex] (matching
/// the order of the Dart-side `darwinEqualizerCenterFrequencies` list). Safe
/// to call from any thread; never called from the realtime audio thread.
- (void)setEqualizerBandGain:(NSInteger)bandIndex gainDecibels:(float)gain;

@end
