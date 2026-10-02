// AC1: real PTY reader -> full app mailbox -> app-thread surface free.
// Links ONLY the opt-in test archive rooted at src/c11_read_test.zig.
#import <Cocoa/Cocoa.h>
#include <ghostty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Test-root exports; neither declaration belongs in shipping ghostty.h.
extern uint32_t c11_test_fill_app_mailbox(ghostty_surface_t);
extern uint32_t c11_test_app_waiter_count(ghostty_surface_t);

static void fail(const char *message) {
  fprintf(stderr, "AC1 FAIL: %s\n", message);
  exit(1);
}

static void watchdog(int signal_number) {
  (void)signal_number;
  const char message[] = "AC1 FAIL: independent SIGALRM watchdog expired\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(124);
}

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}

// The host is the sole app-tick driver. Wakeups cannot dispatch a tick during
// the saturation/free interval, including from the renderer's wakeup callback.
static void wakeup(void *context) { (void)context; }
static bool action(ghostty_app_t app, ghostty_target_s target,
                   ghostty_action_s value) {
  (void)app; (void)target; (void)value;
  return true;
}
static void read_clipboard(void *context, ghostty_clipboard_e type, void *state) {
  (void)context; (void)type; (void)state;
}
static void confirm_clipboard(void *context, const char *text, void *state,
                              ghostty_clipboard_request_e request) {
  (void)context; (void)text; (void)state; (void)request;
}
static void write_clipboard(void *context, ghostty_clipboard_e type,
                            const ghostty_clipboard_content_s *content,
                            size_t count, bool confirm) {
  (void)context; (void)type; (void)content; (void)count; (void)confirm;
}
static void close_surface(void *context, bool running) {
  (void)context; (void)running;
}

static void pause_briefly(void) {
  const struct timespec duration = {.tv_sec = 0, .tv_nsec = 1000000};
  nanosleep(&duration, NULL);
}

static ghostty_surface_t new_surface(ghostty_app_t app, NSView *view,
                                     const char *command) {
  ghostty_surface_config_s config = ghostty_surface_config_new();
  config.platform_tag = GHOSTTY_PLATFORM_MACOS;
  config.platform.macos.nsview = (__bridge void *)view;
  config.scale_factor = 1;
  config.font_size = 12;
  config.command = command;
  config.wait_after_command = false;
  config.io_mode = GHOSTTY_SURFACE_IO_EXEC;
  ghostty_surface_t surface = ghostty_surface_new(app, &config);
  if (!surface) fail("real EXEC surface creation failed; require unlocked macOS GUI");
  ghostty_surface_set_size(surface, 800, 480);
  return surface;
}

static bool contains(ghostty_surface_t surface, const char *needle) {
  const ghostty_selection_s range = {
      .top_left = {.tag = GHOSTTY_POINT_SCREEN,
                   .coord = GHOSTTY_POINT_COORD_TOP_LEFT},
      .bottom_right = {.tag = GHOSTTY_POINT_SCREEN,
                       .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT},
  };
  ghostty_text_s text = {0};
  if (!ghostty_surface_read_text(surface, range, &text)) return false;
  bool found = false;
  const size_t n = strlen(needle);
  for (size_t i = 0; i + n <= text.text_len; ++i) {
    if (memcmp(text.text + i, needle, n) == 0) { found = true; break; }
  }
  ghostty_surface_free_text(surface, &text);
  return found;
}

static void expect_child_ack(ghostty_app_t app, ghostty_surface_t surface,
                             const char *token) {
  char input[128], expected[128];
  snprintf(input, sizeof(input), "%s\n", token);
  snprintf(expected, sizeof(expected), "CHILD-ACK:%s", token);
  ghostty_surface_text(surface, input, strlen(input));
  const double deadline = now_ms() + 5000;
  do {
    @autoreleasepool {
      ghostty_app_tick(app);
      if (contains(surface, expected)) return;
    }
    pause_briefly();
  } while (now_ms() < deadline);
  fail("survivor PTY child did not produce ACK within 5 seconds");
}

int main(int argc, char **argv) {
  signal(SIGALRM, watchdog);
  alarm(30); // Never release a queue gate to rescue a hanging free.
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    if (ghostty_init((uintptr_t)argc, argv)) fail("ghostty_init failed");
    ghostty_config_t config = ghostty_config_new();
    if (!config) fail("config creation failed");
    // No tenant files, shell integration, app socket, or production c11 state.
    ghostty_config_finalize(config);
    const ghostty_runtime_config_s runtime = {
        .wakeup_cb = wakeup, .action_cb = action,
        .read_clipboard_cb = read_clipboard,
        .confirm_read_clipboard_cb = confirm_clipboard,
        .write_clipboard_cb = write_clipboard, .close_surface_cb = close_surface,
    };
    ghostty_app_t app = ghostty_app_new(&runtime, config);
    if (!app) fail("app creation failed");
    NSView *doomed_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 480)];
    NSView *survivor_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 480)];
    // Views remain unshown: this fixture does not take focus or open a window.
    ghostty_surface_t doomed = new_surface(app, doomed_view,
        "/bin/sh -c 'IFS= read -r line; i=0; while :; do "
        "printf \"\\033]2;C11-AC1-%s\\007\" \"$i\"; i=$((i+1)); done'");
    ghostty_surface_t survivor = new_surface(app, survivor_view,
        "/bin/sh -c 'while IFS= read -r line; do "
        "printf \"CHILD-ACK:%s\\n\" \"$line\"; done'");
    expect_child_ack(app, survivor, "before-close");

    // From here until free returns: NO ghostty_app_tick, run-loop dispatch,
    // mailbox draining, helper consumer, or timed capacity release.
    const uint32_t filled = c11_test_fill_app_mailbox(doomed);
    if (filled != 64) fail("test hook did not fill the production 64-message app mailbox");
    ghostty_surface_text(doomed, "go\n", 3);
    const double ready_deadline = now_ms() + 5000;
    uint32_t waiters = 0;
    do {
      waiters = c11_test_app_waiter_count(doomed);
      if (waiters) break;
      pause_briefly();
    } while (now_ms() < ready_deadline);
    if (!waiters) fail("no real blocked app-mailbox producer observed");
    fprintf(stderr, "AC1 saturated messages=%u blocked-producers=%u\n", filled, waiters);

    const double start = now_ms();
    ghostty_surface_free(doomed); // Production Surface.deinit joins all workers.
    const double elapsed = now_ms() - start;
    fprintf(stderr, "AC1 real ghostty_surface_free elapsed-ms=%.3f\n", elapsed);
    if (elapsed > 5000) fail("surface free exceeded fixture's 5-second bound");

    expect_child_ack(app, survivor, "after-close");
    ghostty_surface_free(survivor);
    ghostty_app_free(app);
    ghostty_config_free(config);
    [doomed_view removeFromSuperview];
    [survivor_view removeFromSuperview];
    fprintf(stderr, "AC1 PASS: saturated app mailbox, real surface free, survivor child ACK\n");
  }
  alarm(0);
  return 0;
}
