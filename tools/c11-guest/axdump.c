#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void str(AXUIElementRef e, CFStringRef attr, char *buf, size_t n) {
  buf[0] = 0; CFTypeRef v = NULL;
  if (AXUIElementCopyAttributeValue(e, attr, &v) == kAXErrorSuccess && v) {
    if (CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, buf, n, kCFStringEncodingUTF8);
    else snprintf(buf, n, "<non-string>");
    CFRelease(v);
  }
}
static void walk(AXUIElementRef e, const char *prefix, int depth, int printing) {
  if (depth > 40) return;
  char ident[256], role[128], title[512], desc[512], value[512];
  str(e, CFSTR("AXIdentifier"), ident, sizeof ident);
  int match = printing || (ident[0] && strncmp(ident, prefix, strlen(prefix)) == 0);
  if (match) {
    str(e, kAXRoleAttribute, role, sizeof role); str(e, kAXTitleAttribute, title, sizeof title);
    str(e, kAXDescriptionAttribute, desc, sizeof desc); str(e, kAXValueAttribute, value, sizeof value);
    printf("%*s%s | role=%s | title=%s | desc=%s | value=%s\n", printing ? 4 : 0, "", ident, role, title, desc, value);
  }
  CFArrayRef kids = NULL;
  if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, (CFTypeRef *)&kids) == kAXErrorSuccess && kids) {
    for (CFIndex i = 0; i < CFArrayGetCount(kids); i++)
      walk((AXUIElementRef)CFArrayGetValueAtIndex(kids, i), prefix, depth + 1, match && !printing ? 1 : printing);
    CFRelease(kids);
  }
}
int main(int argc, char **argv) {
  if (argc < 3) return 2;
  AXUIElementRef app = AXUIElementCreateApplication(atoi(argv[1]));
  walk(app, argv[2], 0, 0);
  return 0;
}
