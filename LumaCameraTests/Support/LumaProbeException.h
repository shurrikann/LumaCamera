#import <Foundation/Foundation.h>

// Only for capability probes: AVFoundation reports unsupported configurations
// through Objective-C exceptions, which Swift's do/catch cannot intercept.
FOUNDATION_EXPORT NSException * _Nullable LumaProbeCaptureException(void (NS_NOESCAPE ^ _Nonnull block)(void));
