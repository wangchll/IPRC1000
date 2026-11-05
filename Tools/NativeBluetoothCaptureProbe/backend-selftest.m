#import <Foundation/Foundation.h>
#import <Security/Authorization.h>
#import <xpc/xpc.h>
#include <assert.h>
static void (^handler)(xpc_object_t);
static dispatch_queue_t callbackQueue;
static unsigned sentAuth, freedAuth, canceled, terminalEvents;
static OSStatus fake_create(const AuthorizationRights *r, const AuthorizationEnvironment *e, AuthorizationFlags f, AuthorizationRef *out) {
    (void)r; (void)e; (void)f; *out = (AuthorizationRef)(uintptr_t)1; return 0;
}
static OSStatus fake_rights(AuthorizationRef a, const AuthorizationRights *r, const AuthorizationEnvironment *e, AuthorizationFlags f, AuthorizationRights **out) {
    (void)a; (void)e; (void)out;
    assert(r->count == 1 && !strcmp(r->items[0].name, "com.apple.PacketLogger.HCI"));
    assert(!(f & kAuthorizationFlagInteractionAllowed)); return 0;
}
static OSStatus fake_external(AuthorizationRef a, AuthorizationExternalForm *out) { (void)a; memset(out,0,sizeof(*out)); return 0; }
static OSStatus fake_free(AuthorizationRef a, AuthorizationFlags f) { (void)a; (void)f; freedAuth++; return 0; }
static xpc_connection_t fake_connection(const char *name, dispatch_queue_t q, uint64_t flags) {
    callbackQueue=q; assert(!strcmp(name,"com.apple.bluetooth.BTPacketLogger")); assert(flags==XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    return (xpc_connection_t)[NSObject new];
}
static void fake_handler(xpc_connection_t c, xpc_handler_t block) { (void)c; handler=[block copy]; }
static void fake_resume(xpc_connection_t c) { (void)c; }
static void fake_cancel(xpc_connection_t c) {
    (void)c; canceled++;
    xpc_handler_t terminal=[handler copy];
    dispatch_async(callbackQueue, ^{ terminalEvents++; terminal(XPC_ERROR_CONNECTION_INVALID); });
}
static void fake_send(xpc_connection_t c, xpc_object_t message) {
    (void)c; size_t size=0; assert(xpc_dictionary_get_data(message,"Authentication",&size) && size==sizeof(AuthorizationExternalForm)); sentAuth++;
}
static void fake_request(xpc_connection_t c, xpc_object_t request, dispatch_queue_t q, xpc_handler_t reply) {
    (void)c; (void)q; assert(xpc_dictionary_get_count(request)==0);
    xpc_object_t response=xpc_dictionary_create(NULL,NULL,0); xpc_dictionary_set_bool(response,"RequiresAuth",true); reply(response); reply(response);
}
#define AuthorizationCreate fake_create
#define AuthorizationCopyRights fake_rights
#define AuthorizationMakeExternalForm fake_external
#define AuthorizationFree fake_free
#define xpc_connection_create_mach_service fake_connection
#define xpc_connection_set_event_handler fake_handler
#define xpc_connection_resume fake_resume
#define xpc_connection_cancel fake_cancel
#define xpc_connection_send_message fake_send
#define xpc_connection_send_message_with_reply fake_request
#include "../../Sources/CRemoteSupport/NativeCapture.m"
static void w16(uint8_t *p,unsigned v){p[0]=v;p[1]=v>>8;}
static void inject(IPRCNativeSession *s,unsigned type,const uint8_t *body,size_t length){
    uint8_t data[700]={0};unsigned n=(unsigned)length+9;
    for(unsigned i=0;i<4;i++)data[i]=n>>(8*i);
    data[12]=type;memcpy(data+13,body,length);
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_data(message,"packet",data,length+13);
    dispatch_sync(s.queue,^{ handler(message); });
}
static void signal_packet(IPRCNativeSession *s,unsigned type,unsigned code,const uint8_t *body,size_t n){
    uint8_t packet[32]={0};w16(packet,0x2021);w16(packet+2,n+8);w16(packet+4,n+4);w16(packet+6,1);
    packet[8]=code;packet[9]=7;w16(packet+10,n);memcpy(packet+12,body,n);inject(s,type,packet,n+12);
}
int main(void){@autoreleasepool{
    const uint8_t profileMessage[]="Bluetooth Profile Required";
    assert(profileRequired(profileMessage,sizeof(profileMessage)));
    assert(profileRequired(profileMessage,sizeof(profileMessage)-1));
    assert(!profileRequired(profileMessage,sizeof(profileMessage)-2));
    assert(!profileRequired(NULL,0));
    uint8_t profileRecord[13+sizeof(profileMessage)]={0};
    profileRecord[3]=sizeof(profileRecord)-4;profileRecord[12]=0xfc;
    memcpy(profileRecord+13,profileMessage,sizeof(profileMessage));
    assert(profileRequired(profileRecord,sizeof(profileRecord)));
    profileRecord[12]=3;assert(!profileRequired(profileRecord,sizeof(profileRecord)));
    profileRecord[12]=0xfc;profileRecord[3]++;assert(!profileRequired(profileRecord,sizeof(profileRecord)));
    IPRCNativeCaptureRef ref=NULL;
    assert(iprc_native_capture_create("-0BBCCDDEEFF",&ref)==-2001 && !ref);
    assert(iprc_native_capture_create("AABBCCDDEEFF",&ref)==0 && ref && sentAuth==1);
    IPRCNativeSession *s=(__bridge IPRCNativeSession *)ref;
    uint8_t connection[13]={3,11,0,0x21,0,0xff,0xee,0xdd,0xcc,0xbb,0xaa,1,0};inject(s,1,connection,13);
    uint8_t request[4]={0x13,0,0x41,0};signal_packet(s,2,2,request,4);
    uint8_t response[8]={0x42,0,0x41,0,0,0,0,0};signal_packet(s,3,3,response,8);
    uint8_t acl[661]={0};w16(acl,0x2021);w16(acl+2,657);w16(acl+4,653);w16(acl+6,0x41);acl[8]=0xa1;acl[9]=0xf7;acl[10]=1;w16(acl+19,320);
    for(unsigned i=0;i<70;i++)inject(s,3,acl,sizeof(acl));
    IPRCNativeCaptureStats stats={0};iprc_native_capture_stats(ref,&stats);assert(stats.frames==70 && stats.dropped==6 && stats.interrupt_cid==0x41);
    uint8_t report[652];uint16_t handle=0;
    for(unsigned i=0;i<64;i++)assert(iprc_native_capture_read(ref,report,&handle)==1 && report[0]==0xf7 && handle==0x21);
    assert(!iprc_native_capture_read(ref,report,&handle));
    inject(s,3,acl,sizeof(acl));uint8_t disconnect[6]={5,4,0,0x21,0,0x13};inject(s,1,disconnect,6);
    assert(!iprc_native_capture_read(ref,report,&handle));
    inject(s,1,connection,13);signal_packet(s,2,2,request,4);signal_packet(s,3,3,response,8);
    inject(s,3,acl,sizeof(acl));
    inject(s,0xfc,profileMessage,sizeof(profileMessage)-1);
    iprc_native_capture_stats(ref,&stats);assert(stats.error==IPRCNativeCaptureProfileRequired);
    assert(!iprc_native_capture_read(ref,report,&handle));
    inject(s,3,acl,sizeof(acl));
    assert(!iprc_native_capture_read(ref,report,&handle));
    void (^late)(xpc_object_t)=[handler copy];
    __weak IPRCNativeSession *weak=s;s=nil;iprc_native_capture_destroy(ref);
    assert(canceled==1 && terminalEvents==1 && freedAuth==1 && !weak);
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);late(message);
    puts("NATIVE BACKEND SELF-TEST PASS: authorization, handshake, routing, queue, disconnect, profile denial clears audio and late callback");
    return 0;
}}
