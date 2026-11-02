#include "NativeBuildSupport.h"
#include "AudioDSP/AudioDSP.hpp"
#include <span>

static_assert(__cpp_lib_span >= 202002L, "The standard library must support C++20 span");

long ft_test_cpp_language_version(void) {
    return __cplusplus;
}
