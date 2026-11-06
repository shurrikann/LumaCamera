#import "LumaProbeException.h"

NSException *LumaProbeCaptureException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
