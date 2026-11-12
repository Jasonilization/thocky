/*
 * spu_sensor.h - bridge to the undocumented AppleSPU accelerometer.
 *
 * Apple Silicon MacBooks expose a Bosch-class IMU behind the Sensor Processing
 * Unit as AppleSPUHIDDevice (vendor usage page 0xFF00, usage 3 = accelerometer).
 * There is no public API; we drive it through IOKit HID directly:
 *
 *   1. wake the AppleSPUHIDDriver services (reporting/power state, 1 kHz report
 *      interval) by setting IORegistry properties,
 *   2. open the accel device with IOHIDDeviceOpen,
 *   3. receive 22-byte reports on a dedicated CFRunLoop thread at ~800-1000 Hz.
 *
 * Report payload: three int32 Q16 fixed-point values at byte offsets 6/10/14;
 * dividing by 65536 gives g. No root privileges are required.
 */
#ifndef KS_SPU_SENSOR_H
#define KS_SPU_SENSOR_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t  x, y, z;      /* raw Q16 counts (value / 65536.0 == g) */
    uint64_t mach_time;    /* mach_absolute_time() when the report was handled */
} ks_spu_sample_t;

typedef void (*ks_spu_callback)(const ks_spu_sample_t *sample, void *ctx);

int         ks_spu_start(ks_spu_callback cb, void *ctx);  /* async; 0 = failed */
void        ks_spu_stop(void);
int         ks_spu_is_running(void);
int         ks_spu_available(void);      /* device present in the IO registry */
double      ks_spu_sample_rate_hz(void);  /* measured, after ~1s of samples */
const char *ks_spu_error(void);

#ifdef __cplusplus
}
#endif

#endif /* KS_SPU_SENSOR_H */
