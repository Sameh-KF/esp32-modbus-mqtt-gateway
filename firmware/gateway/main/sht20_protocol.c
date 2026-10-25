#include "sht20_protocol.h"

#include <stdbool.h>
#include <limits.h>

static bool valid_unit(uint8_t unit)
{
    return unit >= 1U && unit <= 247U;
}

uint16_t sht20_crc16(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFFU;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8U; ++bit) {
            crc = (crc & 1U) ? (uint16_t)((crc >> 1) ^ 0xA001U)
                             : (uint16_t)(crc >> 1);
        }
    }
    return crc;
}

size_t sht20_build_request(uint8_t unit, uint8_t out[SHT20_REQUEST_LENGTH])
{
    if (out == NULL || !valid_unit(unit)) {
        return 0;
    }
    out[0] = unit;
    out[1] = SHT20_READ_FUNCTION;
    out[2] = (uint8_t)(SHT20_START_ADDRESS >> 8);
    out[3] = (uint8_t)SHT20_START_ADDRESS;
    out[4] = (uint8_t)(SHT20_REGISTER_COUNT >> 8);
    out[5] = (uint8_t)SHT20_REGISTER_COUNT;
    const uint16_t crc = sht20_crc16(out, SHT20_REQUEST_LENGTH - 2U);
    out[6] = (uint8_t)crc;
    out[7] = (uint8_t)(crc >> 8);
    return SHT20_REQUEST_LENGTH;
}

static bool valid_crc(const uint8_t *frame, size_t length)
{
    const uint16_t wire_crc = (uint16_t)frame[length - 2U] |
        (uint16_t)((uint16_t)frame[length - 1U] << 8);
    return sht20_crc16(frame, length - 2U) == wire_crc;
}

sht20_parse_result_t sht20_parse_response(
    const uint8_t *frame, size_t length, uint8_t expected_unit,
    sht20_sample_t *sample, uint8_t *exception_code)
{
    if ((frame == NULL && length != 0U) || sample == NULL ||
        !valid_unit(expected_unit)) {
        return SHT20_PARSE_INVALID_ARGUMENT;
    }
    if (length == 0U) {
        return SHT20_PARSE_NO_RX;
    }
    if (frame[0] != expected_unit) {
        return SHT20_PARSE_WRONG_UNIT;
    }
    if (length < 2U) {
        return SHT20_PARSE_PARTIAL;
    }
    if (frame[1] == (SHT20_READ_FUNCTION | 0x80U)) {
        if (length < SHT20_EXCEPTION_LENGTH) {
            return SHT20_PARSE_PARTIAL;
        }
        if (length != SHT20_EXCEPTION_LENGTH) {
            return SHT20_PARSE_LENGTH_ERROR;
        }
        if (!valid_crc(frame, length)) {
            return SHT20_PARSE_CRC_ERROR;
        }
        if (exception_code != NULL) {
            *exception_code = frame[2];
        }
        return SHT20_PARSE_EXCEPTION;
    }
    if (frame[1] != SHT20_READ_FUNCTION) {
        return SHT20_PARSE_WRONG_FUNCTION;
    }
    if (length < 3U) {
        return SHT20_PARSE_PARTIAL;
    }
    if (frame[2] != SHT20_REGISTER_COUNT * 2U) {
        return SHT20_PARSE_WRONG_BYTE_COUNT;
    }
    if (length < SHT20_RESPONSE_LENGTH) {
        return SHT20_PARSE_PARTIAL;
    }
    if (length != SHT20_RESPONSE_LENGTH) {
        return SHT20_PARSE_LENGTH_ERROR;
    }
    if (!valid_crc(frame, length)) {
        return SHT20_PARSE_CRC_ERROR;
    }

    const uint16_t raw_temperature = (uint16_t)((uint16_t)frame[3] << 8) |
                                     (uint16_t)frame[4];
    const uint16_t raw_humidity = (uint16_t)((uint16_t)frame[5] << 8) |
                                  (uint16_t)frame[6];
    if (raw_humidity > SHT20_MAX_HUMIDITY_TENTHS) {
        return SHT20_PARSE_HUMIDITY_RANGE;
    }
    /* Avoid an implementation-defined unsigned-to-signed conversion. */
    const int32_t signed_temperature = raw_temperature <= INT16_MAX
        ? (int32_t)raw_temperature : (int32_t)raw_temperature - 65536;
    const sht20_sample_t decoded = {
        .temperature_tenths_c = (int16_t)signed_temperature,
        .humidity_tenths_percent = raw_humidity,
    };
    *sample = decoded;
    return SHT20_PARSE_OK;
}

const char *sht20_parse_result_name(sht20_parse_result_t result)
{
    switch (result) {
    case SHT20_PARSE_OK:               return "OK";
    case SHT20_PARSE_NO_RX:            return "NO_RX";
    case SHT20_PARSE_CRC_ERROR:        return "CRC";
    case SHT20_PARSE_EXCEPTION:        return "EXCEPTION";
    case SHT20_PARSE_WRONG_UNIT:       return "WRONG_UNIT";
    case SHT20_PARSE_WRONG_FUNCTION:   return "WRONG_FUNCTION";
    case SHT20_PARSE_WRONG_BYTE_COUNT: return "WRONG_BYTE_COUNT";
    case SHT20_PARSE_PARTIAL:          return "PARTIAL";
    case SHT20_PARSE_LENGTH_ERROR:     return "LENGTH";
    case SHT20_PARSE_HUMIDITY_RANGE:   return "HUMIDITY_RANGE";
    case SHT20_PARSE_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    default:                         return "UNKNOWN";
    }
}
