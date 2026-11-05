#include "NativePacketFilter.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static void w16(uint8_t *p, unsigned value) { p[0] = value; p[1] = value >> 8; }
static void w32(uint8_t *p, unsigned value, int little) {
    for (unsigned i = 0; i < 4; i++) p[i] = value >> (8 * (little ? i : 3 - i));
}
static size_t record(uint8_t *out, unsigned type, const uint8_t *body, size_t count, int little) {
    memset(out, 0, count + 13);w32(out, (unsigned)count + 9, little);out[12] = type;
    memcpy(out + 13, body, count);return count + 13;
}
static size_t signal_record(uint8_t *out, unsigned type, unsigned code, unsigned id, const uint8_t *body, size_t count) {
    uint8_t p[32] = {0};w16(p, 0x2021);w16(p + 2, count + 8);w16(p + 4, count + 4);w16(p + 6, 1);
    p[8] = code;p[9] = id;w16(p + 10, count);memcpy(p + 12, body, count);
    return record(out, type, p, count + 12, 1);
}
static const uint8_t *fragment(IPRCNativeFilter *f, unsigned type, unsigned handle,
                              unsigned boundary, const uint8_t *body, size_t count, int little) {
    uint8_t acl[662], r[675];assert(count<=sizeof(acl)-4);
    w16(acl,handle | (boundary<<12));w16(acl+2,(unsigned)count);memcpy(acl+4,body,count);
    return iprc_native_filter_feed(f,r,record(r,type,acl,count+4,little));
}
static void fragments(IPRCNativeFilter linked,const uint8_t *pdu) {
    for(unsigned boundary=0;boundary<=2;boundary+=2)for(int little=0;little<2;little++) {
        for(size_t split=4;split<657;split++) {
            IPRCNativeFilter f=linked;
            assert(!fragment(&f,3,0x21,boundary,pdu,split,little));
            assert(!fragment(&f,3,0x22,1,pdu+split,657-split,little));
            assert(!fragment(&f,2,0x21,1,pdu+split,657-split,little));
            const uint8_t *voice=fragment(&f,3,0x21,1,pdu+split,657-split,little);
            assert(voice && !memcmp(voice,pdu+5,652));
        }
    }
    IPRCNativeFilter f=linked;
    assert(!fragment(&f,3,0x21,2,pdu,4,1));
    for(size_t i=4;i<657;i++) {
        const uint8_t *voice=fragment(&f,3,0x21,1,pdu+i,1,1);
        assert((voice!=NULL)==(i==656));
    }
    f=linked;assert(!fragment(&f,3,0x21,2,pdu,100,1));
    assert(!fragment(&f,3,0x21,1,pdu,558,1) && f.voice_used==0); /* overflow */
    assert(!fragment(&f,3,0x21,1,pdu+100,557,1));
    f=linked;assert(!fragment(&f,3,0x21,2,pdu,100,1));
    const uint8_t keyboard[14]={10,0,0x41,0,0xa1,1};
    assert(!fragment(&f,3,0x21,2,keyboard,sizeof(keyboard),1));
    assert(!fragment(&f,3,0x21,1,pdu+100,557,1));
    f=linked;assert(!fragment(&f,3,0x21,2,pdu,100,1));
    uint8_t disconnect[6]={5,4,0,0x21,0,0x13},r[32];
    iprc_native_filter_feed(&f,r,record(r,1,disconnect,sizeof(disconnect),1));
    assert(f.voice_used==0 && f.voice_pdu[4]==0);
    assert(!fragment(&f,3,0x21,1,pdu+100,557,1));
}
int main(void) {
    uint8_t address[6] = {0xaa,0xbb,0xcc,0xdd,0xee,0xff};IPRCNativeFilter f;
    iprc_native_filter_init(&f, address);
    uint8_t connection[13] = {3,11,0,0x21,0,0xff,0xee,0xdd,0xcc,0xbb,0xaa,1,0};
    uint8_t r[700];size_t n = record(r,1,connection,sizeof(connection),1);
    assert(!iprc_native_filter_feed(&f,r,n) && f.handle == 0x21);
    uint8_t acl[661] = {0};w16(acl,0x2021);w16(acl+2,657);w16(acl+4,653);w16(acl+6,0x41);
    acl[8]=0xa1;acl[9]=0xf7;acl[10]=1;w16(acl+17,1);w16(acl+19,320);
    n=record(r,3,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));
    uint8_t request[4]={0x13,0,0x41,0};n=signal_record(r,2,2,7,request,4);iprc_native_filter_feed(&f,r,n);
    uint8_t response[8]={0x42,0,0x41,0,1,0,0,0};
    n=signal_record(r,3,3,7,response,8);iprc_native_filter_feed(&f,r,n);assert(f.interrupt_cid==0);
    response[4]=0;n=signal_record(r,3,3,6,response,8);iprc_native_filter_feed(&f,r,n);assert(f.interrupt_cid==0);
    n=signal_record(r,3,3,7,response,8);iprc_native_filter_feed(&f,r,n);
    assert(f.interrupt_cid==0x41);
    fragments(f,acl+4);
    for(int little=0;little<2;little++){
        n=record(r,3,acl,sizeof(acl),little);const uint8_t *voice=iprc_native_filter_feed(&f,r,n);
        assert(voice && voice[0]==0xf7 && voice[1]==1);
        for(size_t size=0;size<n;size++)assert(!iprc_native_filter_feed(&f,r,size));
    }
    n=record(r,2,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));
    acl[0]=0x22;n=record(r,3,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));acl[0]=0x21;
    acl[6]=0x43;n=record(r,3,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));acl[6]=0x41;
    acl[19]=0;n=record(r,3,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));acl[19]=0x40;
    acl[1]=0x10;n=record(r,3,acl,sizeof(acl),1);assert(!iprc_native_filter_feed(&f,r,n));acl[1]=0x20;
    n=record(r,3,acl,sizeof(acl),1);r[0]^=1;assert(!iprc_native_filter_feed(&f,r,n));
    uint8_t disconnect[6]={5,4,0,0x21,0,0x13};n=record(r,1,disconnect,6,1);iprc_native_filter_feed(&f,r,n);
    assert(f.handle==UINT16_MAX && f.interrupt_cid==0);
    /* Remote-initiated Interrupt: local response DCID is our incoming CID. */
    n=record(r,1,connection,13,1);iprc_native_filter_feed(&f,r,n);
    request[2]=0x55;n=signal_record(r,3,2,8,request,4);iprc_native_filter_feed(&f,r,n);
    response[0]=0x66;response[2]=0x55;n=signal_record(r,2,3,8,response,8);iprc_native_filter_feed(&f,r,n);
    assert(f.interrupt_cid==0x66);
    connection[5]=0;n=record(r,1,connection,13,1);iprc_native_filter_feed(&f,r,n);assert(f.handle==UINT16_MAX);
    puts("NATIVE FILTER SELF-TEST PASS: identity, negotiation, every ACL split, byte fragments, interleaved traffic, overflow and reconnect");
}
