#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface BetterEventChannel : NSObject<FlutterStreamHandler>

- (instancetype)initWithName:(NSString*)name messenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)sendEvent:(id)event;

/// Whether anything is listening. Lets producers skip expensive work for nobody.
- (BOOL)hasListener;
- (void)dispose;

@end
