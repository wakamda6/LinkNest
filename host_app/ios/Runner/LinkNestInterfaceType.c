#include "LinkNestInterfaceType.h"

#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>

uint32_t LinkNestFunctionalInterfaceType(const char *name) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return IFRTYPE_FUNCTIONAL_UNKNOWN;
  struct ifreq request = {0};
  strlcpy(request.ifr_name, name, sizeof(request.ifr_name));
  int result = ioctl(fd, SIOCGIFFUNCTIONALTYPE, &request);
  close(fd);
  return result == 0 ? request.ifr_ifru.ifru_functional_type : IFRTYPE_FUNCTIONAL_UNKNOWN;
}

int LinkNestIsWifiInterface(const char *name) {
  return LinkNestFunctionalInterfaceType(name) == IFRTYPE_FUNCTIONAL_WIFI_INFRA;
}
