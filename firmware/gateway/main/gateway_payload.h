#ifndef GATEWAY_PAYLOAD_H
#define GATEWAY_PAYLOAD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "sht20_protocol.h"

typedef struct {
    uint64_t seq;
    uint64_t captured_mono_ms;
    bool good;
    bool time_valid;
    char timestamp_utc[25];
    sht20_sample_t values;
    char error[48];
} gateway_sample_t;

/* Pure C, bounded JSON, no heap or SDK. seq is assigned per actual read.
 * bad => values=null, sample_ts_utc=null, time_valid=false, sample_age_ms=null.
 * good without SNTP remains good sensor data with null capture timestamp.
 * Returns bytes excluding NUL, or 0 on overflow/invalid arguments.
 */
size_t gateway_format_telemetry(char *out, size_t capacity, const char *boot_id,
                               uint64_t uptime_ms, const gateway_sample_t *sample);
#endif
