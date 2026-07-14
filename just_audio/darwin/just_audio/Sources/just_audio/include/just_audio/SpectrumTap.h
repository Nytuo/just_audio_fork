#import <AVFoundation/AVFoundation.h>
#import "./BetterEventChannel.h"

/// Streams FFT magnitudes of the audio actually being played, by hanging an
/// MTAudioProcessingTap off the player item's audio mix.
///
/// This is the only way to see the samples on Darwin: AVQueuePlayer renders the
/// audio itself and exposes no output tap. Note that an audio mix cannot be
/// attached to an HLS stream — [attachToItem:] simply does nothing there, and no
/// events are sent.
///
/// The FFT is skipped entirely while nothing is listening on the event channel,
/// so an app that never shows a visualizer pays nothing for this.
@interface SpectrumTap : NSObject

/// [channel] is shared between players, so events carry no player id: only the
/// player that is actually rendering audio produces any.
- (instancetype)initWithEventChannel:(BetterEventChannel *)channel;

/// Installs the tap on [item]. Safe to call repeatedly for the same item.
- (void)attachToItem:(AVPlayerItem *)item;

- (void)dispose;

@end
