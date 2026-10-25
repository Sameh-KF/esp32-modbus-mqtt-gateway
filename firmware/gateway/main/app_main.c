#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "mqtt_client.h"
#include "nvs_flash.h"
#include "sdkconfig.h"
#include "sensor.h"
#include "gateway_payload.h"

#ifndef CONFIG_MQTT_USE_CUSTOM_CONFIG
#error "Enable MQTT custom config from sdkconfig.defaults."
#endif
#ifndef CONFIG_MQTT_REPORT_DELETED_MESSAGES
#error "MQTT deleted-message events are required to release the QoS1 slot."
#endif
#if CONFIG_MQTT_OUTBOX_EXPIRED_TIMEOUT_MS != 3000
#error "MQTT outbox expiry must be 3000 ms; remove stale sdkconfig values."
#endif
#define WIFI_UP BIT0
#define TOPIC_TELEMETRY "industrial/gw-01/telemetry"
#define TOPIC_AVAILABILITY "industrial/gw-01/availability"
#define TOPIC_DIAGNOSTICS "industrial/gw-01/diagnostics"
#define MAX_SEND_AGE_MS 2500U
#define OUTBOX_BYTES 2048U

static const char *TAG = "gateway";
static portMUX_TYPE state_lock = portMUX_INITIALIZER_UNLOCKED;
static EventGroupHandle_t network_bits;
static TaskHandle_t wifi_worker;
static gateway_sample_t latest;
static char boot_id[33];
static bool clock_synced;
static bool mqtt_connected;
static bool mqtt_disconnected;
static bool availability_confirmed;
static int inflight_kind;
static int inflight_id = -1;
static uint64_t inflight_since;
static int early_id[4] = { -1, -1, -1, -1 };
static unsigned early_index;
static uint64_t reads_ok, reads_bad, wifi_attempts, mqtt_attempts;
static uint64_t dropped, expired, acknowledgements, last_good_mono;

static uint64_t now_ms(void)
{
    return (uint64_t)esp_timer_get_time() / 1000U;
}

static gateway_sample_t sample_snapshot(void)
{
    gateway_sample_t sample;
    portENTER_CRITICAL(&state_lock);
    sample = latest;
    portEXIT_CRITICAL(&state_lock);
    return sample;
}

static void time_sync_event(struct timeval *tv)
{
    /* A real SNTP callback is required; a plausible boot clock alone is not. */
    const bool valid = tv != NULL && tv->tv_sec >= 1577836800;
    portENTER_CRITICAL(&state_lock);
    clock_synced = valid;
    portEXIT_CRITICAL(&state_lock);
    ESP_LOGI(TAG, "SNTP sync event time_valid=%u", valid ? 1U : 0U);
}

static void sensor_task(void *unused)
{
    (void)unused;
    sensor_init();
    uint64_t seq = 0;
    TickType_t next = xTaskGetTickCount();
    vTaskDelay(pdMS_TO_TICKS(2000));
    next = xTaskGetTickCount();
    for (;;) {
        const sensor_reading_t result = sensor_read();
        gateway_sample_t sample = { .seq = ++seq, .good = result.good,
            .captured_mono_ms = now_ms(), .values = result.values };
        bool synchronized;
        portENTER_CRITICAL(&state_lock);
        synchronized = clock_synced;
        portEXIT_CRITICAL(&state_lock);
        if (result.good && synchronized) {
            struct timeval tv;
            if (gettimeofday(&tv, NULL) == 0 && tv.tv_sec >= 1577836800) {
                struct tm utc;
                if (gmtime_r(&tv.tv_sec, &utc) != NULL) {
                    char seconds[20];
                    if (strftime(seconds, sizeof(seconds), "%Y-%m-%dT%H:%M:%S", &utc) == 19U) {
                        (void)snprintf(sample.timestamp_utc, sizeof(sample.timestamp_utc),
                            "%s.%03uZ", seconds, (unsigned)(tv.tv_usec / 1000) % 1000U);
                        sample.time_valid = true;
                    }
                }
            }
        }
        if (!result.good) {
            (void)snprintf(sample.error, sizeof(sample.error), "%s",
                           result.error != NULL ? result.error : "SENSOR_ERROR");
        }
        portENTER_CRITICAL(&state_lock);
        latest = sample; /* Exactly one latest read, including failures. */
        if (result.good) { ++reads_ok; last_good_mono = sample.captured_mono_ms; }
        else ++reads_bad;
        if (!mqtt_connected) ++dropped;
        portEXIT_CRITICAL(&state_lock);
        if (result.good) {
            ESP_LOGI(TAG, "READ seq=%" PRIu64 " GOOD temp=%.1f RH=%.1f time_valid=%u",
                seq, (double)result.values.temperature_tenths_c / 10.0,
                (double)result.values.humidity_tenths_percent / 10.0,
                sample.time_valid ? 1U : 0U);
        } else {
            ESP_LOGW(TAG, "READ seq=%" PRIu64 " BAD reason=%s rx=%u exception=%u",
                seq, sample.error, (unsigned)result.received_bytes, result.exception_code);
        }
        xTaskDelayUntil(&next, pdMS_TO_TICKS(2000));
    }
}

static void wifi_retry_task(void *unused)
{
    (void)unused;
    for (;;) {
        (void)ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        unsigned backoff = 1;
        while (!(xEventGroupGetBits(network_bits) & WIFI_UP)) {
            portENTER_CRITICAL(&state_lock); ++wifi_attempts; portEXIT_CRITICAL(&state_lock);
            const esp_err_t result = esp_wifi_connect();
            if (result != ESP_OK) ESP_LOGW(TAG, "WiFi connection attempt not started code=%d", (int)result);
            if (xEventGroupWaitBits(network_bits, WIFI_UP, pdFALSE, pdTRUE,
                pdMS_TO_TICKS(backoff * 1000U)) & WIFI_UP) break;
            backoff = backoff < 16U ? backoff * 2U : 30U;
        }
    }
}

static void network_event(void *unused, esp_event_base_t base, int32_t id, void *data)
{
    (void)unused; (void)data;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        xTaskNotifyGive(wifi_worker);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(network_bits, WIFI_UP);
        ESP_LOGW(TAG, "WiFi disconnected; background retry remains active");
        xTaskNotifyGive(wifi_worker);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        xEventGroupSetBits(network_bits, WIFI_UP);
        ESP_LOGI(TAG, "WiFi has IP; starting/restarting SNTP");
        const esp_err_t result = esp_netif_sntp_start();
        if (result != ESP_OK) ESP_LOGW(TAG, "SNTP start failed code=%d", (int)result);
    }
}

static void mqtt_event(void *unused, esp_event_base_t base, int32_t id, void *event_data)
{
    (void)unused; (void)base;
    esp_mqtt_event_handle_t event = event_data;
    if (id == MQTT_EVENT_CONNECTED) {
        portENTER_CRITICAL(&state_lock); mqtt_connected = true; mqtt_disconnected = false; availability_confirmed = false; portEXIT_CRITICAL(&state_lock);
        ESP_LOGI(TAG, "MQTT CONNECTED");
    } else if (id == MQTT_EVENT_DISCONNECTED) {
        portENTER_CRITICAL(&state_lock); mqtt_connected = false; mqtt_disconnected = true; portEXIT_CRITICAL(&state_lock);
        ESP_LOGW(TAG, "MQTT DISCONNECTED; old outbox will be destroyed before reconnect");
    } else if (id == MQTT_EVENT_PUBLISHED || id == MQTT_EVENT_DELETED) {
        const bool deleted = id == MQTT_EVENT_DELETED;
        portENTER_CRITICAL(&state_lock);
        if ((event->msg_id == inflight_id || inflight_id == -2) && inflight_kind == 1) {
            availability_confirmed = !deleted;
        }
        if (event->msg_id == inflight_id) {
            inflight_id = -1;
        } else if (inflight_id == -2) {
            early_id[early_index] = event->msg_id;
            early_index = (early_index + 1U) % 4U;
        }
        if (deleted) { ++expired; ++dropped; }
        else ++acknowledgements;
        portEXIT_CRITICAL(&state_lock);
        ESP_LOGI(TAG, "%s id=%d", deleted ? "OUTBOX_EXPIRED" : "PUBACK", event->msg_id);
    } else if (id == MQTT_EVENT_ERROR) {
        /* Do not print credentials, SSID, URI, or broker authentication data. */
        ESP_LOGW(TAG, "MQTT connection/transport error; awaiting disconnect/retry");
    }
}

/* Only the manager calls this. The one global slot covers ALL QoS1 topics.
 * -2 reserves the slot before publish, covering a PUBACK-before-return race.
 */
static bool publish_one(esp_mqtt_client_handle_t client, const char *topic,
                        const char *payload, int retain, int kind)
{
    portENTER_CRITICAL(&state_lock);
    const bool allowed = mqtt_connected && inflight_id == -1;
    if (allowed) {
        inflight_id = -2; inflight_kind = kind; inflight_since = now_ms();
        for (unsigned i = 0; i < 4U; ++i) early_id[i] = -1;
    }
    portEXIT_CRITICAL(&state_lock);
    if (!allowed) return false;
    const int id = esp_mqtt_client_publish(client, topic, payload, 0, 1, retain);
    portENTER_CRITICAL(&state_lock);
    bool already_finished = false;
    for (unsigned i = 0; i < 4U; ++i) if (early_id[i] == id && id >= 0) already_finished = true;
    inflight_id = id >= 0 && !already_finished ? id : -1;
    if (id < 0) ++dropped;
    portEXIT_CRITICAL(&state_lock);
    ESP_LOGI(TAG, "PUBLISH kind=%d id=%d qos=1 retain=%d", kind, id, retain);
    return id >= 0;
}

static void manager_task(void *unused)
{
    (void)unused;
    esp_mqtt_client_handle_t client = NULL;
    unsigned retry_seconds = 1;
    uint64_t reconnect_at = 0, connect_started = 0;
    uint64_t floor_seq = 0, considered_seq = 0, diagnostic_at = 0;
    bool session_ready = false;
    for (;;) {
        const uint64_t now = now_ms();
        const bool wifi_up = (xEventGroupGetBits(network_bits) & WIFI_UP) != 0;
        bool connected, disconnected, availability_ready;
        int pending;
        uint64_t pending_since;
        portENTER_CRITICAL(&state_lock);
        connected = mqtt_connected; disconnected = mqtt_disconnected;
        availability_ready = availability_confirmed;
        pending = inflight_id; pending_since = inflight_since;
        portEXIT_CRITICAL(&state_lock);
        if (client != NULL && (disconnected || !wifi_up ||
            (!connected && now - connect_started > 15000U))) {
            /* No automatic reconnect: discard that session's RAM outbox before
             * ever creating the next client. A dropped WiFi link keeps LWT useful.
             */
            (void)esp_mqtt_client_stop(client);
            (void)esp_mqtt_client_destroy(client);
            client = NULL;
            portENTER_CRITICAL(&state_lock);
            if (inflight_id != -1) ++dropped;
            inflight_id = -1; mqtt_connected = false; mqtt_disconnected = false;
            portEXIT_CRITICAL(&state_lock);
            session_ready = false;
            reconnect_at = now_ms() + (uint64_t)retry_seconds * 1000U;
            retry_seconds = retry_seconds < 16U ? retry_seconds * 2U : 30U;
        }
        if (client == NULL && wifi_up && now >= reconnect_at) {
            const esp_mqtt_client_config_t config = {
                .broker.address.uri = CONFIG_APP_MQTT_URI,
                .credentials.username = CONFIG_APP_MQTT_USERNAME,
                .credentials.client_id = "industrial-gw-01",
                .credentials.authentication.password = CONFIG_APP_MQTT_PASSWORD,
                .session.last_will = { .topic = TOPIC_AVAILABILITY, .msg = "offline", .qos = 1, .retain = 1 },
                .session.keepalive = 15,
                .session.message_retransmit_timeout = 10000,
                .network.disable_auto_reconnect = true,
                .network.timeout_ms = 2000,
                .buffer.size = 1024,
                .buffer.out_size = 1024,
                .outbox.limit = OUTBOX_BYTES,
            };
            portENTER_CRITICAL(&state_lock); ++mqtt_attempts; mqtt_disconnected = false; portEXIT_CRITICAL(&state_lock);
            client = esp_mqtt_client_init(&config);
            if (client == NULL) {
                reconnect_at = now + (uint64_t)retry_seconds * 1000U;
                retry_seconds = retry_seconds < 16U ? retry_seconds * 2U : 30U;
            } else {
                ESP_ERROR_CHECK(esp_mqtt_client_register_event(client, ESP_EVENT_ANY_ID, mqtt_event, NULL));
                connect_started = now;
                if (esp_mqtt_client_start(client) != ESP_OK) {
                    (void)esp_mqtt_client_destroy(client); client = NULL;
                    reconnect_at = now + (uint64_t)retry_seconds * 1000U;
                }
            }
        }
        if (client != NULL && connected) {
            if (!session_ready) {
                floor_seq = sample_snapshot().seq;
                considered_seq = floor_seq;
                session_ready = publish_one(client, TOPIC_AVAILABILITY, "online", 1, 1);
                diagnostic_at = now + 30000U;
                retry_seconds = 1;
            } else if (pending == -1) {
                if (!availability_ready) {
                    (void)publish_one(client, TOPIC_AVAILABILITY, "online", 1, 1);
                } else {
                const gateway_sample_t sample = sample_snapshot();
                if (sample.seq > floor_seq && sample.seq > considered_seq) {
                    considered_seq = sample.seq;
                    char payload[640];
                    if (now >= sample.captured_mono_ms &&
                        now - sample.captured_mono_ms <= MAX_SEND_AGE_MS &&
                        gateway_format_telemetry(payload, sizeof(payload), boot_id, now, &sample) != 0) {
                        (void)publish_one(client, TOPIC_TELEMETRY, payload, 0, 2);
                    } else {
                        portENTER_CRITICAL(&state_lock); ++dropped; portEXIT_CRITICAL(&state_lock);
                    }
                } else if (now >= diagnostic_at) {
                    char payload[512];
                    portENTER_CRITICAL(&state_lock);
                    const uint64_t ok = reads_ok, bad = reads_bad, wa = wifi_attempts, ma = mqtt_attempts;
                    const uint64_t drop = dropped, exp = expired, ack = acknowledgements, good_at = last_good_mono;
                    portEXIT_CRITICAL(&state_lock);
                    char age[32] = "null";
                    if (good_at != 0 && now >= good_at) (void)snprintf(age, sizeof(age), "%" PRIu64, now - good_at);
                    (void)snprintf(payload, sizeof(payload),
                        "{\"uptime_ms\":%" PRIu64 ",\"read_success\":%" PRIu64 ",\"read_error\":%" PRIu64
                        ",\"wifi_attempts\":%" PRIu64 ",\"mqtt_attempts\":%" PRIu64 ",\"dropped\":%" PRIu64
                        ",\"expired\":%" PRIu64 ",\"puback\":%" PRIu64 ",\"last_good_age_ms\":%s,\"free_heap_bytes\":%u}",
                        now, ok, bad, wa, ma, drop, exp, ack, age, (unsigned)esp_get_free_heap_size());
                    (void)publish_one(client, TOPIC_DIAGNOSTICS, payload, 0, 3);
                    diagnostic_at = now + 30000U;
                }
                }
            } else {
                const uint64_t seq = sample_snapshot().seq;
                if (seq > considered_seq) {
                    considered_seq = seq;
                    portENTER_CRITICAL(&state_lock); ++dropped; portEXIT_CRITICAL(&state_lock);
                }
                /* Expiry is 3000 ms. A zero outbox after its terminal event was
                 * lost still safely frees the application slot; never duplicate.
                 */
                if (pending >= 0 && now - pending_since > 5000U &&
                    esp_mqtt_client_get_outbox_size(client) == 0) {
                    portENTER_CRITICAL(&state_lock);
                    if (inflight_id == pending) { inflight_id = -1; ++expired; ++dropped; }
                    portEXIT_CRITICAL(&state_lock);
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void app_main(void)
{
    esp_log_level_set("wifi", ESP_LOG_WARN);
    esp_log_level_set("mqtt_client", ESP_LOG_WARN);
    for (unsigned i = 0; i < 4U; ++i) {
        (void)snprintf(boot_id + i * 8U, 9U, "%08" PRIx32, esp_random());
    }
    network_bits = xEventGroupCreate();
    ESP_ERROR_CHECK(network_bits != NULL ? ESP_OK : ESP_ERR_NO_MEM);
    /* Sensor polling is launched before network initialization. */
    BaseType_t created = xTaskCreate(sensor_task, "sensor", 4096, NULL, 5, NULL);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    esp_err_t nvs = nvs_flash_init();
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        nvs = nvs_flash_init();
    }
    ESP_ERROR_CHECK(nvs);
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *station = esp_netif_create_default_wifi_sta();
    ESP_ERROR_CHECK(station != NULL ? ESP_OK : ESP_ERR_NO_MEM);
    esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG(CONFIG_APP_SNTP_SERVER);
    sntp.start = false;
    sntp.sync_cb = time_sync_event;
    ESP_ERROR_CHECK(esp_netif_sntp_init(&sntp));
    const wifi_init_config_t initial = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&initial));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_event, NULL));
    wifi_config_t wifi = {0};
    const size_t ssid_length = strlen(CONFIG_ESP_WIFI_SSID);
    const size_t password_length = strlen(CONFIG_ESP_WIFI_PASSWORD);
    if (ssid_length > sizeof(wifi.sta.ssid) || password_length > sizeof(wifi.sta.password)) {
        ESP_LOGE(TAG, "WiFi configuration length invalid; sensor task continues without network");
        return;
    }
    memcpy(wifi.sta.ssid, CONFIG_ESP_WIFI_SSID, ssid_length);
    memcpy(wifi.sta.password, CONFIG_ESP_WIFI_PASSWORD, password_length);
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi));
    created = xTaskCreate(wifi_retry_task, "wifi_retry", 3072, NULL, 4, &wifi_worker);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    created = xTaskCreate(manager_task, "mqtt_manager", 6144, NULL, 4, NULL);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "MQTT POLICY effective_expiry_ms=%d deleted_events=1 total_QoS1_slots=1 outbox_bytes=%u retransmit_ms=10000 auto_reconnect=0",
        CONFIG_MQTT_OUTBOX_EXPIRED_TIMEOUT_MS, OUTBOX_BYTES);
    ESP_LOGI(TAG, "READY project=industrial_gateway boot_id=%s sensor=hardware UART1 TX17 RX18; telemetry 2s; QoS1 slot=1 outbox=2048 keepalive=15", boot_id);
}
