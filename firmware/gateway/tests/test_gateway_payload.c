#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "gateway_payload.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main(void)
{
    char out[640];
    gateway_sample_t sample = { .seq=1, .captured_mono_ms=1000, .good=true,
        .values={.temperature_tenths_c=0,.humidity_tenths_percent=0} };
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1100,&sample)>0);
    puts(out);
    CHECK(strstr(out,"\"temperature_c\":0.0")!=NULL);
    CHECK(strstr(out,"\"time_valid\":false")!=NULL);
    CHECK(strstr(out,"\"sample_ts_utc\":null")!=NULL);
    CHECK(strstr(out,"\"sample_age_ms\":100")!=NULL);
    sample.seq=2; sample.time_valid=true;
    sample.values.temperature_tenths_c=-205;
    sample.values.humidity_tenths_percent=546;
    memcpy(sample.timestamp_utc,"2026-10-25T12:34:56.789Z",25);
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1200,&sample)>0);
    puts(out);
    CHECK(strstr(out,"\"temperature_c\":-20.5")!=NULL);
    CHECK(strstr(out,"\"humidity_pct\":54.6")!=NULL);
    sample.seq=3; sample.good=false; memcpy(sample.error,"CRC",4);
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1300,&sample)>0);
    puts(out);
    CHECK(strstr(out,"\"values\":null")!=NULL);
    CHECK(strstr(out,"\"sample_age_ms\":null")!=NULL);
    CHECK(strstr(out,"\"sample_ts_utc\":null")!=NULL);
    CHECK(strstr(out,"\"time_valid\":false")!=NULL);
    CHECK(strstr(out,"\"error\":\"CRC\"")!=NULL);
    sample.seq=4; sample.good=true; sample.time_valid=false;
    sample.values.temperature_tenths_c=-1;
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1400,&sample)>0);
    puts(out);
    CHECK(strstr(out,"\"temperature_c\":-0.1")!=NULL);
    CHECK(gateway_format_telemetry(out,5,"abcdef0123456789",1400,&sample)==0 && out[0]=='\0');
    sample.values.humidity_tenths_percent=1001;
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1400,&sample)==0);
    sample.values.humidity_tenths_percent=546;
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",999,&sample)==0);
    CHECK(gateway_format_telemetry(out,sizeof(out),"bad\"boot",1400,&sample)==0);
    sample.good=false; memcpy(sample.error,"bad\"error",10);
    CHECK(gateway_format_telemetry(out,sizeof(out),"abcdef0123456789",1400,&sample)==0);
    return 0;
}
