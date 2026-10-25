#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <limits.h>
#include "sht20_protocol.h"

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL line %u: %s\n", (unsigned)__LINE__, #x); exit(1); } } while (0)
static void set_crc(uint8_t *frame, size_t length)
{
    const uint16_t crc = sht20_crc16(frame, length - 2U);
    frame[length - 2U] = (uint8_t)crc;
    frame[length - 1U] = (uint8_t)(crc >> 8);
}
static void expect_error(const uint8_t *frame, size_t length, uint8_t unit,
                         sht20_parse_result_t expected)
{
    sht20_sample_t sample = { 12345, 54321 };
    uint8_t exception = 0xA5;
    const sht20_parse_result_t result = sht20_parse_response(frame, length, unit, &sample, &exception);
    CHECK(result == expected);
    CHECK(sample.temperature_tenths_c == 12345 && sample.humidity_tenths_percent == 54321);
    CHECK(exception == (expected == SHT20_PARSE_EXCEPTION ? 2U : 0xA5U));
}
static uint32_t next_random(uint32_t *state)
{
    *state = *state * 1664525U + 1013904223U;
    return *state;
}
int main(void)
{
    const uint8_t request_expected[] = { 0x01,0x04,0x00,0x01,0x00,0x02,0x20,0x0B };
    const uint8_t positive[] = { 0x01,0x04,0x04,0x01,0x31,0x02,0x22,0x2A,0xCE };
    const uint8_t negative[] = { 0x01,0x04,0x04,0xFF,0x33,0x02,0x22,0xBA,0xE6 };
    const uint8_t exception[] = { 0x01,0x84,0x02,0xC2,0xC1 };
    uint8_t frame[256] = {0};
    uint8_t request[SHT20_REQUEST_LENGTH];
    sht20_sample_t sample = {0};
    uint8_t exception_code = 0xA5;
    CHECK(sht20_crc16(NULL, 0) == 0xFFFFU);
    CHECK(sht20_crc16((const uint8_t *)"123456789", 9) == 0x4B37U);
    CHECK(sht20_build_request(1, request) == SHT20_REQUEST_LENGTH);
    CHECK(memcmp(request, request_expected, sizeof(request)) == 0);
    CHECK(sht20_crc16(request, sizeof(request)) == 0);
    CHECK(sht20_build_request(0, request) == 0);
    CHECK(sht20_build_request(248, request) == 0);
    CHECK(sht20_build_request(1, NULL) == 0);
    CHECK(sht20_build_request(247, request) == SHT20_REQUEST_LENGTH && request[0] == 247);
    CHECK(sht20_crc16(request, sizeof(request)) == 0);
    CHECK(sht20_parse_response(positive, sizeof(positive), 1, &sample, &exception_code) == SHT20_PARSE_OK);
    CHECK(sample.temperature_tenths_c == 305 && sample.humidity_tenths_percent == 546);
    CHECK(exception_code == 0xA5);
    CHECK(sht20_parse_response(negative, sizeof(negative), 1, &sample, NULL) == SHT20_PARSE_OK);
    CHECK(sample.temperature_tenths_c == -205 && sample.humidity_tenths_percent == 546);
    expect_error(exception, sizeof(exception), 1, SHT20_PARSE_EXCEPTION);
    CHECK(sht20_parse_response(exception, sizeof(exception), 1, &sample, NULL) == SHT20_PARSE_EXCEPTION);
    expect_error(NULL, 0, 1, SHT20_PARSE_NO_RX);
    expect_error(NULL, 1, 1, SHT20_PARSE_INVALID_ARGUMENT);
    expect_error(positive, sizeof(positive), 0, SHT20_PARSE_INVALID_ARGUMENT);
    expect_error(positive, sizeof(positive), 248, SHT20_PARSE_INVALID_ARGUMENT);
    CHECK(sht20_parse_response(positive, sizeof(positive), 1, NULL, NULL) == SHT20_PARSE_INVALID_ARGUMENT);
    expect_error(positive, 1, 1, SHT20_PARSE_PARTIAL);
    expect_error(positive, 2, 1, SHT20_PARSE_PARTIAL);
    expect_error(positive, 3, 1, SHT20_PARSE_PARTIAL);
    expect_error(positive, 8, 1, SHT20_PARSE_PARTIAL);
    expect_error(exception, 4, 1, SHT20_PARSE_PARTIAL);
    memcpy(frame, positive, sizeof(positive)); frame[9] = 0;
    expect_error(frame, 10, 1, SHT20_PARSE_LENGTH_ERROR);
    memcpy(frame, exception, sizeof(exception)); frame[5] = 0;
    expect_error(frame, 6, 1, SHT20_PARSE_LENGTH_ERROR);
    memcpy(frame, positive, sizeof(positive)); frame[0] = 2; set_crc(frame, 9);
    expect_error(frame, 9, 1, SHT20_PARSE_WRONG_UNIT);
    memcpy(frame, positive, sizeof(positive)); frame[1] = 3; set_crc(frame, 9);
    expect_error(frame, 9, 1, SHT20_PARSE_WRONG_FUNCTION);
    memcpy(frame, positive, sizeof(positive)); frame[2] = 2; set_crc(frame, 9);
    expect_error(frame, 9, 1, SHT20_PARSE_WRONG_BYTE_COUNT);
    memcpy(frame, positive, sizeof(positive)); frame[8] ^= 1;
    expect_error(frame, 9, 1, SHT20_PARSE_CRC_ERROR);
    memcpy(frame, exception, sizeof(exception)); frame[4] ^= 1;
    expect_error(frame, 5, 1, SHT20_PARSE_CRC_ERROR);
    expect_error(request_expected, sizeof(request_expected), 1, SHT20_PARSE_WRONG_BYTE_COUNT);
    memcpy(frame, positive, sizeof(positive)); frame[5] = 0x03; frame[6] = 0xE9; set_crc(frame, 9);
    expect_error(frame, 9, 1, SHT20_PARSE_HUMIDITY_RANGE);
    frame[6] = 0xE8; set_crc(frame, 9);
    CHECK(sht20_parse_response(frame, 9, 1, &sample, NULL) == SHT20_PARSE_OK);
    CHECK(sample.humidity_tenths_percent == 1000);
    frame[3] = 0x80; frame[4] = 0; frame[5] = 0; frame[6] = 0; set_crc(frame, 9);
    CHECK(sht20_parse_response(frame, 9, 1, &sample, NULL) == SHT20_PARSE_OK);
    CHECK(sample.temperature_tenths_c == INT16_MIN && sample.humidity_tenths_percent == 0);
    frame[3] = 0x7F; frame[4] = 0xFF; set_crc(frame, 9);
    CHECK(sht20_parse_response(frame, 9, 1, &sample, NULL) == SHT20_PARSE_OK);
    CHECK(sample.temperature_tenths_c == INT16_MAX);
    frame[3] = frame[4] = 0; set_crc(frame, 9);
    CHECK(sht20_parse_response(frame, 9, 1, &sample, NULL) == SHT20_PARSE_OK);
    CHECK(sample.temperature_tenths_c == 0 && sample.humidity_tenths_percent == 0);
    frame[0] = 0xFF; memcpy(frame + 1, positive, sizeof(positive));
    expect_error(frame, 10, 1, SHT20_PARSE_WRONG_UNIT);
    memcpy(frame, positive, sizeof(positive)); memcpy(frame + 9, positive, sizeof(positive));
    expect_error(frame, 18, 1, SHT20_PARSE_LENGTH_ERROR);
    for (unsigned bit = 0; bit < sizeof(positive) * 8U; ++bit) {
        memcpy(frame, positive, sizeof(positive));
        frame[bit / 8U] ^= (uint8_t)(1U << (bit % 8U));
        sample.temperature_tenths_c = 12345; sample.humidity_tenths_percent = 54321;
        CHECK(sht20_parse_response(frame, sizeof(positive), 1, &sample, NULL) != SHT20_PARSE_OK);
        CHECK(sample.temperature_tenths_c == 12345 && sample.humidity_tenths_percent == 54321);
    }
    uint32_t state = 0xD95D42ACU;
    for (unsigned round = 0; round < 20000U; ++round) {
        const uint16_t raw = (uint16_t)(next_random(&state) >> 16);
        const uint16_t humidity = (uint16_t)(next_random(&state) % 1001U);
        const uint8_t unit = (uint8_t)(1U + next_random(&state) % 247U);
        frame[0] = unit; frame[1] = 4; frame[2] = 4;
        frame[3] = (uint8_t)(raw >> 8); frame[4] = (uint8_t)raw;
        frame[5] = (uint8_t)(humidity >> 8); frame[6] = (uint8_t)humidity; set_crc(frame, 9);
        CHECK(sht20_parse_response(frame, 9, unit, &sample, NULL) == SHT20_PARSE_OK);
        CHECK(sample.temperature_tenths_c == (raw <= INT16_MAX ? (int32_t)raw : (int32_t)raw - 65536));
        CHECK(sample.humidity_tenths_percent == humidity);
    }
    for (unsigned round = 0; round < 20000U; ++round) {
        const size_t length = next_random(&state) % (sizeof(frame) + 1U);
        for (size_t i = 0; i < length; ++i) frame[i] = (uint8_t)(next_random(&state) >> 24);
        sample.temperature_tenths_c = 12345; sample.humidity_tenths_percent = 54321;
        const sht20_parse_result_t parsed = sht20_parse_response(frame, length, 1, &sample, NULL);
        CHECK(parsed >= SHT20_PARSE_OK && parsed <= SHT20_PARSE_INVALID_ARGUMENT);
        if (parsed != SHT20_PARSE_OK) CHECK(sample.temperature_tenths_c == 12345 && sample.humidity_tenths_percent == 54321);
        else CHECK(sample.humidity_tenths_percent <= 1000);
    }
    CHECK(strcmp(sht20_parse_result_name(SHT20_PARSE_OK), "OK") == 0);
    CHECK(strcmp(sht20_parse_result_name(SHT20_PARSE_CRC_ERROR), "CRC") == 0);
    CHECK(strcmp(sht20_parse_result_name((sht20_parse_result_t)999), "UNKNOWN") == 0);
    printf("PASS: %u assertions; 20,000 generated valid frames; 20,000 random frames; 72 single-bit corruption cases.\n", checks);
    return 0;
}
