//
//  macdeepsleep-plus -- cut the network while the lid is closed
//
//  Differences from the upstream macdeepsleep:
//    1. Only cuts the network when the lid is actually closed; idle sleep with
//       the lid open leaves the network alone.
//    2. Dark wakes do not restore anything -- only a real lid-open does.
//    3. Bluetooth is left untouched by default, so Bluetooth mice/keyboards
//       keep working.
//    4. Handles kIOMessageSystemWillNotSleep (sleep cancelled -> roll back).
//    5. Ships a --status self-check, writes state atomically, recovers after a
//       crash or a forced power-off.
//
//  Build:
//    clang -fobjc-arc -O2 -Wall \
//          -framework Foundation -framework CoreWLAN -framework IOBluetooth \
//          -o macdeepsleep macdeepsleep.m
//

#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPMKeys.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <net/if.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VERSION      "0.0.1"
#define STATE_DIR    "/var/db/macdeepsleep"
#define STATE_FILE   STATE_DIR "/state"
#define CONF_FILE    "/usr/local/etc/macdeepsleep.conf"

/* Hard cap on restore attempts per wake event. Never retry forever. */
#define MAX_RESTORE_ATTEMPTS 2

/* Bluetooth private API (IOBluetooth.framework, undocumented) */
extern int  IOBluetoothPreferenceGetControllerPowerState(void);
extern void IOBluetoothPreferenceSetControllerPowerState(int state);

static io_connect_t   g_root_port = IO_OBJECT_NULL;
static dispatch_queue_t g_queue    = NULL;
static dispatch_source_t g_timer   = NULL;

/* Configuration */
static int g_cfg_touch_bt   = 0;   /* 0 = leave Bluetooth alone (default) */
static int g_cfg_touch_awdl = 1;   /* 1 = bring awdl0 down as well */

/* What we turned off -- only these get turned back on */
static int g_off_wifi = 0, g_off_bt = 0, g_off_awdl = 0;
static int g_pending  = 0;         /* Cut state is pending a restore */
static int g_retries  = 0;         /* Restore attempts for the current event */
static int g_debug    = 0;

/* ------------------------- logging ------------------------- */

static void mlog(const char *fmt, ...)
{
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", localtime(&now));

    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "%s [%d] ", ts, (int)getpid());
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    fflush(stderr);
}

#define LOG(...)  mlog(__VA_ARGS__)
#define DBG(...)  do { if (g_debug) mlog(__VA_ARGS__); } while (0)

/* ------------------------- lid state ------------------------- */

/* 1 = closed, 0 = open, -1 = unknown */
static int lid_closed(void)
{
    io_service_t dom = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"));
    if (!dom) return -1;

    CFTypeRef v = IORegistryEntryCreateCFProperty(dom, CFSTR("AppleClamshellState"),
                                                  kCFAllocatorDefault, 0);
    IOObjectRelease(dom);
    if (!v) return -1;

    int r = -1;
    if (CFGetTypeID(v) == CFBooleanGetTypeID())
        r = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    CFRelease(v);
    return r;
}

/* ------------------------- Wi-Fi ------------------------- */

static CWInterface *wifi_iface(void)
{
    return [[CWWiFiClient sharedWiFiClient] interface];
}

static int wifi_get(void)
{
    CWInterface *i = wifi_iface();
    return i ? (i.powerOn ? 1 : 0) : -1;
}

static int wifi_set(int on)
{
    CWInterface *i = wifi_iface();
    if (!i) return -1;
    NSError *err = nil;
    if (![i setPower:(on ? YES : NO) error:&err]) {
        LOG("wifi setPower:%d failed: %s", on,
            err ? [[err localizedDescription] UTF8String] : "unknown");
        return -1;
    }
    return 0;
}

/* ------------------------- Bluetooth ------------------------- */

static int bt_get(void)
{
    return IOBluetoothPreferenceGetControllerPowerState();
}

static int bt_set(int on)
{
    IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0);
    return (bt_get() == (on ? 1 : 0)) ? 0 : -1;
}

/* ------------------------- AWDL ------------------------- */

static int awdl_get(void)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "awdl0", IFNAMSIZ - 1);
    int rc = ioctl(fd, SIOCGIFFLAGS, &ifr);
    close(fd);
    if (rc < 0) return -1;
    return (ifr.ifr_flags & IFF_UP) ? 1 : 0;
}

static int awdl_set(int on)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "awdl0", IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) { close(fd); return -1; }
    if (on) ifr.ifr_flags |=  IFF_UP;
    else    ifr.ifr_flags &= ~IFF_UP;
    int rc = ioctl(fd, SIOCSIFFLAGS, &ifr);
    close(fd);
    return rc == 0 ? 0 : -1;
}

/* ------------------------- state persistence ------------------------- */

/* File format: v2 <wifi> <bt> <awdl> <epoch> */
static int state_save(void)
{
    mkdir(STATE_DIR, 0755);
    char tmp[128];
    snprintf(tmp, sizeof(tmp), STATE_FILE ".tmp");

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { LOG("state: open %s failed", tmp); return -1; }

    char buf[160];
    int n = snprintf(buf, sizeof(buf), "v2 %d %d %d %ld\n",
                     g_off_wifi, g_off_bt, g_off_awdl, (long)time(NULL));
    if (write(fd, buf, n) != n) { close(fd); unlink(tmp); return -1; }
    fsync(fd);
    close(fd);

    if (rename(tmp, STATE_FILE) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int state_load(int *w, int *b, int *a, long *ts)
{
    FILE *fp = fopen(STATE_FILE, "r");
    if (!fp) return 0;

    char ver[8] = {0};
    long t = 0;
    int ok = (fscanf(fp, "%7s %d %d %d %ld", ver, w, b, a, &t) == 5) &&
             strcmp(ver, "v2") == 0;
    fclose(fp);
    if (ok && ts) *ts = t;
    return ok;
}

static void state_clear(void)
{
    unlink(STATE_FILE);
}

/* ------------------------- cut / restore ------------------------- */

static void timer_disarm(void)
{
    if (g_timer) {
        dispatch_source_cancel(g_timer);
        g_timer = NULL;
    }
}

/* Restore only what we turned off; clear the flags only on full success */
static int restore_all(const char *why)
{
    int all_ok = 1;

    if (g_off_wifi) {
        if (wifi_get() == 1) {
            g_off_wifi = 0;                       /* Already back on */
        } else if (wifi_set(1) == 0) {
            g_off_wifi = 0;
        } else {
            all_ok = 0;
        }
    }
    if (g_off_bt) {
        if (bt_get() == 1)      g_off_bt = 0;
        else if (bt_set(1) == 0) g_off_bt = 0;
        else all_ok = 0;
    }
    if (g_off_awdl) {
        if (awdl_get() == 1)       g_off_awdl = 0;
        else if (awdl_set(1) == 0) g_off_awdl = 0;
        else all_ok = 0;
    }

    if (all_ok) {
        g_retries = 0;
        g_pending = 0;
        state_clear();
        timer_disarm();
        LOG("restored (%s): wifi=%d bt=%d awdl=%d", why,
            wifi_get(), bt_get(), awdl_get());
        return 0;
    }
    g_retries++;
    LOG("restore FAILED (%s, attempt %d/%d): wifi_off=%d bt_off=%d awdl_off=%d",
        why, g_retries, MAX_RESTORE_ATTEMPTS, g_off_wifi, g_off_bt, g_off_awdl);
    return -1;
}

static void timer_arm(void);   /* defined below */

/* Attempt a restore, but give up after MAX_RESTORE_ATTEMPTS instead of
   retrying forever. On give-up the state file is kept so the next boot can
   try once more. */
static void restore_with_policy(const char *why)
{
    if (restore_all(why) == 0)
        return;

    if (g_retries >= MAX_RESTORE_ATTEMPTS) {
        LOG("GIVING UP after %d attempts (%s): network stays off. "
            "Turn Wi-Fi on manually if needed; state file kept for the next boot.",
            g_retries, why);
        timer_disarm();
        return;
    }
    LOG("retry scheduled (%d/%d)", g_retries, MAX_RESTORE_ATTEMPTS);
    timer_arm();
}

/* Cut the network on lid close */
static void cut_all(void)
{
    @autoreleasepool {
        int w = wifi_get();
        if (w == 1) {
            if (wifi_set(0) == 0) g_off_wifi = 1;
            else LOG("cut: wifi off FAILED");
        }

        if (g_cfg_touch_bt) {
            int b = bt_get();
            if (b == 1) {
                if (bt_set(0) == 0) g_off_bt = 1;
                else LOG("cut: bt off FAILED");
            }
        }

        if (g_cfg_touch_awdl) {
            int a = awdl_get();
            if (a == 1) {
                if (awdl_set(0) == 0) g_off_awdl = 1;
                else LOG("cut: awdl down FAILED");
            }
        }
    }

    if (g_off_wifi || g_off_bt || g_off_awdl) {
        g_pending = 1;
        if (state_save() != 0) LOG("cut: state save FAILED (no crash recovery)");
        LOG("cut: wifi_off=%d bt_off=%d(managed=%d) awdl_off=%d(managed=%d)",
            g_off_wifi, g_off_bt, g_cfg_touch_bt, g_off_awdl, g_cfg_touch_awdl);
    } else {
        LOG("cut: nothing to do (wifi already off)");
    }
}

/* Short timer used during dark wakes to notice the lid being opened */
static void timer_arm(void)
{
    if (g_timer) return;
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_queue);
    dispatch_source_set_timer(g_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(g_timer, ^{
        int c = lid_closed();
        DBG("timer: lid=%d", c);
        if (c != 0) return;              /* still closed: keep waiting */
        timer_disarm();
        restore_with_policy("lid opened (timer)");
    });
    dispatch_resume(g_timer);
    DBG("timer armed");
}

/* ------------------------- power events ------------------------- */

static void power_callback(void *ref __unused, io_service_t srv __unused,
                           natural_t msg, void *arg)
{
    switch (msg) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(g_root_port, (long)arg);
        break;

    case kIOMessageSystemWillSleep: {
        int lid = lid_closed();
        LOG("event: will sleep (lid=%d)", lid);

        if (lid == 0) {
            LOG("skip: lid is open (idle sleep), network untouched");
        } else {
            if (lid < 0) LOG("warn: lid state unknown, treat as closed");
            cut_all();
        }
        IOAllowPowerChange(g_root_port, (long)arg);
        break;
    }

    case kIOMessageSystemWillNotSleep:
        LOG("event: sleep CANCELLED");
        if (g_pending) {
            g_retries = 0;
            restore_with_policy("sleep cancelled");
        }
        break;

    case kIOMessageSystemWillPowerOn:
        DBG("event: will power on");
        break;

    case kIOMessageSystemHasPoweredOn: {
        int lid = lid_closed();
        LOG("event: powered on (lid=%d, pending=%d)", lid, g_pending);

        if (!g_pending) { timer_disarm(); break; }

        if (lid == 0) {
            g_retries = 0;
            restore_with_policy("full wake, lid open");
        } else {
            LOG("keep network off: still lid-closed (dark wake or clamshell)");
            timer_arm();
        }
        break;
    }

    default:
        DBG("event: 0x%x (ignored)", (unsigned)msg);
        break;
    }
}

/* ------------------------- configuration ------------------------- */

static void load_config(void)
{
    FILE *fp = fopen(CONF_FILE, "r");
    if (!fp) { DBG("no config, using defaults"); return; }

    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        if (!strncasecmp(p, "disable_bluetooth", 17)) {
            char *eq = strchr(p, '=');
            if (eq) g_cfg_touch_bt = (atoi(eq + 1) != 0);
        } else if (!strncasecmp(p, "disable_awdl", 12)) {
            char *eq = strchr(p, '=');
            if (eq) g_cfg_touch_awdl = (atoi(eq + 1) != 0);
        }
    }
    fclose(fp);
}

/* ------------------------- subcommands ------------------------- */

static int cmd_status(void)
{
    int lid = lid_closed();
    int w = wifi_get();
    int b = bt_get();
    int a = awdl_get();
    int sw = 0, sb = 0, sa = 0;
    long ts = 0;
    int has_state = state_load(&sw, &sb, &sa, &ts);

    const char *lid_s  = lid == 1 ? "closed" : lid == 0 ? "open" : "unknown";
    const char *wifi_s = w == 1 ? "on" : w == 0 ? "off" : "unknown";
    const char *bt_s   = b == 1 ? "on" : b == 0 ? "off" : "unknown";
    const char *awdl_s = a == 1 ? "up" : a == 0 ? "down" : "unknown";

    printf("macdeepsleep-plus %s\n", VERSION);
    printf("  lid        : %s\n", lid_s);
    printf("  wi-fi      : %s\n", wifi_s);
    printf("  bluetooth  : %s%s\n", bt_s, g_cfg_touch_bt ? " (we manage)" : " (untouched)");
    printf("  awdl0      : %s%s\n", awdl_s, g_cfg_touch_awdl ? "" : " (untouched)");

    if (has_state)
        printf("  state file : present (wifi_off=%d bt_off=%d awdl_off=%d, %lds ago)\n",
               sw, sb, sa, ts ? (long)(time(NULL) - ts) : -1L);
    else
        printf("  state file : absent\n");
    return 0;
}

static void recover_on_startup(void)
{
    int w = 0, b = 0, a = 0;
    long ts = 0;
    if (!state_load(&w, &b, &a, &ts)) return;

    LOG("startup: found stale state (wifi_off=%d bt_off=%d awdl_off=%d), recovering",
        w, b, a);
    g_off_wifi = w; g_off_bt = b; g_off_awdl = a; g_pending = 1;

    int lid = lid_closed();
    if (lid == 0) {
        g_retries = 0;
        restore_with_policy("startup recovery, lid open");
    } else {
        LOG("startup: lid closed, keep network off and wait");
        timer_arm();
    }
}

static void usage(void)
{
    printf(
        "macdeepsleep-plus %s\n"
        "usage: macdeepsleep [option]\n"
        "  --status    print current state (lid/wifi/bluetooth/awdl/state file)\n"
        "  --version   print version\n"
        "  --debug     run in foreground with debug logging\n"
        "\n"
        "config file: %s\n"
        "  disable_bluetooth=0   # 1 = also power off Bluetooth on sleep\n"
        "  disable_awdl=1        # 1 = also bring down awdl0 on sleep\n",
        VERSION, CONF_FILE);
}

/* ------------------------- main ------------------------- */

int main(int argc, char **argv)
{
    @autoreleasepool {
        load_config();

        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--version") || !strcmp(argv[i], "-v")) {
                printf("macdeepsleep-plus %s\n", VERSION);
                return 0;
            }
            if (!strcmp(argv[i], "--status")) {
                return cmd_status();
            }
            if (!strcmp(argv[i], "--debug")) {
                g_debug = 1;
                continue;
            }
            usage();
            return 2;
        }

        g_queue = dispatch_queue_create("com.local.macdeepsleep", DISPATCH_QUEUE_SERIAL);

        recover_on_startup();

        IONotificationPortRef port = NULL;
        io_object_t notifier = 0;
        g_root_port = IORegisterForSystemPower(NULL, &port, power_callback, &notifier);
        if (g_root_port == IO_OBJECT_NULL) {
            LOG("FATAL: IORegisterForSystemPower failed");
            return 1;
        }

        LOG("started v%s (lid=%d wifi=%d bt=%d awdl=%d cfg_bt=%d cfg_awdl=%d)",
            VERSION, lid_closed(), wifi_get(), bt_get(), awdl_get(),
            g_cfg_touch_bt, g_cfg_touch_awdl);

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(port),
                           kCFRunLoopDefaultMode);
        CFRunLoopRun();
    }
    return 0;
}
