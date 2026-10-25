#include "gateway_payload.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

static bool safe_token(const char *value)
{
    if (value == NULL || value[0] == '\0') return false;
    for (const unsigned char *p = (const unsigned char *)value; *p != 0; ++p) {
        if (!(isalnum(*p) || *p == '_' || *p == '-')) return false;
    }
    return true;
}

size_t gateway_format_telemetry(char *out, size_t capacity, const char *boot_id,
                               uint64_t uptime_ms, const gateway_sample_t *sample)
{
    if (out == NULL || capacity == 0 || sample == NULL || !safe_token(boot_id) ||
        (!sample->good && !safe_token(sample->error))) return 0;
    char timestamp[32] = "null";
    char age[32] = "null";
    char values[100] = "null";
    char error[64] = "null";
    const bool valid_time = sample->good && sample->time_valid;
    if (sample->good) {
        if (sample->values.humidity_tenths_percent > 1000 ||
            uptime_ms < sample->captured_mono_ms) return 0;
        if (valid_time) {
            if (strlen(sample->timestamp_utc) != 24U ||
                sample->timestamp_utc[10] != 'T' || sample->timestamp_utc[23] != 'Z') return 0;
            (void)snprintf(timestamp, sizeof(timestamp), "\"%s\"", sample->timestamp_utc);
        }
        (void)snprintf(age, sizeof(age), "%" PRIu64, uptime_ms - sample->captured_mono_ms);
        (void)snprintf(values, sizeof(values),
            "{\"temperature_c\":%.1f,\"humidity_pct\":%.1f}",
            (double)sample->values.temperature_tenths_c / 10.0,
            (double)sample->values.humidity_tenths_percent / 10.0);
    } else {
        (void)snprintf(error, sizeof(error), "\"%s\"", sample->error);
    }
    const int length = snprintf(out, capacity,
        "{\"schema_version\":1,\"device_id\":\"gw-01\",\"source_mode\":\"hardware\","
        "\"boot_id\":\"%s\",\"seq\":%" PRIu64 ",\"slave_id\":1,"
        "\"uptime_ms\":%" PRIu64 ",\"sample_ts_utc\":%s,\"time_valid\":%s,"
        "\"sample_age_ms\":%s,\"quality\":\"%s\",\"values\":%s,\"error\":%s}",
        boot_id, sample->seq, uptime_ms, timestamp, valid_time ? "true" : "false",
        age, sample->good ? "good" : "bad", values, error);
    if (length < 0 || (size_t)length >= capacity) {
        out[0] = '\0';
        return 0;
    }
    return (size_t)length;
}
