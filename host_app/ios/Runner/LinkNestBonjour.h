#ifndef LinkNestBonjour_h
#define LinkNestBonjour_h

#include <stdint.h>

void *LinkNestBonjourStart(const char *interfaceName, const char *serviceName,
                           uint16_t port, const uint8_t *txt, uint16_t txtLength);
void LinkNestBonjourStop(void *registration);

#endif
