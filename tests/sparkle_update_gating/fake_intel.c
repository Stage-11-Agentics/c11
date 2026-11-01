// Injected into an x86_64 probe running under Rosetta, this makes
// sysctlbyname("sysctl.proc_translated") fail with ENOENT, which is what a
// native process on an Intel Mac sees. Sparkle 2.9's arm64 hardware check
// treats that answer as "Intel hardware".
#include <errno.h>
#include <string.h>
#include <sys/sysctl.h>

static int fake_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
  if (name != NULL && strcmp(name, "sysctl.proc_translated") == 0) {
    errno = ENOENT;
    return -1;
  }
  return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

__attribute__((used)) static const struct {
  const void *replacement;
  const void *replacee;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void *)fake_sysctlbyname, (const void *)sysctlbyname},
};
