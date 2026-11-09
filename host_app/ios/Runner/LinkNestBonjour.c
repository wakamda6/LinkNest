#include "LinkNestBonjour.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <dispatch/dispatch.h>
#include <net/if.h>
#include <stdio.h>

static void LinkNestRegistered(DNSServiceRef service, DNSServiceFlags flags,
                               DNSServiceErrorType error, const char *name,
                               const char *type, const char *domain, void *context) {
  if (error == kDNSServiceErr_NoError) {
    fprintf(stderr, "[LinkNest] iOS 局域网空间广告已注册\n");
  } else {
    fprintf(stderr, "[LinkNest] iOS 局域网空间广告注册回调失败 code=%d\n", error);
  }
}

void *LinkNestBonjourStart(const char *interfaceName, const char *serviceName,
                           uint16_t port, const uint8_t *txt, uint16_t txtLength) {
  uint32_t interfaceIndex = if_nametoindex(interfaceName);
  if (interfaceIndex == 0) return NULL;
  DNSServiceRef ref = NULL;
  DNSServiceErrorType error = DNSServiceRegister(
      &ref, 0, interfaceIndex, serviceName, "_linknest._tcp.", NULL, NULL,
      htons(port), txtLength, txt, LinkNestRegistered, NULL);
  if (error != kDNSServiceErr_NoError || ref == NULL) {
    fprintf(stderr, "[LinkNest] iOS 局域网空间广告提交失败 code=%d\n", error);
    return NULL;
  }
  error = DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
  if (error != kDNSServiceErr_NoError) {
    DNSServiceRefDeallocate(ref);
    fprintf(stderr, "[LinkNest] iOS 局域网空间广告监听失败 code=%d\n", error);
    return NULL;
  }
  return ref;
}

void LinkNestBonjourStop(void *registration) {
  if (registration != NULL) DNSServiceRefDeallocate((DNSServiceRef)registration);
}
