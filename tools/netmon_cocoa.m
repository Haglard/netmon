// =============================================
// File: tools/netmon_cocoa.m
// Project: netmon — Vibe NetMon, macOS network monitor
// Equivalent to internet_monitor.py (Python reference)
// License: MIT (c) 2025
// =============================================
#import <Cocoa/Cocoa.h>
#include <sys/socket.h>
#include <netdb.h>
#include <sys/time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>

// ===================== Globals (set in main) =====================
static NSString *kOutputDir;
static NSArray  *kICMPTargets;
static NSString *kDNSTestHost;
static NSArray  *kHTTPTestURLs;

#define DFLT_GATEWAY      @"192.168.1.1"
#define DFLT_INTERVAL_SEC  10
#define PING_TIMEOUT_MS    1000
#define LOG_FONT_SZ        11.0
#define WIN_W              1150.0
#define WIN_H               720.0
#define HEADER_H             52.0

// ===================== Data Structures =====================
typedef struct {
    double ts_unix;
    BOOL   gateway_ok;
    double gateway_rtt;   // ms; -1 = N/A
    int    icmp_ok, icmp_total;
    double icmp_median;   // ms; -1 = N/A
    BOOL   dns_ok;
    double dns_ms;        // -1 = N/A
    int    http_ok, http_total;
    double http_median;   // ms; -1 = N/A
    BOOL   internet_up;
    char   notes[512];
    double rx_bps;        // byte/s ricevuti nell'intervallo; -1 = N/A
    double tx_bps;        // byte/s trasmessi nell'intervallo; -1 = N/A
} NMSample;

// ===================== Traffic helpers =====================
// Somma ibytes/obytes di tutte le interfacce fisiche non-loopback.
// Restituisce NO se getifaddrs fallisce.
static BOOL nm_iface_bytes(uint64_t *rx, uint64_t *tx) {
    *rx = 0; *tx = 0;
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return NO;
    for (struct ifaddrs *ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr) continue;
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        // Escludi loopback e interfacce virtuali comuni
        const char *n = ifa->ifa_name;
        if (strncmp(n, "lo",    2) == 0) continue;
        if (strncmp(n, "utun",  4) == 0) continue;
        if (strncmp(n, "awdl",  4) == 0) continue;
        if (strncmp(n, "llw",   3) == 0) continue;
        if (strncmp(n, "bridge",6) == 0) continue;
        if (!(ifa->ifa_flags & IFF_UP))  continue;
        struct if_data *ifd = (struct if_data *)ifa->ifa_data;
        if (!ifd) continue;
        *rx += ifd->ifi_ibytes;
        *tx += ifd->ifi_obytes;
    }
    freeifaddrs(ifap);
    return YES;
}

// Thread-safe snapshot of hourly stats (computed on BG thread, passed to main thread)
typedef struct {
    double availability;   // 0..100
    double downtimeSec;
    int    samples;
    int    disconnectEvents;
    int    reconnectEvents;
    int    gatewayFail;
    double gwMedian;
    double icmpMedian, icmpP95;
    double dnsMedian;
    double httpMedian, httpP95;
} NMStatsSnap;

// ===================== Array stats helpers =====================
static double nm_median(NSArray *sorted) {
    if (!sorted.count) return -1;
    NSInteger n = sorted.count;
    if (n % 2 == 1) return [sorted[n/2] doubleValue];
    return ([sorted[n/2-1] doubleValue] + [sorted[n/2] doubleValue]) / 2.0;
}
static double nm_percentile(NSArray *sorted, double p) {
    if (!sorted.count) return -1;
    NSInteger n = sorted.count;
    double k = (n - 1) * p;
    NSInteger f = (NSInteger)k;
    NSInteger c = MIN(f + 1, n - 1);
    if (f == c) return [sorted[f] doubleValue];
    return [sorted[f] doubleValue] * (c - k) + [sorted[c] doubleValue] * (k - f);
}
static NSArray *nm_sort(NSMutableArray *arr) {
    return [arr sortedArrayUsingSelector:@selector(compare:)];
}

// ===================== NMHourStats =====================
@interface NMHourStats : NSObject
@property NSDate          *hourStart;
@property (atomic) int     samples;
@property (atomic) int     gatewayFail;
@property (atomic) int     internetDown;
@property (atomic) int     disconnectEvents;
@property (atomic) int     reconnectEvents;
@property (atomic) double  downtimeSec;
@property NSMutableArray  *gwRTTs, *icmpRTTs, *dnsTimes, *httpTimes;
- (instancetype)initWithDate:(NSDate *)d;
- (void)addSample:(NMSample *)s intervalSec:(int)iv;
- (NMStatsSnap)snapshot;
- (NSString *)formatReport;
@end

@implementation NMHourStats
- (instancetype)initWithDate:(NSDate *)d {
    self = [super init];
    _hourStart = d;
    _gwRTTs   = [NSMutableArray array];
    _icmpRTTs = [NSMutableArray array];
    _dnsTimes = [NSMutableArray array];
    _httpTimes= [NSMutableArray array];
    return self;
}
- (void)addSample:(NMSample *)s intervalSec:(int)iv {
    self.samples++;
    if (!s->gateway_ok) self.gatewayFail++;
    else if (s->gateway_rtt >= 0) [self.gwRTTs  addObject:@(s->gateway_rtt)];
    if (!s->internet_up) { self.internetDown++; self.downtimeSec += iv; }
    if (s->icmp_median >= 0) [self.icmpRTTs addObject:@(s->icmp_median)];
    if (s->dns_ok && s->dns_ms >= 0) [self.dnsTimes addObject:@(s->dns_ms)];
    if (s->http_median >= 0) [self.httpTimes addObject:@(s->http_median)];
}
- (NMStatsSnap)snapshot {
    NSArray *gw  = nm_sort(self.gwRTTs);
    NSArray *ic  = nm_sort(self.icmpRTTs);
    NSArray *dn  = nm_sort(self.dnsTimes);
    NSArray *ht  = nm_sort(self.httpTimes);
    double avail = self.samples > 0
        ? 100.0 * (self.samples - self.internetDown) / self.samples : 100.0;
    NMStatsSnap s = {
        avail, self.downtimeSec,
        self.samples, self.disconnectEvents, self.reconnectEvents, self.gatewayFail,
        nm_median(gw), nm_median(ic), nm_percentile(ic, 0.95),
        nm_median(dn), nm_median(ht), nm_percentile(ht, 0.95)
    };
    return s;
}
- (NSString *)formatReport {
    NMStatsSnap s = [self snapshot];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:00";
    NSString *(^ms)(double) = ^(double v) {
        return v < 0 ? @"-" : [NSString stringWithFormat:@"%.1f", v];
    };
    return [NSString stringWithFormat:
        @"======================================================================\n"
        @"REPORT ORARIO %@\n"
        @"----------------------------------------------------------------------\n"
        @"Campioni              : %d\n"
        @"Disponibilità         : %.2f%%\n"
        @"Downtime stimato      : %.1fs\n"
        @"Disconnessioni        : %d  Riconnessioni: %d\n"
        @"Gateway KO            : %d\n\n"
        @"Latenza GW mediana    : %@ ms\n"
        @"Latenza ICMP mediana  : %@ ms\n"
        @"Latenza ICMP p95      : %@ ms\n"
        @"Tempo DNS mediano     : %@ ms\n"
        @"Tempo HTTP mediano    : %@ ms\n"
        @"Tempo HTTP p95        : %@ ms\n"
        @"======================================================================\n\n",
        [df stringFromDate:self.hourStart],
        s.samples, s.availability, s.downtimeSec,
        s.disconnectEvents, s.reconnectEvents, s.gatewayFail,
        ms(s.gwMedian), ms(s.icmpMedian), ms(s.icmpP95),
        ms(s.dnsMedian), ms(s.httpMedian), ms(s.httpP95)];
}
@end

// ===================== NMProbe =====================
@interface NMProbe : NSObject
+ (BOOL)pingHost:(NSString *)host tms:(int)tms rtt:(double *)rtt;
+ (BOOL)dnsLookup:(NSString *)host ms:(double *)ms;
+ (BOOL)httpCheck:(NSString *)url ms:(double *)ms;
+ (NSString *)runDiag:(NSArray *)cmd timeout:(int)sec;
@end

@implementation NMProbe

+ (BOOL)pingHost:(NSString *)host tms:(int)tms rtt:(double *)rtt {
    if (rtt) *rtt = -1;
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/ping";
    task.arguments  = @[@"-c", @"1", @"-W", [NSString stringWithFormat:@"%d", tms], host];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = pipe;
    @try { [task launch]; }
    @catch (...) { return NO; }
    NSTask * __weak wt = task;
    double dl = tms / 1000.0 + 3.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dl * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0),
                   ^{ if (wt.isRunning) [wt terminate]; });
    [task waitUntilExit];
    NSData   *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *out  = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    BOOL ok = (task.terminationStatus == 0);
    if (rtt) {
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"time[=<]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*ms"
            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:out options:0
                                                   range:NSMakeRange(0, out.length)];
        if (m && [m rangeAtIndex:1].location != NSNotFound)
            *rtt = [[out substringWithRange:[m rangeAtIndex:1]] doubleValue];
    }
    return ok;
}

+ (BOOL)dnsLookup:(NSString *)host ms:(double *)ms {
    if (ms) *ms = -1;
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    int rc = getaddrinfo(host.UTF8String, "443", &hints, &res);
    gettimeofday(&t1, NULL);
    if (res) freeaddrinfo(res);
    if (ms) *ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_usec - t0.tv_usec) / 1000.0;
    return rc == 0;
}

+ (BOOL)httpCheck:(NSString *)url ms:(double *)ms {
    if (ms) *ms = -1;
    __block BOOL ok = NO;
    __block double elapsed = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:url]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:5.0];
    [req setValue:@"netmon/1.0" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e) { ok = YES; elapsed = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0; }
        dispatch_semaphore_signal(sem);
    }] resume];
    [sess finishTasksAndInvalidate];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC));
    if (ms) *ms = elapsed;
    return ok;
}

+ (NSString *)runDiag:(NSArray *)cmd timeout:(int)sec {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = cmd[0];
    task.arguments  = [cmd subarrayWithRange:NSMakeRange(1, cmd.count - 1)];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = pipe;
    @try { [task launch]; }
    @catch (...) { return @"(failed to launch)"; }
    NSTask * __weak wt = task;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sec + 1) * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0),
                   ^{ if (wt.isRunning) [wt terminate]; });
    [task waitUntilExit];
    NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}
@end

// ===================== NMLogger =====================
@interface NMLogger : NSObject {
    FILE *_csvF, *_evF, *_repF;
}
- (instancetype)initWithDir:(NSString *)dir tag:(NSString *)tag;
- (void)writeCSV:(NMSample *)s;
- (void)writeEvent:(NSString *)txt;
- (void)writeReport:(NSString *)txt;
- (void)close;
@end

@implementation NMLogger
- (instancetype)initWithDir:(NSString *)dir tag:(NSString *)tag {
    self = [super init];
    NSString *exp = [dir stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:exp
                                withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *(^path)(NSString *, NSString *) = ^(NSString *pfx, NSString *ext) {
        return [exp stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@_%@.%@", pfx, tag, ext]];
    };
    _csvF = fopen(path(@"samples", @"csv").UTF8String, "a");
    _evF  = fopen(path(@"events",  @"log").UTF8String, "a");
    _repF = fopen(path(@"hourly",  @"log").UTF8String, "a");
    if (_csvF && ftell(_csvF) == 0)
        fprintf(_csvF,
            "timestamp,gateway_ok,gateway_rtt_ms,icmp_ok,icmp_total,icmp_median_ms,"
            "dns_ok,dns_ms,http_ok,http_total,http_median_ms,internet_up,notes\n");
    return self;
}
- (void)writeCSV:(NMSample *)s {
    if (!_csvF) return;
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:s->ts_unix];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    fprintf(_csvF, "%s,%d,%.1f,%d,%d,%.1f,%d,%.1f,%d,%d,%.1f,%d,\"%s\"\n",
        [df stringFromDate:d].UTF8String,
        s->gateway_ok, s->gateway_rtt,
        s->icmp_ok, s->icmp_total, s->icmp_median,
        s->dns_ok, s->dns_ms,
        s->http_ok, s->http_total, s->http_median,
        s->internet_up, s->notes);
    fflush(_csvF);
}
- (void)writeEvent:(NSString *)txt {
    if (!_evF) return;
    fprintf(_evF, "%s\n", txt.UTF8String); fflush(_evF);
}
- (void)writeReport:(NSString *)txt {
    if (!_repF) return;
    fprintf(_repF, "%s", txt.UTF8String); fflush(_repF);
}
- (void)close {
    if (_csvF) { fclose(_csvF); _csvF = NULL; }
    if (_evF)  { fclose(_evF);  _evF  = NULL; }
    if (_repF) { fclose(_repF); _repF = NULL; }
}
- (void)dealloc { [self close]; }
@end

// ===================== NMMonitor =====================
@interface NMMonitor : NSObject {
    NSThread     *_thread;
    volatile BOOL _running;
    volatile int  _intervalSec;
    NSString     *_gateway;
}
@property (copy) void(^onSample)(NMSample s, NMStatsSnap snap);
@property (copy) void(^onEvent)(NSString *text, BOOL isDown);
@property (copy) void(^onHourlyReport)(NMHourStats *stats);
- (void)startWithGateway:(NSString *)gw;
- (void)stop;
- (void)setIntervalSec:(int)iv;
@end

@implementation NMMonitor
- (instancetype)init {
    self = [super init];
    _intervalSec = DFLT_INTERVAL_SEC;
    _gateway = DFLT_GATEWAY;
    return self;
}
- (void)startWithGateway:(NSString *)gw {
    _gateway = gw.length ? gw : DFLT_GATEWAY;
    _running = YES;
    _thread  = [[NSThread alloc] initWithTarget:self selector:@selector(_loop) object:nil];
    _thread.name = @"netmon";
    [_thread start];
}
- (void)stop  { _running = NO; }
- (void)setIntervalSec:(int)iv { _intervalSec = MAX(1, iv); }

- (void)_loop {
    @autoreleasepool {
        NSDateFormatter *tagFmt = [[NSDateFormatter alloc] init];
        tagFmt.dateFormat = @"yyyyMMdd";
        NSCalendar *cal = [NSCalendar currentCalendar];

        NSDate *now  = [NSDate date];
        NSString *tag = [tagFmt stringFromDate:now];
        NMLogger *logger = [[NMLogger alloc] initWithDir:kOutputDir tag:tag];

        NSDate *hourStart = [cal dateBySettingHour:[cal component:NSCalendarUnitHour fromDate:now]
                                            minute:0 second:0 ofDate:now options:0];
        NMHourStats *stats = [[NMHourStats alloc] initWithDate:hourStart];

        BOOL prevUp = YES, firstSample = YES, downActive = NO;
        NSDate *downStart = nil;

        // Baseline traffico (contatori cumulativi al primo tick)
        uint64_t prevRxBytes = 0, prevTxBytes = 0;
        NSTimeInterval prevTrafficTime = 0;
        BOOL hasTrafficBaseline = nm_iface_bytes(&prevRxBytes, &prevTxBytes);
        if (hasTrafficBaseline) prevTrafficTime = [NSDate timeIntervalSinceReferenceDate];

        while (_running) {
            @autoreleasepool {
                NSDate *tick = [NSDate date];

                // Day rotation
                NSString *newTag = [tagFmt stringFromDate:tick];
                if (![newTag isEqualToString:tag]) {
                    [logger close];
                    tag = newTag;
                    logger = [[NMLogger alloc] initWithDir:kOutputDir tag:tag];
                }
                // Hour rotation
                NSDate *newHour = [cal dateBySettingHour:[cal component:NSCalendarUnitHour fromDate:tick]
                                                  minute:0 second:0 ofDate:tick options:0];
                if ([newHour timeIntervalSinceDate:hourStart] > 1) {
                    NSString *rep = [stats formatReport];
                    [logger writeReport:rep];
                    NMHourStats *done = stats;
                    if (self.onHourlyReport) dispatch_async(dispatch_get_main_queue(), ^{
                        self.onHourlyReport(done);
                    });
                    hourStart = newHour;
                    stats = [[NMHourStats alloc] initWithDate:newHour];
                }

                // ---- Probes ----
                NMSample s; memset(&s, 0, sizeof(s));
                s.ts_unix    = tick.timeIntervalSince1970;
                s.icmp_total = (int)kICMPTargets.count;
                s.http_total = (int)kHTTPTestURLs.count;
                s.gateway_rtt = s.icmp_median = s.dns_ms = s.http_median = -1;

                // Gateway
                double gwRtt;
                s.gateway_ok  = [NMProbe pingHost:_gateway tms:PING_TIMEOUT_MS rtt:&gwRtt];
                s.gateway_rtt = gwRtt;

                // ICMP
                NSMutableArray *icRTTs = [NSMutableArray array];
                for (NSString *t in kICMPTargets) {
                    double rtt;
                    if ([NMProbe pingHost:t tms:PING_TIMEOUT_MS rtt:&rtt]) {
                        s.icmp_ok++;
                        if (rtt >= 0) [icRTTs addObject:@(rtt)];
                    }
                }
                s.icmp_median = nm_median(nm_sort(icRTTs));

                // DNS
                double dms;
                s.dns_ok = [NMProbe dnsLookup:kDNSTestHost ms:&dms];
                s.dns_ms = s.dns_ok ? dms : -1;

                // HTTP
                NSMutableArray *htMs = [NSMutableArray array];
                for (NSString *url in kHTTPTestURLs) {
                    double hms;
                    if ([NMProbe httpCheck:url ms:&hms]) {
                        s.http_ok++;
                        if (hms >= 0) [htMs addObject:@(hms)];
                    }
                }
                s.http_median = nm_median(nm_sort(htMs));

                s.internet_up = s.gateway_ok && (s.icmp_ok > 0 || s.http_ok > 0);

                // ---- Traffico interfacce ----
                s.rx_bps = s.tx_bps = -1;
                uint64_t curRx = 0, curTx = 0;
                NSTimeInterval curTime = [NSDate timeIntervalSinceReferenceDate];
                if (nm_iface_bytes(&curRx, &curTx) && hasTrafficBaseline && prevTrafficTime > 0) {
                    double dt = curTime - prevTrafficTime;
                    if (dt > 0.1) {
                        // Gestione rollover (contatori uint64: estremamente improbabile,
                        // ma gestiamo il caso in cui la baseline sia stata resettata)
                        int64_t dRx = (int64_t)(curRx - prevRxBytes);
                        int64_t dTx = (int64_t)(curTx - prevTxBytes);
                        if (dRx >= 0) s.rx_bps = (double)dRx / dt;
                        if (dTx >= 0) s.tx_bps = (double)dTx / dt;
                    }
                }
                prevRxBytes = curRx; prevTxBytes = curTx;
                prevTrafficTime = curTime;
                hasTrafficBaseline = YES;

                // Notes
                NSMutableArray *notes = [NSMutableArray array];
                if (!s.gateway_ok) [notes addObject:@"GW_FAIL"];
                if (!s.dns_ok)     [notes addObject:@"DNS_FAIL"];
                if (s.icmp_ok < s.icmp_total)
                    [notes addObject:[NSString stringWithFormat:@"ICMP_%d/%d", s.icmp_ok, s.icmp_total]];
                if (s.http_ok < s.http_total)
                    [notes addObject:[NSString stringWithFormat:@"HTTP_%d/%d", s.http_ok, s.http_total]];
                strncpy(s.notes, [[notes componentsJoinedByString:@" | "] UTF8String], 511);

                [logger writeCSV:&s];

                // ---- Event detection ----
                NSDateFormatter *tf = [[NSDateFormatter alloc] init];
                tf.dateFormat = @"yyyy-MM-dd HH:mm:ss";

                if (!firstSample) {
                    if (prevUp && !s.internet_up && !downActive) {
                        stats.disconnectEvents++;
                        downActive = YES; downStart = tick;
                        NSString *ev = [NSString stringWithFormat:@"[%@] *** DOWN rilevato ***",
                                        [tf stringFromDate:tick]];
                        [logger writeEvent:ev];
                        // Append diagnostics
                        dispatch_async(dispatch_get_global_queue(0, 0), ^{
                            NSMutableString *diag = [NSMutableString string];
                            [diag appendFormat:@"\n--- Ping GW %@ ---\n", _gateway];
                            [diag appendString:[NMProbe runDiag:@[@"/sbin/ping",@"-c",@"3",_gateway] timeout:12]];
                            for (NSString *t in kICMPTargets) {
                                [diag appendFormat:@"\n--- Ping %@ ---\n", t];
                                [diag appendString:[NMProbe runDiag:@[@"/sbin/ping",@"-c",@"3",t] timeout:12]];
                            }
                            [diag appendString:@"\n--- Traceroute ---\n"];
                            [diag appendString:[NMProbe runDiag:@[@"/usr/sbin/traceroute",@"-m",@"8",@"1.1.1.1"] timeout:20]];
                            NSString *evFull = [ev stringByAppendingFormat:@"\n%@", diag];
                            [logger writeEvent:evFull];
                        });
                        if (self.onEvent) dispatch_async(dispatch_get_main_queue(), ^{
                            self.onEvent(ev, YES);
                        });

                    } else if (!prevUp && s.internet_up && downActive) {
                        stats.reconnectEvents++;
                        downActive = NO;
                        double durSec = downStart ? [tick timeIntervalSinceDate:downStart] : 0;
                        NSString *ev = [NSString stringWithFormat:
                            @"[%@] *** RIPRISTINATA (durata: %.0fs) ***", [tf stringFromDate:tick], durSec];
                        [logger writeEvent:ev];
                        downStart = nil;
                        if (self.onEvent) dispatch_async(dispatch_get_main_queue(), ^{
                            self.onEvent(ev, NO);
                        });
                    }
                }
                firstSample = NO;
                prevUp = s.internet_up;

                [stats addSample:&s intervalSec:_intervalSec];
                NMStatsSnap snap = [stats snapshot];
                NMSample scopy = s;
                if (self.onSample) dispatch_async(dispatch_get_main_queue(), ^{
                    self.onSample(scopy, snap);
                });

                // Sleep in small chunks so we can react to interval changes
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:tick];
                NSDate *wake = [NSDate dateWithTimeIntervalSinceNow:MAX(0, _intervalSec - elapsed)];
                while (_running && [[NSDate date] compare:wake] == NSOrderedAscending)
                    [NSThread sleepForTimeInterval:0.25];
            }
        }
        [logger close];
    }
}
@end

// ===================== NMStatsView =====================
#define NM_TRAFFIC_HIST 60   // campioni di storia traffico

@interface NMStatsView : NSView {
    NMStatsSnap _snap;
    NMSample    _sample;
    BOOL        _hasSample;
    BOOL        _isUp;
    // Ring buffer traffico
    double _rxHist[NM_TRAFFIC_HIST];
    double _txHist[NM_TRAFFIC_HIST];
    int    _histHead;    // indice prossima scrittura (circolare)
    int    _histCount;   // quanti campioni validi (0..NM_TRAFFIC_HIST)
}
- (void)updateSnap:(NMStatsSnap)snap sample:(NMSample)s isUp:(BOOL)up;
@end

@implementation NMStatsView
- (instancetype)initWithFrame:(NSRect)fr {
    self = [super initWithFrame:fr];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor colorWithRed:0.07 green:0.09 blue:0.15 alpha:1] CGColor];
    }
    return self;
}
- (void)updateSnap:(NMStatsSnap)snap sample:(NMSample)s isUp:(BOOL)up {
    _snap = snap; _sample = s; _hasSample = YES; _isUp = up;
    // Aggiorna ring buffer traffico (valori negativi = N/A → 0 nel grafico)
    _rxHist[_histHead] = s.rx_bps >= 0 ? s.rx_bps : 0;
    _txHist[_histHead] = s.tx_bps >= 0 ? s.tx_bps : 0;
    _histHead = (_histHead + 1) % NM_TRAFFIC_HIST;
    if (_histCount < NM_TRAFFIC_HIST) _histCount++;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)__unused dirty {
    float W = self.bounds.size.width;
    float x = 16, pw = W - 32;
    __block float y = self.bounds.size.height - 20;

    // Sfondo
    [[NSColor colorWithRed:0.07 green:0.09 blue:0.15 alpha:1] setFill];
    NSRectFill(self.bounds);

    // Palette colori
    NSColor *colBright = [NSColor colorWithWhite:0.92 alpha:1];
    NSColor *colMid    = [NSColor colorWithWhite:0.60 alpha:1];
    NSColor *colDim    = [NSColor colorWithWhite:0.33 alpha:1];
    NSColor *colGreen  = [NSColor colorWithRed:0.28 green:0.88 blue:0.44 alpha:1];
    NSColor *colRed    = [NSColor colorWithRed:1.00 green:0.30 blue:0.30 alpha:1];
    NSColor *colOrange = [NSColor colorWithRed:1.00 green:0.62 blue:0.10 alpha:1];
    NSColor *colSep    = [NSColor colorWithWhite:0.18 alpha:1];
    NSColor *colAccent = [NSColor colorWithRed:0.32 green:0.62 blue:1.00 alpha:1];

    // Attributi testo
    NSDictionary *titleA = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: colAccent };
    NSDictionary *sectionA = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:8],
        NSForegroundColorAttributeName: colDim,
        NSKernAttributeName: @(2.2) };
    NSDictionary *labelA = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: colMid };

    // Helper: riga label sx / valore dx colorato
    void (^row)(NSString *, NSString *, NSColor *) = ^(NSString *lbl, NSString *val, NSColor *vc) {
        [lbl drawAtPoint:NSMakePoint(x, y) withAttributes:labelA];
        if (val) {
            NSDictionary *va = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: vc ?: colBright };
            NSSize vs = [val sizeWithAttributes:va];
            [val drawAtPoint:NSMakePoint(x + pw - vs.width, y) withAttributes:va];
        }
        y -= 18;
    };

    // Helper: separatore + intestazione sezione
    void (^section)(NSString *) = ^(NSString *title) {
        y -= 5;
        [colSep setFill]; NSRectFill(NSMakeRect(x, y + 7, pw, 1));
        y -= 15;
        [title drawAtPoint:NSMakePoint(x, y) withAttributes:sectionA];
        y -= 14;
    };

    // Formattatore ms
    NSString *(^ms)(double) = ^(double v) {
        return v < 0 ? @"—" : [NSString stringWithFormat:@"%.0f ms", v];
    };

    // ---- Titolo ----
    [@"VIBE NETMON" drawAtPoint:NSMakePoint(x, y) withAttributes:titleA];
    y -= 22;

    // ---- Dot stato ----
    NSColor *dotCol = _isUp ? colGreen : colRed;
    NSDictionary *dotA = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: dotCol };
    [(_isUp ? @"● UP" : @"● DOWN") drawAtPoint:NSMakePoint(x, y) withAttributes:dotA];
    y -= 24;

    if (!_hasSample) {
        NSDictionary *wa = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: colDim };
        [@"In attesa del primo campione…" drawAtPoint:NSMakePoint(x, y) withAttributes:wa];
        return;
    }

    // ---- Barra disponibilità ----
    float barH = 18, barW = pw;
    double avFrac = _snap.availability / 100.0;
    [[NSColor colorWithRed:0.42 green:0.07 blue:0.07 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barW, barH) xRadius:5 yRadius:5] fill];
    if (avFrac > 0.001) {
        NSColor *bc = avFrac >= 0.999 ? [NSColor colorWithRed:0.10 green:0.55 blue:0.22 alpha:1]
                    : avFrac >= 0.990 ? [NSColor colorWithRed:0.60 green:0.55 blue:0.05 alpha:1]
                    :                   [NSColor colorWithRed:0.65 green:0.20 blue:0.05 alpha:1];
        [bc setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, barW * avFrac, barH)
                                         xRadius:5 yRadius:5] fill];
    }
    NSString *avS = [NSString stringWithFormat:@"%.2f%%", _snap.availability];
    NSDictionary *blA = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.95 alpha:1] };
    NSSize bls = [avS sizeWithAttributes:blA];
    [avS drawAtPoint:NSMakePoint(x + barW/2 - bls.width/2, y + (barH - bls.height)/2 + 1)
      withAttributes:blA];
    y -= (barH + 12);

    // ---- CONNESSIONE ----
    section(@"CONNESSIONE");
    NSColor *avC = _snap.availability >= 99.9 ? colGreen
                 : _snap.availability >= 99.0 ? colOrange : colRed;
    row(@"Disponibilità",
        [NSString stringWithFormat:@"%.2f%%", _snap.availability], avC);
    row(@"Downtime",
        _snap.downtimeSec <= 0 ? @"—" : [NSString stringWithFormat:@"%.0f s", _snap.downtimeSec],
        _snap.downtimeSec > 0 ? colOrange : colMid);
    row(@"Campioni",   [NSString stringWithFormat:@"%d", _snap.samples], nil);
    row(@"Disc/Riconn",
        [NSString stringWithFormat:@"%d / %d", _snap.disconnectEvents, _snap.reconnectEvents],
        _snap.disconnectEvents > 0 ? colOrange : colMid);

    // ---- LATENZE ----
    section(@"LATENZE");
    NSColor *(^latCol)(double) = ^(double v) {
        return (v < 0 || v < 50) ? colGreen : (v < 150) ? colOrange : colRed;
    };
    row(@"GW mediana",   ms(_snap.gwMedian),   latCol(_snap.gwMedian));
    row(@"ICMP mediana", ms(_snap.icmpMedian), latCol(_snap.icmpMedian));
    row(@"ICMP p95",     ms(_snap.icmpP95),    latCol(_snap.icmpP95));
    row(@"DNS mediano",  ms(_snap.dnsMedian),  latCol(_snap.dnsMedian));
    row(@"HTTP mediano", ms(_snap.httpMedian), latCol(_snap.httpMedian));
    row(@"HTTP p95",     ms(_snap.httpP95),    latCol(_snap.httpP95));

    // ---- ULTIMO CAMPIONE ----
    section(@"ULTIMO CAMPIONE");
    NSColor *(^okC)(BOOL) = ^(BOOL ok) { return ok ? colGreen : colRed; };
    row(@"Gateway",
        [NSString stringWithFormat:@"%@  %@",
         _sample.gateway_ok ? @"OK" : @"KO", ms(_sample.gateway_rtt)],
        okC(_sample.gateway_ok));
    row(@"ICMP",
        [NSString stringWithFormat:@"%d/%d  %@",
         _sample.icmp_ok, _sample.icmp_total, ms(_sample.icmp_median)],
        _sample.icmp_ok == _sample.icmp_total ? colGreen : colOrange);
    row(@"DNS",
        [NSString stringWithFormat:@"%@  %@",
         _sample.dns_ok ? @"OK" : @"KO", ms(_sample.dns_ms)],
        okC(_sample.dns_ok));
    row(@"HTTP",
        [NSString stringWithFormat:@"%d/%d  %@",
         _sample.http_ok, _sample.http_total, ms(_sample.http_median)],
        _sample.http_ok == _sample.http_total ? colGreen : colOrange);

    // ---- TRAFFICO ----
    if (_histCount > 0) {

    section(@"TRAFFICO");

    // Formattatore throughput leggibile
    NSString *(^fmtBps)(double) = ^(double bps) {
        if (bps < 0)          return @"—";
        if (bps < 1024)       return [NSString stringWithFormat:@"%.0f B/s",     bps];
        if (bps < 1024*1024)  return [NSString stringWithFormat:@"%.1f KB/s",    bps / 1024.0];
        return                       [NSString stringWithFormat:@"%.2f MB/s",    bps / (1024.0*1024.0)];
    };

    {
        // Contatori RX / TX ultimi valori
        int lastIdx = (_histHead - 1 + NM_TRAFFIC_HIST) % NM_TRAFFIC_HIST;
        double lastRx = _rxHist[lastIdx];
        double lastTx = _txHist[lastIdx];

        NSDictionary *rxA = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithRed:0.30 green:0.78 blue:1.00 alpha:1] };
        NSDictionary *txA = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithRed:1.00 green:0.65 blue:0.15 alpha:1] };
        NSDictionary *iconA = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: colMid };

        NSString *rxS  = fmtBps(lastRx);
        NSString *txS  = fmtBps(lastTx);
        NSSize   rxSz  = [rxS sizeWithAttributes:rxA];
        NSSize   txSz  = [txS sizeWithAttributes:txA];

        float half = pw / 2.0f;
        [@"↓ RX" drawAtPoint:NSMakePoint(x,            y) withAttributes:iconA];
        [rxS     drawAtPoint:NSMakePoint(x + half - rxSz.width - 4, y) withAttributes:rxA];
        [@"↑ TX" drawAtPoint:NSMakePoint(x + half + 4, y) withAttributes:iconA];
        [txS     drawAtPoint:NSMakePoint(x + pw - txSz.width, y) withAttributes:txA];
        y -= 20;

        // ---- Grafico ----
        float graphH = MAX(60.0f, MIN(y - 14.0f, 100.0f));  // altezza adattiva
        float graphY = y - graphH;
        float graphW = pw;

        // Sfondo grafico
        [[NSColor colorWithRed:0.04 green:0.06 blue:0.10 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, graphY, graphW, graphH)
                                         xRadius:4 yRadius:4] fill];

        // Griglia orizzontale (3 linee)
        [[NSColor colorWithWhite:0.14 alpha:1] setStroke];
        for (int gi = 1; gi <= 3; gi++) {
            float gy = graphY + graphH * gi / 4.0f;
            NSBezierPath *gl = [NSBezierPath bezierPath];
            [gl moveToPoint:NSMakePoint(x + 2, gy)];
            [gl lineToPoint:NSMakePoint(x + graphW - 2, gy)];
            gl.lineWidth = 0.5;
            [gl stroke];
        }

        if (_histCount >= 2) {
            // Scala Y: massimo tra RX e TX nella storia
            double ymax = 1024.0;  // minimo 1 KB/s per evitare divisione per zero
            int start = (_histHead - _histCount + NM_TRAFFIC_HIST) % NM_TRAFFIC_HIST;
            for (int i = 0; i < _histCount; i++) {
                int idx = (start + i) % NM_TRAFFIC_HIST;
                if (_rxHist[idx] > ymax) ymax = _rxHist[idx];
                if (_txHist[idx] > ymax) ymax = _txHist[idx];
            }
            ymax *= 1.15;  // 15% headroom

            float stepX = graphW / (float)(NM_TRAFFIC_HIST - 1);

            // Helper: costruisce il path di un canale e lo riempie
            void (^drawChannel)(double *, NSColor *, NSColor *) =
                ^(double *hist, NSColor *lineCol, NSColor *fillCol) {
                NSBezierPath *path = [NSBezierPath bezierPath];
                BOOL first = YES;
                for (int i = 0; i < _histCount; i++) {
                    int  idx = (start + i) % NM_TRAFFIC_HIST;
                    // Allinea a destra: i campioni più vecchi a sinistra
                    float px = x + (NM_TRAFFIC_HIST - _histCount + i) * stepX;
                    float py = graphY + (float)(hist[idx] / ymax) * (graphH - 2) + 1;
                    if (first) { [path moveToPoint:NSMakePoint(px, py)]; first = NO; }
                    else        [path lineToPoint:NSMakePoint(px, py)];
                }
                // Chiudi area verso il basso
                NSBezierPath *fill = [path copy];
                int lastI = _histCount - 1;
                int lastIdx2 = (start + lastI) % NM_TRAFFIC_HIST;
                float lastPx = x + (NM_TRAFFIC_HIST - _histCount + lastI) * stepX;
                float firstPx = x + (NM_TRAFFIC_HIST - _histCount) * stepX;
                [fill lineToPoint:NSMakePoint(lastPx, graphY + 1)];
                [fill lineToPoint:NSMakePoint(firstPx, graphY + 1)];
                [fill closePath];
                (void)lastIdx2;
                [fillCol setFill];
                [fill fill];
                [lineCol setStroke];
                path.lineWidth = 1.5;
                [path stroke];
            };

            // TX (arancio) prima → sotto RX
            drawChannel(_txHist,
                [NSColor colorWithRed:1.00 green:0.65 blue:0.15 alpha:0.9],
                [NSColor colorWithRed:0.60 green:0.35 blue:0.05 alpha:0.30]);
            // RX (ciano) sopra
            drawChannel(_rxHist,
                [NSColor colorWithRed:0.30 green:0.78 blue:1.00 alpha:0.9],
                [NSColor colorWithRed:0.05 green:0.35 blue:0.60 alpha:0.30]);

            // Etichetta scala (valore massimo)
            NSString *(^fmtScale)(double) = ^(double v) {
                if (v < 1024)        return [NSString stringWithFormat:@"%.0f B/s",  v];
                if (v < 1024*1024)   return [NSString stringWithFormat:@"%.0f KB/s", v / 1024.0];
                return                      [NSString stringWithFormat:@"%.1f MB/s", v / (1024.0*1024.0)];
            };
            NSDictionary *scaleA = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightLight],
                NSForegroundColorAttributeName: colDim };
            NSString *scaleS = fmtScale(ymax / 1.15);
            [scaleS drawAtPoint:NSMakePoint(x + 3, graphY + graphH - 10) withAttributes:scaleA];
        }

        // Legenda RX / TX
        NSDictionary *legA = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8],
            NSForegroundColorAttributeName: colDim };
        NSString *leg = @"— RX  — TX";
        (void)leg;
        NSString *legRX = @"▬ RX";
        NSString *legTX = @"▬ TX";
        NSDictionary *legRXA = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8],
            NSForegroundColorAttributeName: [NSColor colorWithRed:0.30 green:0.78 blue:1.00 alpha:0.8] };
        NSDictionary *legTXA = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8],
            NSForegroundColorAttributeName: [NSColor colorWithRed:1.00 green:0.65 blue:0.15 alpha:0.8] };
        (void)legA;
        [legRX drawAtPoint:NSMakePoint(x + 3, graphY - 12) withAttributes:legRXA];
        [legTX drawAtPoint:NSMakePoint(x + 38, graphY - 12) withAttributes:legTXA];
    }

    } // end if (_histCount > 0)
}
@end

// ===================== AppDelegate (UI) =====================
@interface AppDelegate : NSObject<NSApplicationDelegate, NSSplitViewDelegate> {
    NSWindow        *_win;
    NMMonitor       *_monitor;
    BOOL             _running;

    // Header
    NSTextField     *_gwField;
    NSTextField     *_intervalField;
    NSButton        *_startBtn;
    NSTextField     *_statusLbl;

    // Panels
    NSTextView      *_logTV;
    NSTextView      *_evTV;

    NMStatsView     *_statsView;

    NSSplitView     *_mainSplit, *_topSplit;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp activateIgnoringOtherApps:YES];
    [self buildMenu];
    [self buildWindow];
    dispatch_async(dispatch_get_main_queue(), ^{
        float cw = self->_win.contentView.frame.size.width;
        float ch = self->_win.contentView.frame.size.height - HEADER_H;
        [self->_mainSplit setPosition:cw * 0.68 ofDividerAtIndex:0];
        [self->_topSplit  setPosition:ch * 0.65 ofDividerAtIndex:0];
    });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

// ---- Helpers ----
- (NSTextField *)makeLbl:(NSString *)s size:(CGFloat)sz bold:(BOOL)b {
    NSTextField *f = [NSTextField labelWithString:s];
    f.font = b ? [NSFont boldSystemFontOfSize:sz] : [NSFont systemFontOfSize:sz];
    f.textColor = [NSColor colorWithWhite:0.80 alpha:1];
    return f;
}
- (NSTextField *)makeInput:(NSString *)placeholder {
    NSTextField *f = [[NSTextField alloc] init];
    f.placeholderString = placeholder;
    f.bezelStyle = NSTextFieldSquareBezel;
    f.font = [NSFont systemFontOfSize:12];
    return f;
}
- (NSTextField *)addRow:(NSView *)panel label:(NSString *)lbl x:(float)x y:(float *)y w:(float)w {
    NSTextField *l = [self makeLbl:lbl size:11 bold:NO];
    l.frame = NSMakeRect(x, *y, w * 0.54, 17);
    l.textColor = [NSColor colorWithWhite:0.50 alpha:1];
    [panel addSubview:l];
    NSTextField *v = [self makeLbl:@"—" size:11 bold:NO];
    v.alignment = NSTextAlignmentRight;
    v.frame = NSMakeRect(x + w * 0.54, *y, w * 0.44, 17);
    v.textColor = [NSColor colorWithWhite:0.88 alpha:1];
    [panel addSubview:v];
    *y -= 21;
    return v;
}
- (NSScrollView *)makeLogPane:(NSTextView * __strong *)tv {
    NSScrollView *sv = [[NSScrollView alloc] init];
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = NO;
    sv.autohidesScrollers = YES;
    sv.borderType = NSNoBorder;
    NSTextView *t = [[NSTextView alloc] initWithFrame:sv.bounds];
    t.editable = NO; t.selectable = YES; t.richText = YES;
    t.backgroundColor = [NSColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1];
    t.textColor = [NSColor colorWithWhite:0.82 alpha:1];
    t.font = [NSFont monospacedSystemFontOfSize:LOG_FONT_SZ weight:NSFontWeightRegular];
    t.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [t.textContainer setWidthTracksTextView:NO];
    [t.textContainer setContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    sv.hasHorizontalScroller = YES;
    sv.documentView = t;
    if (tv) *tv = t;
    return sv;
}

// ---- Window ----
- (void)buildWindow {
    _win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, WIN_W, WIN_H)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _win.title = @"Vibe NetMon";
    _win.minSize = NSMakeSize(900, 550);
    [_win center];
    NSView *cv = _win.contentView;

    // ---- Header bar ----
    NSView *hdr = [[NSView alloc] initWithFrame:NSMakeRect(0, WIN_H - HEADER_H, WIN_W, HEADER_H)];
    hdr.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    hdr.wantsLayer = YES;
    hdr.layer.backgroundColor = [[NSColor colorWithRed:0.10 green:0.12 blue:0.20 alpha:1] CGColor];
    [cv addSubview:hdr];

    float hx = 14, hy = 13;
    _statusLbl = [self makeLbl:@"● IDLE" size:14 bold:YES];
    _statusLbl.frame = NSMakeRect(hx, hy, 100, 24);
    _statusLbl.textColor = [NSColor systemGrayColor];
    [hdr addSubview:_statusLbl]; hx += 116;

    NSTextField *l1 = [self makeLbl:@"Gateway:" size:11 bold:NO];
    l1.frame = NSMakeRect(hx, hy + 3, 56, 18); [hdr addSubview:l1]; hx += 60;
    _gwField = [self makeInput:@"192.168.1.1"];
    _gwField.stringValue = DFLT_GATEWAY;
    _gwField.frame = NSMakeRect(hx, hy, 108, 24); [hdr addSubview:_gwField]; hx += 116;

    NSTextField *l2 = [self makeLbl:@"Intervallo (s):" size:11 bold:NO];
    l2.frame = NSMakeRect(hx, hy + 3, 100, 18); [hdr addSubview:l2]; hx += 104;
    _intervalField = [self makeInput:@"10"];
    _intervalField.stringValue = [NSString stringWithFormat:@"%d", DFLT_INTERVAL_SEC];
    _intervalField.frame = NSMakeRect(hx, hy, 56, 24); [hdr addSubview:_intervalField]; hx += 62;

    NSButton *applyBtn = [NSButton buttonWithTitle:@"Applica" target:self
                                            action:@selector(applyInterval:)];
    applyBtn.frame = NSMakeRect(hx, hy, 72, 24); [hdr addSubview:applyBtn]; hx += 82;

    _startBtn = [NSButton buttonWithTitle:@"▶  Avvia" target:self
                                   action:@selector(toggleMonitor:)];
    _startBtn.frame = NSMakeRect(hx, hy, 106, 24);
    [_startBtn setKeyEquivalent:@"\r"];
    [hdr addSubview:_startBtn];

    // ---- Main content (below header) ----
    // Layout:
    //  _mainSplit  (VERTICAL)
    //  ├── colonna sinistra: _leftSplit (HORIZONTAL)
    //  │   ├── [alto]  log scroll view
    //  │   └── [basso] eventi scroll view
    //  └── colonna destra: _statsView (piena altezza)
    float contentH = WIN_H - HEADER_H;

    // Split principale sinistra/destra
    _mainSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, contentH)];
    _mainSplit.vertical = YES;   // ← divide orizzontalmente lo spazio
    _mainSplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _mainSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _mainSplit.delegate = self;
    [cv addSubview:_mainSplit];

    // Colonna sinistra: log + eventi impilati
    _topSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W * 0.68, contentH)];
    _topSplit.vertical = NO;   // ← divide verticalmente
    _topSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _topSplit.delegate = self;
    [_mainSplit addSubview:_topSplit];

    // Log (alto)
    NSScrollView *logSV = [self makeLogPane:&_logTV];
    logSV.frame = NSMakeRect(0, 0, WIN_W * 0.68, contentH * 0.65);
    [_topSplit addSubview:logSV];

    // Intestazione pane eventi (wrapper con titolo)
    NSView *evWrapper = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W * 0.68, contentH * 0.35)];
    evWrapper.wantsLayer = YES;
    evWrapper.layer.backgroundColor = [[NSColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1] CGColor];
    [_topSplit addSubview:evWrapper];

    NSDictionary *evTitleA = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:8],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.33 alpha:1],
        NSKernAttributeName: @(2.0) };
    NSTextField *evTitle = [NSTextField labelWithString:@""];
    evTitle.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"EVENTI CONNESSIONE" attributes:evTitleA];
    evTitle.frame = NSMakeRect(12, contentH * 0.35 - 20, 200, 14);
    evTitle.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [evWrapper addSubview:evTitle];

    NSScrollView *evSV = [self makeLogPane:&_evTV];
    evSV.frame = NSMakeRect(0, 0, WIN_W * 0.68, contentH * 0.35 - 22);
    evSV.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [evWrapper addSubview:evSV];

    // Colonna destra: stats a piena altezza
    _statsView = [[NMStatsView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W * 0.32, contentH)];
    _statsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_mainSplit addSubview:_statsView];

    [_win makeKeyAndOrderFront:nil];
    [_win makeFirstResponder:_startBtn];
}

// ---- Menu ----
- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    [NSApp setMainMenu:bar];
    NSMenuItem *ai = [[NSMenuItem alloc] init];
    [bar addItem:ai];
    NSMenu *am = [[NSMenu alloc] init];
    ai.submenu = am;
    [am addItemWithTitle:@"Esci da Vibe NetMon" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"Monitor" action:nil keyEquivalent:@""];
    [bar addItem:mi];
    NSMenu *mm = [[NSMenu alloc] initWithTitle:@"Monitor"];
    mi.submenu = mm;
    [mm addItemWithTitle:@"Avvia / Ferma" action:@selector(toggleMonitor:) keyEquivalent:@"r"];
    NSMenuItem *si = [mm addItemWithTitle:@"Pulisci Log" action:@selector(clearLog:) keyEquivalent:@"k"];
    si.target = self;
}

// ---- Actions ----
- (void)toggleMonitor:(id)sender {
    if (_running) {
        [_monitor stop]; _monitor = nil; _running = NO;
        _startBtn.title = @"▶  Avvia";
        _statusLbl.stringValue = @"● STOP";
        _statusLbl.textColor = [NSColor systemGrayColor];
        [self appendLog:@"[info] Monitor fermato.\n" color:[NSColor colorWithWhite:0.5 alpha:1]];
    } else {
        NSString *gw = _gwField.stringValue.length ? _gwField.stringValue : DFLT_GATEWAY;
        int iv = _intervalField.intValue > 0 ? _intervalField.intValue : DFLT_INTERVAL_SEC;
        _monitor = [[NMMonitor alloc] init];
        [_monitor setIntervalSec:iv];
        __weak AppDelegate *ws = self;
        _monitor.onSample = ^(NMSample s, NMStatsSnap snap) { [ws handleSample:s snap:snap]; };
        _monitor.onEvent  = ^(NSString *t, BOOL d)           { [ws handleEvent:t isDown:d];  };
        _monitor.onHourlyReport = ^(NMHourStats *st)         { [ws handleReport:st];         };
        [_monitor startWithGateway:gw];
        _running = YES;
        _startBtn.title = @"■  Ferma";
        _statusLbl.stringValue = @"● AVVIO…";
        _statusLbl.textColor = [NSColor systemYellowColor];
        [self appendLog:[NSString stringWithFormat:@"[info] Monitor avviato — GW=%@  intervallo=%ds\n", gw, iv]
                  color:[NSColor colorWithWhite:0.55 alpha:1]];
    }
}

- (void)applyInterval:(id)sender {
    int iv = _intervalField.intValue;
    if (iv < 1) { iv = 1; _intervalField.intValue = 1; }
    if (_monitor) [_monitor setIntervalSec:iv];
    [self appendLog:[NSString stringWithFormat:@"[info] Intervallo aggiornato: %ds\n", iv]
              color:[NSColor colorWithWhite:0.50 alpha:1]];
}

- (void)clearLog:(id)sender {
    [[_logTV textStorage] deleteCharactersInRange:NSMakeRange(0, _logTV.string.length)];
}

// ---- Sample/event/report handlers ----
- (void)handleSample:(NMSample)s snap:(NMStatsSnap)snap {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:s.ts_unix];
    NSString *(^fmt)(double) = ^(double v) {
        return v < 0 ? @"-" : [NSString stringWithFormat:@"%.0f", v];
    };
    NSString *line = [NSString stringWithFormat:
        @"[%@]  GW=%@(%@ms)  ICMP=%d/%d(%@ms)  DNS=%@(%@ms)  HTTP=%d/%d(%@ms)  INET=%@\n",
        [df stringFromDate:d],
        s.gateway_ok ? @"OK" : @"KO", fmt(s.gateway_rtt),
        s.icmp_ok, s.icmp_total, fmt(s.icmp_median),
        s.dns_ok ? @"OK" : @"KO", fmt(s.dns_ms),
        s.http_ok, s.http_total, fmt(s.http_median),
        s.internet_up ? @"UP" : @"DOWN"];
    NSColor *col = s.internet_up
        ? [NSColor colorWithRed:0.70 green:0.90 blue:0.70 alpha:1]
        : [NSColor colorWithRed:1.00 green:0.38 blue:0.38 alpha:1];
    [self appendLog:line color:col];

    // Status indicator
    if (s.internet_up) {
        _statusLbl.stringValue = @"● UP";
        _statusLbl.textColor   = [NSColor systemGreenColor];
    } else {
        _statusLbl.stringValue = @"● DOWN";
        _statusLbl.textColor   = [NSColor systemRedColor];
    }

    // Stats panel — aggiorna la custom view
    [_statsView updateSnap:snap sample:s isUp:s.internet_up];
}

- (void)handleEvent:(NSString *)text isDown:(BOOL)isDown {
    NSColor *col = isDown
        ? [NSColor colorWithRed:1.0 green:0.38 blue:0.38 alpha:1]
        : [NSColor colorWithRed:0.40 green:1.00 blue:0.50 alpha:1];
    NSString *line = [text stringByAppendingString:@"\n"];
    [self appendLog:line color:col];
    [self appendToTV:_evTV text:line color:col];
}

- (void)handleReport:(NMHourStats *)stats {
    NSString *rep = [stats formatReport];
    [self appendLog:rep color:[NSColor colorWithWhite:0.62 alpha:1]];
}

// ---- Text view helpers ----
- (void)appendLog:(NSString *)text color:(NSColor *)col {
    [self appendToTV:_logTV text:text color:col];
}
- (void)appendToTV:(NSTextView *)tv text:(NSString *)text color:(NSColor *)col {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:LOG_FONT_SZ weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: col
    };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    NSTextStorage *ts = [tv textStorage];
    [ts appendAttributedString:as];
    // Trim if too long (keep last ~150 KB)
    if (ts.length > 250000) {
        NSRange trim = NSMakeRange(0, ts.length - 180000);
        NSRange nl = [ts.string rangeOfString:@"\n" options:0
                                        range:NSMakeRange(trim.length, ts.length - trim.length)];
        if (nl.location != NSNotFound) trim.length = nl.location + 1;
        [ts deleteCharactersInRange:trim];
    }
    [tv scrollToEndOfDocument:nil];
}

// ---- NSSplitView delegate (prevent collapse) ----
- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    if (sv == _mainSplit) return 500;   // colonna sinistra: minimo 500pt larghezza
    if (sv == _topSplit)  return 120;   // log: minimo 120pt altezza
    return 120;
}
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    if (sv == _mainSplit) return sv.frame.size.width - 260; // stats: minimo 260pt larghezza
    if (sv == _topSplit)  return sv.frame.size.height - 80; // eventi: minimo 80pt
    return p;
}
@end

// ===================== main =====================
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        kICMPTargets  = @[@"1.1.1.1", @"8.8.8.8"];
        kDNSTestHost  = @"www.google.com";
        kHTTPTestURLs = @[@"https://www.google.com/generate_204",
                          @"https://www.cloudflare.com/cdn-cgi/trace"];
        kOutputDir    = @"~/internet_monitor_logs";

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
