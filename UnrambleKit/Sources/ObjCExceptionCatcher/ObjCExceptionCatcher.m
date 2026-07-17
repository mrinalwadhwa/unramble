#import "ObjCExceptionCatcher.h"

NSException * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
