#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include "sht20_protocol.h"
#include "sensor.h"
#include "soc/uart_reg.h"

#if !CONFIG_IDF_TARGET_ESP32S3
#error "Select ESP32-S3 in the Espressif extension, then reconfigure."
#endif
#if CONFIG_ESP_CONSOLE_UART_NUM != 0
#error "This test needs a separate UART0 console on COM9."
#endif

#define SENSOR_UART             UART_NUM_1
#define SENSOR_TX_GPIO          17
#define SENSOR_RX_GPIO          18
#define SENSOR_BAUD              9600
#define RX_DRIVER_BYTES          1024
#define RX_CAPTURE_BYTES         256U
#define RAW_CHUNK_BYTES          64U
#define UART_EVENT_QUEUE_LENGTH  20
#define RX_TIMEOUT_SYMBOLS       4U
#define RX_TIMEOUT_MS            1500U
#define TX_TIMEOUT_MS            200U
#define PRE_TX_TIMEOUT_MS        200U
#define RTU_SILENCE_MS           5U
#define STARTUP_DELAY_MS         2000U
#define SAMPLE_PERIOD_MS         2000U
#define SAMPLE_COUNT             10U

static const char *TAG = "gateway_sensor";
static QueueHandle_t uart_events;

typedef struct {
    sht20_parse_result_t protocol;
    const char *transport_error;
    sht20_sample_t sample;
    uint8_t exception_code;
    size_t captured_bytes;
    bool echo_removed;
} reading_t;

/* Round up, so a 5 ms interval never becomes zero at the default 100 Hz. */
static TickType_t ticks_for_ms(uint32_t ms)
{
    const TickType_t ticks = (TickType_t)(
        ((uint64_t)ms * (uint64_t)configTICK_RATE_HZ + 999U) / 1000U);
    return ticks != 0 ? ticks : 1;
}

static TickType_t elapsed_since(TickType_t started)
{
    /* Correct across the unsigned FreeRTOS tick wrap for these short windows. */
    return (TickType_t)(xTaskGetTickCount() - started);
}

static void log_hex(const char *label, const uint8_t *data, size_t length)
{
    static const char digits[] = "0123456789ABCDEF";
    char line[RAW_CHUNK_BYTES * 3U + 1U];
    for (size_t offset = 0; offset < length; offset += RAW_CHUNK_BYTES) {
        const size_t left = length - offset;
        const size_t count = left < RAW_CHUNK_BYTES ? left : RAW_CHUNK_BYTES;
        size_t at = 0;
        for (size_t i = 0; i < count; ++i) {
            const uint8_t value = data[offset + i];
            line[at++] = digits[value >> 4];
            line[at++] = digits[value & 0x0FU];
            line[at++] = ' ';
        }
        line[at] = '\0';
        ESP_LOGI(TAG, "%s RAW (%u) HEX: %s", label, (unsigned)count, line);
    }
}

static void init_sensor_uart(void)
{
    const uart_config_t config = {
        .baud_rate = SENSOR_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_param_config(SENSOR_UART, &config));
    ESP_ERROR_CHECK(uart_set_pin(SENSOR_UART, SENSOR_TX_GPIO, SENSOR_RX_GPIO,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(SENSOR_UART, RX_DRIVER_BYTES, 0,
                                        UART_EVENT_QUEUE_LENGTH, &uart_events, 0));
    /* This particular XY module switches direction internally. No DE/RE pin. */
    ESP_ERROR_CHECK(uart_set_mode(SENSOR_UART, UART_MODE_UART));
    ESP_ERROR_CHECK(uart_set_rx_full_threshold(SENSOR_UART, 64));
    /* UART hardware marks the end of a receive burst. Preserve that boundary
     * with UART_DATA.timeout_flag; never append a later burst to a partial frame.
     * At 9600 baud, four symbol periods are approximately 4-5 ms.
     */
    ESP_ERROR_CHECK(uart_set_rx_timeout(SENSOR_UART, RX_TIMEOUT_SYMBOLS));
    ESP_ERROR_CHECK(uart_enable_intr_mask(SENSOR_UART, UART_FRM_ERR_INT_ENA_M));
}

static const char *uart_event_error(uart_event_type_t type)
{
    switch (type) {
    case UART_FIFO_OVF:    return "UART_FIFO_OVERFLOW";
    case UART_BUFFER_FULL: return "UART_BUFFER_FULL";
    case UART_FRAME_ERR:   return "UART_FRAME_ERROR";
    case UART_PARITY_ERR:  return "UART_PARITY_ERROR";
    case UART_BREAK:       return "UART_BREAK";
    default:              return NULL;
    }
}

/* Drain/log old data BEFORE the next request. No blind uart_flush_input().
 * One extra tick compensates for tick quantization, so the actual silence is
 * at least 5 ms even at a 100 Hz scheduler rate. Continuous traffic is a failure.
 */
static const char *prepare_bus(void)
{
    const TickType_t started = xTaskGetTickCount();
    TickType_t quiet_since = started;
    const TickType_t quiet_ticks = ticks_for_ms(RTU_SILENCE_MS) + 1U;
    uint8_t chunk[RAW_CHUNK_BYTES];
    size_t discarded = 0;

    while (elapsed_since(started) < ticks_for_ms(PRE_TX_TIMEOUT_MS)) {
        uart_event_t old_event;
        while (xQueueReceive(uart_events, &old_event, 0) == pdTRUE) {
            const char *old_error = uart_event_error(old_event.type);
            if (old_error != NULL) {
                ESP_LOGW(TAG, "PRE_TX previous UART event: %s", old_error);
            }
        }
        const size_t left = RX_CAPTURE_BYTES - discarded;
        const size_t wanted = left < sizeof(chunk) ? left : sizeof(chunk);
        if (wanted == 0U) {
            return "BUS_BUSY_CAPTURE_LIMIT";
        }
        const int count = uart_read_bytes(SENSOR_UART, chunk, (uint32_t)wanted, 0);
        if (count < 0) {
            return "UART_READ_ERROR";
        }
        if (count > 0) {
            log_hex("RX PRE_TX DISCARD", chunk, (size_t)count);
            discarded += (size_t)count;
            quiet_since = xTaskGetTickCount();
        } else if (elapsed_since(quiet_since) >= quiet_ticks) {
            return NULL;
        }
        vTaskDelay(1);
    }
    return "BUS_BUSY_NO_SILENCE";
}

/* Save and display a bounded UART event, including malformed response bytes. */
static bool read_event_bytes(size_t event_bytes, uint8_t *frame,
                             size_t *frame_length, reading_t *reading)
{
    while (event_bytes > 0U) {
        const size_t room = RX_CAPTURE_BYTES - reading->captured_bytes;
        if (room == 0U) {
            reading->transport_error = "RX_CAPTURE_LIMIT";
            return false;
        }
        size_t wanted = event_bytes < RAW_CHUNK_BYTES ? event_bytes : RAW_CHUNK_BYTES;
        if (wanted > room) {
            wanted = room;
        }
        const int count = uart_read_bytes(SENSOR_UART, frame + *frame_length,
                                          (uint32_t)wanted, 0);
        if (count > 0) {
            log_hex("RX", frame + *frame_length, (size_t)count);
            *frame_length += (size_t)count;
            reading->captured_bytes += (size_t)count;
            event_bytes -= (size_t)count;
        }
        if (count < 0 || (size_t)count != wanted) {
            reading->transport_error = "UART_READ_ERROR";
            return false;
        }
    }
    return true;
}

/* The IDF ISR can enqueue UART_DATA before FRAME_ERR/PARITY/OVERFLOW for
 * the same interrupt snapshot. End-of-burst alone is not enough for GOOD.
 * Let that ISR finish, then inspect pending events without merging a second
 * burst into the frame already parsed. Additional data is logged but BAD.
 */
static void inspect_boundary_events(uint8_t *frame, size_t *length,
                                     reading_t *reading)
{
    vTaskDelay(1);
    uart_event_t event;
    unsigned inspected = 0;
    while (inspected < UART_EVENT_QUEUE_LENGTH &&
           xQueueReceive(uart_events, &event, 0) == pdTRUE) {
        ++inspected;
        if (event.type == UART_DATA && event.size > 0U) {
            if (reading->transport_error == NULL) {
                reading->transport_error = "RX_EXTRA_BURST";
            }
            /* The first frame has already been parsed. This storage is only
             * for bounded raw logging; these bytes are never parsed together.
             */
            if (!read_event_bytes(event.size, frame, length, reading)) {
                return;
            }
        } else {
            const char *error = uart_event_error(event.type);
            if (error != NULL) {
                reading->transport_error = error;
            }
        }
    }
    if (inspected == UART_EVENT_QUEUE_LENGTH &&
        reading->transport_error == NULL) {
        reading->transport_error = "UART_EVENT_BACKLOG";
    }
}
static reading_t receive_response(const uint8_t request[SHT20_REQUEST_LENGTH],
                                   TickType_t transaction_started)
{
    reading_t reading = { .protocol = SHT20_PARSE_NO_RX };
    uint8_t frame[RX_CAPTURE_BYTES];
    size_t length = 0;
    const TickType_t timeout = ticks_for_ms(RX_TIMEOUT_MS);

    while (elapsed_since(transaction_started) < timeout) {
        const TickType_t elapsed = elapsed_since(transaction_started);
        if (elapsed >= timeout) {
            break;
        }
        uart_event_t event;
        if (xQueueReceive(uart_events, &event, timeout - elapsed) != pdTRUE) {
            break;
        }
        if (event.type == UART_DATA) {
            if (!read_event_bytes(event.size, frame, &length, &reading)) {
                return reading;
            }
            /* Ignore exactly one complete local request echo, whether it is
             * its own UART burst or immediately precedes the response.
             * A matching two-byte prefix or a truncated echo is NOT enough.
             */
            if (!reading.echo_removed && length >= SHT20_REQUEST_LENGTH &&
                memcmp(frame, request, SHT20_REQUEST_LENGTH) == 0) {
                length -= SHT20_REQUEST_LENGTH;
                memmove(frame, frame + SHT20_REQUEST_LENGTH, length);
                reading.echo_removed = true;
                ESP_LOGW(TAG, "LOCAL_ECHO exact request ignored (8 bytes)");
            }
            if (elapsed_since(transaction_started) >= timeout) {
                reading.transport_error = "RX_DEADLINE";
                reading.protocol = sht20_parse_response(
                    frame, length, SHT20_DEFAULT_UNIT, &reading.sample,
                    &reading.exception_code);
                return reading; /* Even a valid late frame cannot become GOOD. */
            }
            if (event.timeout_flag && length > 0U) {
                reading.protocol = sht20_parse_response(
                    frame, length, SHT20_DEFAULT_UNIT, &reading.sample,
                    &reading.exception_code);
                inspect_boundary_events(frame, &length, &reading);
                if (elapsed_since(transaction_started) >= timeout &&
                    reading.transport_error == NULL) {
                    reading.transport_error = "RX_DEADLINE";
                }
                return reading;
            }
        } else {
            const char *error = uart_event_error(event.type);
            if (error != NULL) {
                /* Display any bytes already buffered before reporting damage
                 * to UART framing/overflow; never turn that burst into GOOD.
                 */
                size_t buffered = 0;
                if (uart_get_buffered_data_len(SENSOR_UART, &buffered) == ESP_OK) {
                    (void)read_event_bytes(buffered, frame, &length, &reading);
                }
                reading.transport_error = error;
                return reading;
            }
        }
    }
    /* Diagnose buffered bytes even if their UART_DATA event was lost. Keep
     * orphan data BAD: no end-of-frame event, no verified sample boundary.
     */
    size_t buffered = 0;
    if (uart_get_buffered_data_len(SENSOR_UART, &buffered) != ESP_OK) {
        reading.transport_error = "UART_BUFFER_QUERY_ERROR";
    } else if (buffered > 0U) {
        (void)read_event_bytes(buffered, frame, &length, &reading);
        if (reading.transport_error == NULL) reading.transport_error = "RX_ORPHAN_BYTES";
    }
    reading.protocol = sht20_parse_response(
        frame, length, SHT20_DEFAULT_UNIT, &reading.sample, &reading.exception_code);
    if ((reading.protocol == SHT20_PARSE_OK ||
         reading.protocol == SHT20_PARSE_EXCEPTION) && reading.transport_error == NULL) {
        /* No hardware end-of-burst was seen before the monotonic deadline. */
        reading.transport_error = "RX_TIMEOUT_NO_FRAME_END";
    }
    return reading;
}

static reading_t read_sample(const uint8_t request[SHT20_REQUEST_LENGTH])
{
    reading_t reading = { .protocol = SHT20_PARSE_NO_RX };
    reading.transport_error = prepare_bus();
    if (reading.transport_error != NULL) {
        return reading;
    }
    log_hex("TX", request, SHT20_REQUEST_LENGTH);
    const TickType_t transaction_started = xTaskGetTickCount();
    const int sent = uart_write_bytes(SENSOR_UART, request, SHT20_REQUEST_LENGTH);
    const esp_err_t tx_done = uart_wait_tx_done(
        SENSOR_UART, ticks_for_ms(TX_TIMEOUT_MS));
    if (sent != (int)SHT20_REQUEST_LENGTH || tx_done != ESP_OK) {
        ESP_LOGE(TAG, "TX error: queued=%d/8, tx_done=%s", sent,
                 esp_err_to_name(tx_done));
        reading.transport_error = "TX_ERROR";
        return reading;
    }
    return receive_response(request, transaction_started);
}

void sensor_init(void)
{
    init_sensor_uart();
    ESP_LOGI(TAG, "READY UART1 TX17 RX18 9600 8N1 FC04 raw1 count2 unit1; XY 3V3 auto direction");
}

sensor_reading_t sensor_read(void)
{
    uint8_t request[SHT20_REQUEST_LENGTH];
    if (sht20_build_request(SHT20_DEFAULT_UNIT, request) != SHT20_REQUEST_LENGTH) {
        return (sensor_reading_t){ .error = "INVALID_REQUEST" };
    }
    const reading_t result = read_sample(request);
    return (sensor_reading_t){
        .good = result.transport_error == NULL && result.protocol == SHT20_PARSE_OK,
        .values = result.sample,
        .error = result.transport_error != NULL ? result.transport_error
            : (result.protocol == SHT20_PARSE_OK ? NULL : sht20_parse_result_name(result.protocol)),
        .received_bytes = result.captured_bytes,
        .exception_code = result.exception_code,
    };
}
