/* spu_sensor.c - IOKit HID reader for the AppleSPU accelerometer. */
#include "../include/spu_sensor.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t mach_absolute_time_scale_ns(uint64_t ticks);

#define SPU_REPORT_BUF      4096
#define SPU_REPORT_BYTES    22
#define SPU_DATA_OFFSET     6
#define SPU_PAGE_VENDOR     0xFF00
#define SPU_USAGE_ACCEL     3
#define SPU_REPORT_INTERVAL 1000   /* microseconds */

static struct {
    pthread_t          thread;
    CFRunLoopRef       runloop;
    IOHIDDeviceRef     device;
    ks_spu_callback    cb;
    void              *ctx;
    atomic_int         running;
    atomic_int         thread_ready;
    char               error[256];

    /* measured rate */
    uint64_t           first_ts;
    unsigned long long count;
    double             rate;
} g;

const char *ks_spu_error(void) { return g.error; }

int ks_spu_is_running(void) { return atomic_load(&g.running); }

static int prop_int(io_service_t svc, CFStringRef key) {
    int v = 0;
    CFTypeRef r = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
    if (r) {
        if (CFGetTypeID(r) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)r, kCFNumberIntType, &v);
        }
        CFRelease(r);
    }
    return v;
}

static int prop_page(io_service_t svc) {
    return prop_int(svc, CFSTR("PrimaryUsagePage"));
}
static int prop_usage(io_service_t svc) {
    return prop_int(svc, CFSTR("PrimaryUsage"));
}

int ks_spu_available(void) {
    CFMutableDictionaryRef m = IOServiceMatching("AppleSPUHIDDevice");
    if (!m) return 0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return 0;
    io_service_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(it)) != 0) {
        if (prop_page(svc) == SPU_PAGE_VENDOR && prop_usage(svc) == SPU_USAGE_ACCEL) {
            found = 1;
        }
        IOObjectRelease(svc);
        if (found) break;
    }
    IOObjectRelease(it);
    return found;
}

double ks_spu_sample_rate_hz(void) { return g.rate; }

static void spu_report_cb(void *ctx, IOReturn result, void *sender, uint32_t type,
                          uint32_t report_id, uint8_t *report, CFIndex length,
                          uint64_t hid_mach_time) {
    (void)ctx; (void)result; (void)sender; (void)type; (void)report_id; (void)hid_mach_time;
    if (length < SPU_REPORT_BYTES) return;

    ks_spu_sample_t s;
    memcpy(&s.x, report + SPU_DATA_OFFSET + 0, 4);
    memcpy(&s.y, report + SPU_DATA_OFFSET + 4, 4);
    memcpy(&s.z, report + SPU_DATA_OFFSET + 8, 4);

    const uint64_t now = (uint64_t)mach_absolute_time();
    s.mach_time = now;

    if (g.cb) g.cb(&s, g.ctx);

    g.count++;
    if (g.first_ts == 0) g.first_ts = now;
    else {
        const uint64_t dt = now - g.first_ts;
        if (dt > 0) g.rate = (double)g.count * 1e9 / (double)mach_absolute_time_scale_ns(dt);
    }
}

/* converts mach ticks to nanoseconds using the timebase */
static uint64_t mach_absolute_time_scale_ns(uint64_t ticks) {
    static mach_timebase_info_data_t info;
    static int ready = 0;
    if (!ready) { mach_timebase_info(&info); ready = 1; }
    return (info.numer * ticks) / info.denom;
}

static void spu_wake_drivers(void) {
    CFMutableDictionaryRef m = IOServiceMatching("AppleSPUHIDDriver");
    if (!m) return;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != 0) {
        const struct { const char *k; int v; } props[] = {
            { "SensorPropertyReportingState", 1 },
            { "SensorPropertyPowerState", 1 },
            { "ReportInterval", SPU_REPORT_INTERVAL },
        };
        for (size_t i = 0; i < sizeof(props) / sizeof(props[0]); i++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, props[i].k,
                                                       kCFStringEncodingUTF8);
            int v = props[i].v;
            CFNumberRef val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
            if (key && val) IORegistryEntrySetCFProperty(svc, key, val);
            if (key) CFRelease(key);
            if (val) CFRelease(val);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
}

static void *spu_thread(void *arg) {
    (void)arg;
    g.runloop = NULL;
    g.rate = 0.0;
    g.count = 0;
    g.first_ts = 0;

    spu_wake_drivers();

    CFMutableDictionaryRef m = IOServiceMatching("AppleSPUHIDDevice");
    if (!m) { snprintf(g.error, sizeof(g.error), "IOServiceMatching failed"); goto done; }

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) {
        snprintf(g.error, sizeof(g.error), "no matching services");
        goto done;
    }

    io_service_t svc;
    int opened = 0;
    while ((svc = IOIteratorNext(it)) != 0) {
        if (prop_page(svc) == SPU_PAGE_VENDOR && prop_usage(svc) == SPU_USAGE_ACCEL) {
            g.device = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
            if (g.device && IOHIDDeviceOpen(g.device, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
                static uint8_t report_buf[SPU_REPORT_BUF];
                IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                    g.device, report_buf, sizeof(report_buf), spu_report_cb, NULL);
                IOHIDDeviceScheduleWithRunLoop(g.device, CFRunLoopGetCurrent(),
                                               kCFRunLoopDefaultMode);
                opened = 1;
                break;
            }
            snprintf(g.error, sizeof(g.error), "could not open the accelerometer");
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);

    if (!opened) {
        if (g.error[0] == '\0') snprintf(g.error, sizeof(g.error), "no accelerometer found");
        goto done;
    }

    g.runloop = CFRunLoopGetCurrent();
    atomic_store(&g.thread_ready, 1);
    CFRunLoopRun();

done:
    atomic_store(&g.thread_ready, 0);
    atomic_store(&g.running, 0);
    return NULL;
}

int ks_spu_start(ks_spu_callback cb, void *ctx) {
    if (atomic_load(&g.running)) return 1;
    if (!cb) return 0;
    if (!ks_spu_available()) {
        snprintf(g.error, sizeof(g.error), "no AppleSPU accelerometer on this machine");
        return 0;
    }
    g.cb = cb;
    g.ctx = ctx;
    atomic_store(&g.running, 1);
    atomic_store(&g.thread_ready, 0);
    if (pthread_create(&g.thread, NULL, spu_thread, NULL) != 0) {
        atomic_store(&g.running, 0);
        snprintf(g.error, sizeof(g.error), "pthread_create failed");
        return 0;
    }
    /* wait briefly so callers can assume the stream is live */
    for (int i = 0; i < 100 && !atomic_load(&g.thread_ready); i++) usleep(10000);
    return atomic_load(&g.thread_ready) ? 1 : 0;
}

void ks_spu_stop(void) {
    if (!atomic_load(&g.running)) return;
    CFRunLoopRef rl = g.runloop;
    if (rl) CFRunLoopStop(rl);
    pthread_join(g.thread, NULL);
    if (g.device) {
        IOHIDDeviceClose(g.device, kIOHIDOptionsTypeNone);
        CFRelease(g.device);
        g.device = NULL;
    }
    atomic_store(&g.running, 0);
}
