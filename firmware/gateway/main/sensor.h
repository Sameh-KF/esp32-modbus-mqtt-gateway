#ifndef GATEWAY_SENSOR_H
#define GATEWAY_SENSOR_H
#include <stdbool.h>
#include <stddef.h>
#include "sht20_protocol.h"

typedef struct {
    bool good;
    sht20_sample_t values;
    const char *error; /* static machine-readable token, never a secret */
    size_t received_bytes;
    unsigned exception_code;
} sensor_reading_t;
void sensor_init(void);
/* Blocking <= about 1.8 s under normal driver operation. One caller only.
 * UART1 TX17 RX18, 9600 8N1, FC04 raw1 count2 ID1. No sensor writes.
 */
sensor_reading_t sensor_read(void);
#endif
