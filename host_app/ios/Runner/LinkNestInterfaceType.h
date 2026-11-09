#ifndef LinkNestInterfaceType_h
#define LinkNestInterfaceType_h

#include <stdint.h>

// Returns the Darwin functional type for a network interface, or 0 on failure.
uint32_t LinkNestFunctionalInterfaceType(const char *name);
int LinkNestIsWifiInterface(const char *name);

#endif
