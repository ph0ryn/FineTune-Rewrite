#include "NativeAudio.h"
#include "AudioDSP/AudioDSP.hpp"
#include "AudioDSP/Pipeline.hpp"
#import <Foundation/Foundation.h>

static_assert(__cplusplus >= 202002L, "NativeAudio requires C++20 or later");
