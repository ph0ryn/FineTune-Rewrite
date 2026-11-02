#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Test-only probes. These are not part of the product's native API.
long ft_test_cpp_language_version(void);
bool ft_test_objc_runtime_available(void);

#ifdef __cplusplus
}
#endif
