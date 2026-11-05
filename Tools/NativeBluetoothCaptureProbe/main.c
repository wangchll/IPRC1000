/* Native service probe: system frameworks only; optional target filtering, no payload storage. */
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <Security/Authorization.h>
#include "NativePacketFilter.h"

static int parse_address(const char *text, uint8_t address[6]) {
    unsigned values[6];
    int end = 0;
    if (sscanf(text, "%2x:%2x:%2x:%2x:%2x:%2x%n", &values[0], &values[1],
        &values[2], &values[3], &values[4], &values[5], &end) != 6 || text[end]) return 0;
    for (unsigned i = 0; i < 6; i++) address[i] = values[i];
    return 1;
}

int main(int argc, const char *argv[]) {
    int authorize = 0, check = 0, target = 0, interactive = 0;
    unsigned seconds = 2;
    uint8_t address[6] = {0};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--authorize")) authorize = 1;
        else if (!strcmp(argv[i], "--check-authorization")) check = 1;
        else if (!strcmp(argv[i], "--interactive")) interactive = 1;
        else if (!strcmp(argv[i], "--target") && i + 1 < argc) {
            if (!parse_address(argv[++i], address)) return 64;
            target = 1;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            char *end = NULL;
            unsigned long value = strtoul(argv[++i], &end, 10);
            if (*end || !value || value > 900) return 64;
            seconds = (unsigned)value;
        } else return 64;
    }
    if (authorize && check) return 64;
    AuthorizationRef authorization = NULL;
    AuthorizationExternalForm external = {0};
    if (authorize || check) {
        OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorization);
        AuthorizationItem item = {"com.apple.PacketLogger.HCI", 0, NULL, 0};
        AuthorizationRights rights = {1, &item};
        if (status == errAuthorizationSuccess) {
            AuthorizationFlags flags = kAuthorizationFlagExtendRights;
            if (authorize) flags |= kAuthorizationFlagInteractionAllowed;
            status = AuthorizationCopyRights(authorization, &rights, kAuthorizationEmptyEnvironment, flags, NULL);
        }
        printf("Native capture AuthorizationCopyRights status=%d (policy not modified)\n", (int)status);
        fflush(stdout);
        if (status != errAuthorizationSuccess || check) {
            if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDefaults);
            return status == errAuthorizationSuccess ? 0 : 5;
        }
        status = AuthorizationMakeExternalForm(authorization, &external);
        if (status != errAuthorizationSuccess) {
            AuthorizationFree(authorization, kAuthorizationFlagDefaults);
            return 5;
        }
    }
    do {
    if (interactive) {
        puts("IDLE: no capture connection; s starts one bounded window, q/EOF exits");
        fflush(stdout);
        int command;
        do { command = getchar(); } while (command == '\n' || command == '\r');
        if (command != 's') break;
    }
    dispatch_queue_t queue = dispatch_queue_create("local.iprc1000.native-probe", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block int stopped = 0;
    __block unsigned packets = 0, replies = 0, errors = 0;
    __block unsigned target_voice_frames = 0;
    __block unsigned last_packets = 0;
    __block IPRCNativeFilter filter;
    iprc_native_filter_init(&filter, address);
    __block int requires_auth = -1;
    __block int authentication_sent = 0;
    xpc_connection_t connection = xpc_connection_create_mach_service(
        "com.apple.bluetooth.BTPacketLogger", queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!connection) { fputs("Native capture service connection could not be created\n", stderr); return 2; }
    void (^metadata)(xpc_object_t) = ^(xpc_object_t message) {
        if (stopped) return;
        if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
            replies++;
            xpc_object_t auth = xpc_dictionary_get_value(message, "RequiresAuth");
            if (auth && xpc_get_type(auth) == XPC_TYPE_BOOL) {
                requires_auth = xpc_bool_get_value(auth);
                printf("RequiresAuth=%d\n", requires_auth);
                if (requires_auth && authorization && !authentication_sent) {
                    xpc_object_t authentication = xpc_dictionary_create(NULL, NULL, 0);
                    xpc_dictionary_set_data(authentication, "Authentication", &external, sizeof(external));
                    xpc_connection_send_message(connection, authentication);
                    xpc_release(authentication);
                    authentication_sent = 1;
                    puts("Native authorization submitted; awaiting packet data");
                }
            }
            xpc_object_t packet = xpc_dictionary_get_value(message, "packet");
            if (packet && xpc_get_type(packet) == XPC_TYPE_DATA) {
                packets++;
                if (packets == 1) printf("First native packet envelope received (%zu bytes); payload not printed\n",
                    xpc_data_get_length(packet));
                if (target) {
                    uint16_t old_handle = filter.handle, old_cid = filter.interrupt_cid;
                    if (iprc_native_filter_feed(&filter, xpc_data_get_bytes_ptr(packet),
                        xpc_data_get_length(packet))) {
                        target_voice_frames++;
                        if (target_voice_frames == 1) puts("First target F7 frame received; no audio stored");
                    }
                    if (filter.handle != old_handle || filter.interrupt_cid != old_cid)
                        printf("Target link: connected=%d interrupt_negotiated=%d\n",
                            filter.handle != UINT16_MAX, filter.interrupt_cid != 0);
                }
            }
        } else if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            errors++;
            const char *reason = xpc_dictionary_get_string(message, XPC_ERROR_KEY_DESCRIPTION);
            printf("Service error: %s\n", reason ? reason : "unknown");
        }
        fflush(stdout);
    };
    xpc_connection_set_event_handler(connection, metadata);
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_connection_send_message_with_reply(connection, request, queue, metadata);
    xpc_release(request);
    dispatch_source_t progress = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_t timeout = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timeout, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timeout, ^{
        stopped = 1;
        xpc_connection_set_event_handler(connection, ^(xpc_object_t unused) { (void)unused; });
        xpc_connection_cancel(connection);
        dispatch_source_cancel(progress);
        dispatch_source_cancel(timeout);
        printf("Native probe uid=%u dictionaries=%u packet_envelopes=%u errors=%u requires_auth=%d target_f7=%u; no payload stored\n",
            getuid(), replies, packets, errors, requires_auth, target_voice_frames);
        fflush(stdout);
        dispatch_semaphore_signal(finished);
    });
    dispatch_resume(timeout);
    dispatch_source_set_timer(progress, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(progress, ^{
        if (packets != last_packets) {
            printf("Native counts: envelopes=%u target_f7=%u\n", packets, target_voice_frames);
            fflush(stdout);
            last_packets = packets;
        }
    });
    dispatch_resume(progress);
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    dispatch_sync(queue, ^{});
    int result = errors ? 3 : (packets ? 0 : 4);
    dispatch_release(timeout);
    dispatch_release(progress);
    xpc_release(connection);
    dispatch_release(finished);
    dispatch_release(queue);
    if (!interactive) {
        if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDefaults);
        return result;
    }
    } while (interactive);
    if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDefaults);
    return 0;
}
