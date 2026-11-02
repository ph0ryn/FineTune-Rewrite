#include "NativeBuildSupport.h"
#include "NativeAudio.h"
#import <Foundation/Foundation.h>

bool ft_test_objc_runtime_available(void) {
    return [NSObject class] != Nil;
}
