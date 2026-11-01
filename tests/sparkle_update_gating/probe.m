// Runs one real Sparkle update probe and prints a single "RESULT:" line.
//
// Usage: probe <host.app> <feed-url>
//
// The host bundle supplies the installed version (CFBundleVersion) and the
// EdDSA public key. The probe starts an SPUUpdater for that bundle and calls
// -checkForUpdateInformation, so the verdict comes from Sparkle's own appcast
// parsing, item filtering (hardware, OS, informational) and no-update reason.
// Built with -DSPARKLE_281 for Sparkle 2.8.1, which predates
// SUAppcastItem.hardwareRequirements.
#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>
#include <TargetConditionals.h>
#include <errno.h>
#include <string.h>
#include <sys/sysctl.h>

static NSString *gFeedURL;

@interface ProbeUserDriver : NSObject <SPUUserDriver>
@end

@implementation ProbeUserDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { printf("driver: unexpected permission request\n"); }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)downloadData {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { printf("driver: updater error: %s\n", error.localizedDescription.UTF8String); acknowledgement(); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)expectedContentLength {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)applicationTerminated retryTerminatingApplication:(void (^)(void))retryTerminatingApplication {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end

@interface ProbeDelegate : NSObject <SPUUpdaterDelegate>
@end

@implementation ProbeDelegate
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return gFeedURL; }

- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
#ifdef SPARKLE_281
  printf("RESULT: OFFERED  informationOnly=%s version=%s\n", item.informationOnlyUpdate ? "YES" : "NO", item.displayVersionString.UTF8String);
#else
  printf("RESULT: OFFERED  informationOnly=%s version=%s hardwareRequirements=%s\n", item.informationOnlyUpdate ? "YES" : "NO",
         item.displayVersionString.UTF8String, [[item.hardwareRequirements.allObjects componentsJoinedByString:@","] UTF8String]);
#endif
}

- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
  static const char *names[] = {"unknown", "onLatestVersion", "onNewerThanLatestVersion", "systemIsTooOld", "systemIsTooNew", "hardwareDoesNotSupportARM64"};
  long reason = [error.userInfo[SPUNoUpdateFoundReasonKey] longValue];
  SUAppcastItem *latest = error.userInfo[SPULatestAppcastItemFoundKey];
  printf("RESULT: NOT OFFERED  reason=%ld (%s) latest=%s message=\"%s\"\n", reason, (reason >= 0 && reason <= 5) ? names[reason] : "?",
         latest.displayVersionString.UTF8String, error.localizedDescription.UTF8String);
}

- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
  printf("abort: %s\n", error.localizedDescription.UTF8String);
}

- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)updateCheck error:(NSError *)error {
  fflush(stdout);
  exit(0);
}
@end

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 3) {
      fprintf(stderr, "usage: probe <host.app> <feed-url>\n");
      return 2;
    }
    NSBundle *host = [NSBundle bundleWithPath:@(argv[1])];
    gFeedURL = @(argv[2]);
    if (host == nil) {
      fprintf(stderr, "no bundle at %s\n", argv[1]);
      return 2;
    }

#if TARGET_CPU_X86_64
    const char *slice = "x86_64";
#else
    const char *slice = "arm64";
#endif
    // The same sysctl Sparkle 2.9 reads to tell Rosetta from a native Intel Mac.
    int translated = -1;
    size_t size = sizeof translated;
    int rc = sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0);
    printf("process: slice=%s proc_translated=%s host_build=%s\n", slice,
           rc == 0 ? (translated ? "1" : "0") : (errno == ENOENT ? "ENOENT" : strerror(errno)),
           [host.infoDictionary[@"CFBundleVersion"] UTF8String]);

    ProbeDelegate *delegate = [ProbeDelegate new];
    ProbeUserDriver *driver = [ProbeUserDriver new];
    SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host userDriver:driver delegate:delegate];
    NSError *error = nil;
    if (![updater startUpdater:&error]) {
      printf("startUpdater failed: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    [updater checkForUpdateInformation];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:20]];
    printf("timeout\n");
    return 3;
  }
}
