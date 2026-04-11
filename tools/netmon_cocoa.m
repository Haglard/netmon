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
} NMSample;

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

    // Stats labels
    NSTextField     *_lblAvail, *_lblDowntime, *_lblSamples;
    NSTextField     *_lblDisconn, *_lblGW;
    NSTextField     *_lblICMPMed, *_lblICMPP95;
    NSTextField     *_lblDNS, *_lblHTTPMed, *_lblHTTMP95;

    NSSplitView     *_mainSplit, *_topSplit;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp activateIgnoringOtherApps:YES];
    [self buildMenu];
    [self buildWindow];
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
    float contentH = WIN_H - HEADER_H;

    _mainSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, contentH)];
    _mainSplit.vertical = NO;
    _mainSplit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _mainSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _mainSplit.delegate = self;
    [cv addSubview:_mainSplit];

    // Top: log + stats side by side
    _topSplit = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, WIN_W, contentH * 0.65)];
    _topSplit.vertical = YES;
    _topSplit.dividerStyle = NSSplitViewDividerStyleThin;
    _topSplit.delegate = self;
    [_mainSplit addSubview:_topSplit];

    // Log panel (left)
    NSScrollView *logSV = [self makeLogPane:&_logTV];
    logSV.frame = NSMakeRect(0, 0, WIN_W * 0.62, contentH * 0.65);
    [_topSplit addSubview:logSV];

    // Stats panel (right)
    float pw = WIN_W * 0.38;
    NSView *statsPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, pw, contentH * 0.65)];
    statsPanel.wantsLayer = YES;
    statsPanel.layer.backgroundColor = [[NSColor colorWithRed:0.08 green:0.10 blue:0.16 alpha:1] CGColor];
    [_topSplit addSubview:statsPanel];

    float sx = 14, sy = contentH * 0.65 - 32, sw = pw - 28;
    NSTextField *stitle = [self makeLbl:@"STATISTICHE ORA CORRENTE" size:9 bold:YES];
    stitle.frame = NSMakeRect(sx, sy, sw, 16);
    stitle.textColor = [NSColor colorWithWhite:0.38 alpha:1];
    stitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [statsPanel addSubview:stitle]; sy -= 22;

    _lblAvail    = [self addRow:statsPanel label:@"Disponibilità"   x:sx y:&sy w:sw];
    _lblDowntime = [self addRow:statsPanel label:@"Downtime"        x:sx y:&sy w:sw];
    _lblSamples  = [self addRow:statsPanel label:@"Campioni"        x:sx y:&sy w:sw];
    _lblDisconn  = [self addRow:statsPanel label:@"Disc. / Riconn." x:sx y:&sy w:sw];
    sy -= 6;
    _lblGW       = [self addRow:statsPanel label:@"GW latenza med." x:sx y:&sy w:sw];
    _lblICMPMed  = [self addRow:statsPanel label:@"ICMP mediana"    x:sx y:&sy w:sw];
    _lblICMPP95  = [self addRow:statsPanel label:@"ICMP p95"        x:sx y:&sy w:sw];
    _lblDNS      = [self addRow:statsPanel label:@"DNS mediano"     x:sx y:&sy w:sw];
    _lblHTTPMed  = [self addRow:statsPanel label:@"HTTP mediano"    x:sx y:&sy w:sw];
    _lblHTTMP95  = [self addRow:statsPanel label:@"HTTP p95"        x:sx y:&sy w:sw];

    // Separator
    NSTextField *evtitle = [self makeLbl:@"EVENTI CONNESSIONE" size:9 bold:YES];
    evtitle.frame = NSMakeRect(sx, 28, sw, 16);
    evtitle.textColor = [NSColor colorWithWhite:0.38 alpha:1];
    evtitle.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [statsPanel addSubview:evtitle];

    // Events pane (bottom)
    NSScrollView *evSV = [self makeLogPane:&_evTV];
    evSV.frame = NSMakeRect(0, 0, WIN_W, contentH * 0.35);
    [_mainSplit addSubview:evSV];

    [_mainSplit setPosition:contentH * 0.65 ofDividerAtIndex:0];
    [_topSplit  setPosition:WIN_W * 0.62    ofDividerAtIndex:0];

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

    // Stats panel
    NSString *(^ms)(double) = ^(double v) {
        return v < 0 ? @"—" : [NSString stringWithFormat:@"%.1f ms", v];
    };
    _lblAvail.stringValue    = [NSString stringWithFormat:@"%.2f%%", snap.availability];
    _lblAvail.textColor      = snap.availability < 99.0
        ? [NSColor systemOrangeColor] : [NSColor colorWithRed:0.4 green:0.9 blue:0.5 alpha:1];
    _lblDowntime.stringValue = [NSString stringWithFormat:@"%.0f s", snap.downtimeSec];
    _lblSamples.stringValue  = [NSString stringWithFormat:@"%d", snap.samples];
    _lblDisconn.stringValue  = [NSString stringWithFormat:@"%d / %d",
                                snap.disconnectEvents, snap.reconnectEvents];
    _lblGW.stringValue      = ms(snap.gwMedian);
    _lblICMPMed.stringValue = ms(snap.icmpMedian);
    _lblICMPP95.stringValue = ms(snap.icmpP95);
    _lblDNS.stringValue     = ms(snap.dnsMedian);
    _lblHTTPMed.stringValue = ms(snap.httpMedian);
    _lblHTTMP95.stringValue = ms(snap.httpP95);
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
    return (sv == _topSplit) ? 420 : 200;
}
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    if (sv == _topSplit) return sv.frame.size.width - 280;
    return sv.frame.size.height - 160;
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
