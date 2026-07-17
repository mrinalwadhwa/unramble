#import <Foundation/Foundation.h>

/// Try to execute a block and catch any Objective-C NSException.
/// Returns the caught NSException, or nil if no exception was thrown.
/// Use this to protect Swift code from AVAudioEngine operations that
/// throw ObjC exceptions (e.g. installTap, engine.start) instead of
/// Swift errors.
NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSException * _Nullable ObjCTryCatch(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END