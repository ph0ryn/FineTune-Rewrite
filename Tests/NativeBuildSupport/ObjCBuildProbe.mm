#include "NativeAudio.h"
#include "NativeBuildSupport.h"
#import <Foundation/Foundation.h>

bool ft_test_objc_runtime_available(void) { return [NSObject class] != Nil; }
