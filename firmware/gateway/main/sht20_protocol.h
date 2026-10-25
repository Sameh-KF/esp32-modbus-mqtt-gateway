#ifndef SHT20_PROTOCOL_H
#define SHT20_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Candidate profile from the supplied manual, not a verified factory setting.
 * All addresses below are raw, zero-based PDU addresses: start=0x0001.
 */
#define SHT20_DEFAULT_UNIT         1U
#define SHT20_READ_FUNCTION        0x04U
#define SHT20_START_ADDRESS        0x0001U
#define SHT20_REGISTER_COUNT       2U
#define SHT20_REQUEST_LENGTH       8U
#define SHT20_RESPONSE_LENGTH      9U
#define SHT20_EXCEPTION_LENGTH     5U
#define SHT20_MAX_HUMIDITY_TENTHS   1000U

typedef struct {
    int16_t temperature_tenths_c;
    uint16_t humidity_tenths_percent;
} sht20_sample_t;

typedef enum {
    SHT20_PARSE_OK = 0,
    SHT20_PARSE_NO_RX,
    SHT20_PARSE_CRC_ERROR,
    SHT20_PARSE_EXCEPTION,
    SHT20_PARSE_WRONG_UNIT,
    SHT20_PARSE_WRONG_FUNCTION,
    SHT20_PARSE_WRONG_BYTE_COUNT,
    SHT20_PARSE_PARTIAL,
    SHT20_PARSE_LENGTH_ERROR,
    SHT20_PARSE_HUMIDITY_RANGE,
    SHT20_PARSE_INVALID_ARGUMENT
} sht20_parse_result_t;

/* Modbus CRC16: seed 0xFFFF, reflected polynomial 0xA001.
 * The low byte is transmitted first. data must be valid for length bytes;
 * data=NULL is permitted only for length=0.
 */
uint16_t sht20_crc16(const uint8_t *data, size_t length);

/* Build FC04, raw address 1, two registers. Returns 8, or 0 on invalid
 * arguments. Allowed unicast units: 1..247. No writes or scanning.
 */
size_t sht20_build_request(uint8_t unit, uint8_t out[SHT20_REQUEST_LENGTH]);

/* Parse EXACTLY ONE response, without searching, skipping bytes or echo
 * removal. The transport must pass a complete frame from one receive window.
 * Success requires the expected unit, FC04, byte count=4, exact length, CRC
 * and humidity in 0..1000. Temperature is signed int16 in 0.1 deg C units.
 * sample is required and remains unchanged on every non-OK result.
 * exception_code is optional, and is changed only for a CRC-valid exception.
 * A CRC-valid exception is a failed measurement, never a zero reading.
 */
sht20_parse_result_t sht20_parse_response(
    const uint8_t *frame, size_t length, uint8_t expected_unit,
    sht20_sample_t *sample, uint8_t *exception_code);

const char *sht20_parse_result_name(sht20_parse_result_t result);

#ifdef __cplusplus
}
#endif
#endif
