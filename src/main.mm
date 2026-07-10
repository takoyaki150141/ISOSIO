// ============================================================
// ISOSIO — Auto-tap macro tool for iOS
// Replaces the original memory-scanner / cheat-engine with a
// simple macro recorder / repeater.
//
// Controls (all on the floating button):
//   Single tap      : toggle ON/OFF (auto-tap at recorded target)
//   Long press      : enter config mode (next screen tap = new target)
//   Double tap      : cycle interval (50 / 100 / 200 / 500 / 1000 ms)
//   Drag from anywhere on the button : move the button
//
// Tap injection strategy (3-stage fallback, no jailbreak required):
//   1. Find a UIControl at the target point and trigger
//      sendActionsForControlEvents:UIControlEventTouchUpInside
//   2. Trigger a UITapGestureRecognizer attached to the view at that point
//   3. IOKit HID event (jailbreak only, TODO if needed)
//
// Build: see Makefile
// ============================================================

#import <UIKit/UIKit.h>
#import <UIKit/UIAccessibility.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach_time.h>
#include <dlfcn.h>

// ============================================================
// IOKIT HID (private API, resolved at runtime via dlsym)
// The theos IOKit headers are old enough that including them in a
// modern Objective-C++ TU triggers C++-module / extern-C conflicts,
// so we don't include them. We forward-declare what we need and
// resolve the symbols at runtime. If a symbol is missing (jailbreak
// required) the IOKitHID strategy logs 'not available' and skips.
// ============================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

typedef IOHIDEventRef (*fnIOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef, uint32_t, uint32_t,
    uint32_t, uint64_t, uint32_t,
    double, double, double, double, double, double);
typedef void (*fnIOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int64_t);
typedef IOHIDEventSystemClientRef (*fnIOHIDEventSystemClientCreate)(CFAllocatorRef);
typedef void (*fnIOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);

static fnIOHIDEventCreateDigitizerEvent      pIOHIDEventCreateDigitizerEvent     = NULL;
static fnIOHIDEventSetIntegerValue           pIOHIDEventSetIntegerValue          = NULL;
static fnIOHIDEventSystemClientCreate        pIOHIDEventSystemClientCreate       = NULL;
static fnIOHIDEventSystemClientDispatchEvent pIOHIDEventSystemClientDispatchEvent = NULL;

static BOOL gIOKitResolved = NO;
static BOOL gIOKitAvailable = NO;

static void resolveIOKitOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen(NULL, RTLD_NOW);
        if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) { gIOKitResolved = YES; gIOKitAvailable = NO; return; }
        // dlsym returns void*; assigning to a function-pointer type via
        // implicit conversion is rejected by modern clang with -Werror.
        // Cast through (void**) which is the POSIX-portable way to get
        // a function pointer out of dlsym.
        *(void **)&pIOHIDEventCreateDigitizerEvent      = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        *(void **)&pIOHIDEventSetIntegerValue           = dlsym(h, "IOHIDEventSetIntegerValue");
        *(void **)&pIOHIDEventSystemClientCreate        = dlsym(h, "IOHIDEventSystemClientCreate");
        *(void **)&pIOHIDEventSystemClientDispatchEvent = dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        gIOKitResolved = YES;
        gIOKitAvailable = (pIOHIDEventCreateDigitizerEvent &&
                           pIOHIDEventSetIntegerValue &&
                           pIOHIDEventSystemClientCreate &&
                           pIOHIDEventSystemClientDispatchEvent);
    });
}

// IOHID constants we need (values match the public IOKit headers).
static const uint32_t kIOHIDDigitizerTransducerTypeTouch  = 13;   // IOHIDDigitizerTransducerTypeTouch
static const uint32_t kIOHIDDigitizerEventTouch          = 1u << 0;
static const uint32_t kIOHIDDigitizerEventTouchEnd       = 1u << 1;
static const uint32_t kIOHIDEventFieldDigitizerCollection = 0x0c01;

// ============================================================
// CONFIG
// ============================================================

static const CGFloat kButtonSize          = 50.0;
static const CGFloat kButtonTouchPadding  = 8.0;   // invisible grab area around the circle
static const NSTimeInterval kIntervals[]  = { 0.05, 0.1, 0.2, 0.5, 1.0 };
static const NSInteger kIntervalCount     = sizeof(kIntervals) / sizeof(kIntervals[0]);
static const CGFloat kTargetStopRadius    = 30.0;  // finger-tap tolerance for stop-on-tap

static NSInteger gIntervalIndex = 1;     // default 100 ms

// ============================================================
// TAP STRATEGY
// Different ways to "synthesize a tap" on a target view. The user picks
// one from the log window; the active strategy is shown there too.
// ============================================================

typedef NS_ENUM(NSInteger, TapStrategy) {
    TapStrategyControlAction = 0,   // sendActionsForControlEvents: on the closest UIControl
    TapStrategyTapRecognizer,       // setState:Recognized on the closest UITapGestureRecognizer
    TapStrategyAccessibility,       // accessibilityActivate on the closest accessible element
    TapStrategyIOKitHID,            // IOHIDEvent digitizer touch via IOHIDEventSystemClient
    TapStrategyEarlGrey,            // UITouchesEvent + _addTouch + IOHIDEvent (EarlGrey / XCTest)
    TapStrategyCount
};

static TapStrategy gCurrentStrategy = TapStrategyControlAction;

static NSString *TapStrategyName(TapStrategy s) {
    switch (s) {
        case TapStrategyControlAction: return @"ControlAction";
        case TapStrategyTapRecognizer: return @"TapRecognizer";
        case TapStrategyAccessibility: return @"Accessibility";
        case TapStrategyIOKitHID:      return @"IOKitHID";
        case TapStrategyEarlGrey:      return @"EarlGrey";
        default: return @"?";
    }
}

// ============================================================
// HELPERS
// ============================================================

// iOS 16+ replacement for UIApplication.keyWindow that ignores our tweak's
// own windows. UIWindowScene.keyWindow returns whichever window was most
// recently makeKeyAndVisible'd — if that was our FloatingButton or
// ConfigCaptureWindow, we'd hitTest on a 50x50 button or a full-screen
// capture overlay instead of the host app's content, and the auto-tap
// would silently miss every target.
//
// Strategy:
//   1. If the scene's keyWindow is at or below UIWindowLevelAlert, return
//      it (it's the host app's content, not our overlay)
//   2. Otherwise, walk the scene's windows and pick the lowest-windowLevel
//      non-hidden one (the host app's main window lives at
//      UIWindowLevelNormal, below any of our tweak windows)
//   3. Fall through to nil if nothing matches
static UIWindow *foregroundKeyWindow(UIApplication *app) {
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.keyWindow && ws.keyWindow.windowLevel <= UIWindowLevelAlert) {
            return ws.keyWindow;
        }
        UIWindow *best = nil;
        for (UIWindow *w in ws.windows) {
            if (w.hidden) continue;
            if (w.windowLevel > UIWindowLevelAlert) continue;   // skip our tweak's UIWindowLevelAlert + 99 / + 100
            if (!best || w.windowLevel < best.windowLevel) best = w;
        }
        if (best) return best;
    }
    return nil;
}

// ============================================================
// FORWARD DECLARATIONS
// ============================================================

@class FloatingButton;
@class ConfigCaptureWindow;
@class LogWindow;

// ============================================================
// MACRO STATE — singleton holding target, mode, timer
// ============================================================

@interface MacroState : NSObject {
@public
    CGPoint _target;
    BOOL    _isTargetSet;
    BOOL    _isActive;
    BOOL    _isConfigMode;
    NSTimer *_timer;
    FloatingButton *_button;
    ConfigCaptureWindow *_capture;
    LogWindow *_log;}
+ (instancetype)shared;
- (void)attachButton:(FloatingButton *)button;
- (void)attachCapture:(ConfigCaptureWindow *)capture;
- (void)attachLog:(LogWindow *)log;
- (void)toggle;
- (void)start;
- (void)stop;
- (void)enterConfigMode;
- (void)setTarget:(CGPoint)p;
- (void)cycleInterval;
- (NSString *)statusText;
- (NSString *)intervalText;
- (void)performTap;
@end

// ============================================================
// FLOATING BUTTON
// ============================================================

@interface FloatingButton : UIWindow
@property (nonatomic, strong) UIView *backing;     // invisible touch target, full window bounds
@property (nonatomic, strong) UIView *circle;     // visible circle
@property (nonatomic, strong) UILabel *label;
- (void)refreshDisplay;
- (void)handleTripleTap;   // opens the LogWindow
@end

// ============================================================
// CONFIG CAPTURE WINDOW — full-screen transparent overlay used
// only while the user is selecting a new target location.
// ============================================================

@interface ConfigCaptureWindow : UIWindow
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIView *indicator;
- (void)showForConfig;
- (void)flashTarget:(CGPoint)point;
- (void)hide;
@end

// ============================================================
// MACRO LOG — in-memory ring buffer of debug lines, shown by
// LogWindow. Thread-safe via @synchronized on the backing array.
// ============================================================

@interface MacroLog : NSObject {
    NSMutableArray<NSString *> *_lines;
}
+ (instancetype)shared;
+ (void)record:(NSString *)message;
+ (NSString *)allLinesJoined;
+ (void)clear;
+ (NSUInteger)lineCount;
@end

// Macro for ergonomic call sites. The variadic Objective-C method syntax
// (with NS_FORMAT_FUNCTION) was getting mangled by the compiler's
// method-declaration parser, so the API is now a single-arg method
// driven by a C-macro that builds the formatted string.
#define MACRO_LOG(fmt, ...) [MacroLog record:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]

// ============================================================
// LOG WINDOW — full-screen overlay with scrollable text view +
// Copy / Clear / Start / Close buttons. Shown via triple-tap on
// the floating button. Auto-closes when the user starts the macro
// from inside it (Start) or fires any other floating-button gesture
// (so the log overlay doesn't block auto-tap target resolution).
// ============================================================

@interface LogWindow : UIWindow {
    NSArray<UIButton *> *_strategyButtons;
}
@property (nonatomic, strong) UITextView *textView;
- (void)show;
- (void)hide;
- (void)refresh;
- (void)closeIfOpen;
@end

// ============================================================
// MACRO STATE IMPL
// ============================================================

@implementation MacroState

+ (instancetype)shared {
    static MacroState *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MacroState alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _target = CGPointZero;
        _isTargetSet = NO;
        _isActive = NO;
        _isConfigMode = NO;
    }
    return self;
}

- (void)attachButton:(FloatingButton *)button  { _button = button; }
- (void)attachCapture:(ConfigCaptureWindow *)c { _capture = c; }
- (void)attachLog:(LogWindow *)log            { _log = log; }

- (void)toggle {
    if (_isActive) [self stop];
    else           [self start];
    [_button refreshDisplay];
}

- (void)start {
    if (_isActive) return;
    if (!_isTargetSet) {
        MACRO_LOG(@"start() with no target — entering config mode");
        [self enterConfigMode];
        return;
    }
    _isActive = YES;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kIntervals[gIntervalIndex]
                                              target:self
                                            selector:@selector(performTap)
                                            userInfo:nil
                                             repeats:YES];
    MACRO_LOG(@"MACRO START — target=(%.0f,%.0f) interval=%.0fms",
                 _target.x, _target.y, kIntervals[gIntervalIndex] * 1000);
    [_button refreshDisplay];
}

- (void)stop {
    if (!_isActive && !_timer) return;
    _isActive = NO;
    [_timer invalidate];
    _timer = nil;
    MACRO_LOG(@"MACRO STOP");
    [_button refreshDisplay];
}

- (void)enterConfigMode {
    _isConfigMode = YES;
    _isTargetSet = NO;
    _isActive = NO;
    [_timer invalidate];
    _timer = nil;
    MACRO_LOG(@"Entering CONFIG mode — tap on screen to set target");
    [_capture showForConfig];
    [_button refreshDisplay];
}

- (void)setTarget:(CGPoint)p {
    _target = p;
    _isTargetSet = YES;
    _isConfigMode = NO;
    MACRO_LOG(@"Target set to (%.0f, %.0f)", p.x, p.y);
    [_capture flashTarget:p];
    [_button refreshDisplay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [_capture hide];
    });
}

- (void)cycleInterval {
    gIntervalIndex = (gIntervalIndex + 1) % kIntervalCount;
    NSTimeInterval i = kIntervals[gIntervalIndex];
    if (_isActive) {
        [_timer invalidate];
        _timer = [NSTimer scheduledTimerWithTimeInterval:i
                                                  target:self
                                                selector:@selector(performTap)
                                                userInfo:nil
                                                 repeats:YES];
    }
    MACRO_LOG(@"Interval -> %.0fms", i * 1000);
    [_button refreshDisplay];
}

- (void)setStrategy:(TapStrategy)s {
    gCurrentStrategy = s;
    MACRO_LOG(@"Strategy -> %@", TapStrategyName(s));
    [_button refreshDisplay];
}

- (TapStrategy)currentStrategy { return gCurrentStrategy; }

- (void)cycleStrategy {
    TapStrategy next = (TapStrategy)((gCurrentStrategy + 1) % TapStrategyCount);
    [self setStrategy:next];
}

- (NSString *)statusText {
    if (_isConfigMode) return @"TAP";
    if (_isActive)     return @"ON";
    if (_isTargetSet)  return @"OFF";
    return @"--";
}

- (NSString *)intervalText {
    NSTimeInterval i = kIntervals[gIntervalIndex];
    if (i < 1.0) return [NSString stringWithFormat:@"%.0f", i * 1000];
    return [NSString stringWithFormat:@"%.1fs", i];
}

- (void)performTap {
    if (!_isTargetSet) return;
    CGPoint target = _target;

    UIWindow *targetWindow = foregroundKeyWindow(UIApplication.sharedApplication);
    if (!targetWindow) {
        MACRO_LOG(@"performTap: no target window found, skipping");
        return;
    }

    UIView *hit = [targetWindow hitTest:target withEvent:nil];
    if (!hit) {
        MACRO_LOG(@"performTap: hitTest returned nil (strategy %@)", TapStrategyName(gCurrentStrategy));
        return;
    }

    switch (gCurrentStrategy) {
        case TapStrategyControlAction: {
            UIControl *ctrl = [self findControlIn:hit];
            if (ctrl) {
                MACRO_LOG(@"performTap: ControlAction on %@", NSStringFromClass(ctrl.class));
                [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
            MACRO_LOG(@"performTap: ControlAction — no UIControl in hierarchy under %@",
                     NSStringFromClass(hit.class));
            break;
        }
        case TapStrategyTapRecognizer: {
            UITapGestureRecognizer *tap = [self findTapGestureIn:hit];
            if (tap && tap.state == UIGestureRecognizerStatePossible) {
                MACRO_LOG(@"performTap: TapRecognizer — firing");
                [tap setState:UIGestureRecognizerStateRecognized];
                return;
            }
            MACRO_LOG(@"performTap: TapRecognizer — no recognizer in hierarchy");
            break;
        }
        case TapStrategyAccessibility: {
            // Walk up from hit, looking for an accessibility container that
            // can produce an element at the target point.
            //
            // The UIAccessibilityContainer protocol is not in the public
            // iOS 17.5 SDK headers, so we can't reference its selector
            // through dot syntax even on an `id` receiver. objc_msgSend
            // with a typed function-pointer cast is the only way to
            // dispatch this selector at compile time without dragging
            // in a private header.
            typedef id (*aeap_fn)(id, SEL, CGPoint);
            UIView *v = hit;
            UIAccessibilityElement *element = nil;
            while (v && !element) {
                if ([v respondsToSelector:@selector(accessibilityElementAtPoint:)]) {
                    CGPoint local = [v convertPoint:target fromView:nil];
                    id e = ((aeap_fn)objc_msgSend)(v, @selector(accessibilityElementAtPoint:), local);
                    if ([e isKindOfClass:[UIAccessibilityElement class]]) element = e;
                }
                v = v.superview;
            }
            id target_ = element ?: hit;
            if ([target_ respondsToSelector:@selector(accessibilityActivate)]) {
                MACRO_LOG(@"performTap: Accessibility — calling accessibilityActivate on %@",
                         NSStringFromClass([target_ class]));
                BOOL ok = [target_ accessibilityActivate];
                MACRO_LOG(@"performTap: Accessibility returned %d", ok);
                return;
            }
            MACRO_LOG(@"performTap: Accessibility — no activatable element");
            break;
        }
        case TapStrategyIOKitHID: {
            resolveIOKitOnce();
            if (!gIOKitAvailable) {
                MACRO_LOG(@"performTap: IOKitHID — not available (jailbreak / entitlement required)");
                break;
            }
            IOHIDEventSystemClientRef client = pIOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!client) {
                MACRO_LOG(@"performTap: IOKitHID — system client create returned NULL");
                break;
            }
            uint64_t ts = mach_absolute_time();
            IOHIDEventRef down = pIOHIDEventCreateDigitizerEvent(
                kCFAllocatorDefault,
                kIOHIDDigitizerTransducerTypeTouch,
                1,
                kIOHIDDigitizerEventTouch,
                ts, 0,
                (double)target.x, (double)target.y,
                0, 0, 0, 0);
            if (down) {
                pIOHIDEventSetIntegerValue(down, kIOHIDEventFieldDigitizerCollection, 1);
                pIOHIDEventSystemClientDispatchEvent(client, down);
                CFRelease(down);
            }
            usleep(20000);
            uint64_t ts2 = mach_absolute_time();
            IOHIDEventRef up = pIOHIDEventCreateDigitizerEvent(
                kCFAllocatorDefault,
                kIOHIDDigitizerTransducerTypeTouch,
                1,
                kIOHIDDigitizerEventTouch,
                ts2,
                kIOHIDDigitizerEventTouchEnd,
                (double)target.x, (double)target.y,
                0, 0, 0, 0);
            if (up) {
                pIOHIDEventSetIntegerValue(up, kIOHIDEventFieldDigitizerCollection, 1);
                pIOHIDEventSystemClientDispatchEvent(client, up);
                CFRelease(up);
            }
            CFRelease(client);
            MACRO_LOG(@"performTap: IOKitHID — dispatched down+up at (%.0f,%.0f)", target.x, target.y);
            return;
        }
        case TapStrategyEarlGrey: {
            // EarlGrey (google.com's iOS UI testing framework) approach.
            // Used internally by XCTest. The path is:
            //   1. Get UIApplication._touchesEvent (private)
            //   2. _clearTouches + _addTouch:forDelayedDelivery:
            //   3. Build IOHIDEvent and bind via UITouch._setHidEvent:
            //      and UITouchesEvent._setHIDEvent:
            //   4. sendEvent: on UIApplication
            // Works for both UIKit and many games (anything that uses the
            // standard hit-test + responder chain, since dispatch goes
            // through the same plumbing as a real touch).
            if (![UIApplication.sharedApplication respondsToSelector:@selector(_touchesEvent)]) {
                MACRO_LOG(@"performTap: EarlGrey — _touchesEvent unavailable");
                break;
            }
            id touchesEvent = [UIApplication.sharedApplication performSelector:@selector(_touchesEvent)];
            if (!touchesEvent ||
                ![touchesEvent respondsToSelector:@selector(_clearTouches)] ||
                ![touchesEvent respondsToSelector:@selector(_addTouch:forDelayedDelivery:)] ||
                ![touchesEvent respondsToSelector:@selector(_setHIDEvent:)]) {
                MACRO_LOG(@"performTap: EarlGrey — required private methods missing");
                break;
            }
            resolveIOKitOnce();
            if (!gIOKitAvailable) {
                MACRO_LOG(@"performTap: EarlGrey — IOHit HID symbols missing, need a real touch only");
                // Fall through, dispatch without a HID event attached.
            }

            // Build the touch.
            UITouch *touch = [[UITouch alloc] init];
            [touch setValue:@(1)                                  forKey:@"tapCount"];
            [touch setValue:[NSValue valueWithCGPoint:target]      forKey:@"locationInWindow"];
            [touch setValue:[NSValue valueWithCGPoint:target]      forKey:@"previousLocationInWindow"];
            [touch setValue:@(UITouchPhaseBegan)                   forKey:@"phase"];
            [touch setValue:targetWindow                           forKey:@"window"];
            [touch setValue:hit                                    forKey:@"view"];
            [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"timestamp"];

            // Build the HID event.
            IOHIDEventRef hidEvent = NULL;
            if (gIOKitAvailable) {
                hidEvent = pIOHIDEventCreateDigitizerEvent(
                    kCFAllocatorDefault,
                    kIOHIDDigitizerTransducerTypeTouch,
                    1,
                    kIOHIDDigitizerEventTouch,
                    mach_absolute_time(), 0,
                    (double)target.x, (double)target.y,
                    0, 0, 0, 0);
                if (hidEvent) {
                    pIOHIDEventSetIntegerValue(hidEvent, kIOHIDEventFieldDigitizerCollection, 1);
                }
            }

            [touchesEvent performSelector:@selector(_clearTouches)];

            if (hidEvent && [touch respondsToSelector:@selector(_setHidEvent:)]) {
                [touch performSelector:@selector(_setHidEvent:) withObject:(__bridge id)hidEvent];
            }
            [touchesEvent performSelector:@selector(_addTouch:forDelayedDelivery:)
                                withObject:touch
                                withObject:(__bridge id)NO];
            if (hidEvent) {
                [touchesEvent performSelector:@selector(_setHIDEvent:) withObject:(__bridge id)hidEvent];
            }

            [UIApplication.sharedApplication sendEvent:touchesEvent];

            [touchesEvent performSelector:@selector(_clearTouches)];
            if (hidEvent) CFRelease(hidEvent);

            MACRO_LOG(@"performTap: EarlGrey — dispatched via _touchesEvent at (%.0f,%.0f) hidEvent=%@",
                      target.x, target.y, hidEvent ? @"yes" : @"no");
            return;
        }
        default:
            break;
    }
}

- (UIControl *)findControlIn:(UIView *)view {
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)view;
        if (c.enabled) return c;
    }
    for (UIView *sub in view.subviews) {
        UIControl *c = [self findControlIn:sub];
        if (c) return c;
    }
    return nil;
}

- (UITapGestureRecognizer *)findTapGestureIn:(UIView *)view {
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
            return (UITapGestureRecognizer *)g;
        }
    }
    for (UIView *sub in view.subviews) {
        UITapGestureRecognizer *t = [self findTapGestureIn:sub];
        if (t) return t;
    }
    return nil;
}

@end

// ============================================================
// FLOATING BUTTON IMPL
// ============================================================

@implementation FloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;

        // iOS 26 requires every UIWindow to have a rootViewController at the
        // end of application launch. Attach a transparent dummy so UIKit's
        // scene-lifecycle assertion passes.
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        self.rootViewController = vc;
        UIView *rootView = vc.view;

        // Backing view: covers the whole window, makes the whole square tappable
        CGRect backingFrame = CGRectInset(self.bounds, -kButtonTouchPadding, -kButtonTouchPadding);
        _backing = [[UIView alloc] initWithFrame:backingFrame];
        _backing.backgroundColor = UIColor.clearColor;
        _backing.userInteractionEnabled = YES;
        [rootView addSubview:_backing];

        // Visible circle (slightly smaller than the window for visual margin)
        CGRect circleFrame = CGRectInset(self.bounds, 3, 3);
        _circle = [[UIView alloc] initWithFrame:circleFrame];
        _circle.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.85];
        _circle.layer.cornerRadius = circleFrame.size.width / 2.0;
        _circle.layer.borderWidth = 2.0;
        _circle.layer.borderColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:0.8].CGColor;
        _circle.userInteractionEnabled = NO;
        [rootView addSubview:_circle];

        _label = [[UILabel alloc] initWithFrame:_circle.bounds];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        _label.textColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:1.0];
        _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        [rootView addSubview:_label];

        // Gestures
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.maximumNumberOfTouches = 1;        // keep pan 1-finger only
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap)];
        [self addGestureRecognizer:single];

        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap)];
        dbl.numberOfTapsRequired = 2;
        [self addGestureRecognizer:dbl];
        [single requireGestureRecognizerToFail:dbl];

        UITapGestureRecognizer *trp = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleTap)];
        trp.numberOfTapsRequired = 3;
        [self addGestureRecognizer:trp];
        [dbl requireGestureRecognizerToFail:trp];

        UITapGestureRecognizer *twoFinger = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTwoFingerTap)];
        twoFinger.numberOfTouchesRequired = 2;
        twoFinger.numberOfTapsRequired = 1;
        [self addGestureRecognizer:twoFinger];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.55;
        [self addGestureRecognizer:lp];

        [MacroState.shared attachButton:self];
        [self refreshDisplay];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGRect f = self.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect sb = UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(sb.size.width  - f.size.width,  f.origin.x));
    f.origin.y = MAX(0, MIN(sb.size.height - f.size.height, f.origin.y));
    self.frame = f;
    [g setTranslation:CGPointZero inView:self];
}

- (void)handleSingleTap {
    MacroState *s = MacroState.shared;
    [s->_log closeIfOpen];   // any real gesture → drop the log overlay
    if (s->_isConfigMode) return;   // already waiting for a screen tap
    if (!s->_isTargetSet) {
        [s enterConfigMode];
    } else {
        [s toggle];
    }
}

- (void)handleDoubleTap {
    MacroState *s = MacroState.shared;
    [s->_log closeIfOpen];
    [s cycleInterval];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        MacroState *s = MacroState.shared;
        [s->_log closeIfOpen];
        [s enterConfigMode];
    }
}

- (void)handleTripleTap {
    MacroState *s = MacroState.shared;
    if (s->_log) {
        if (s->_log.hidden) [s->_log show];
        else                [s->_log hide];
    }
}

- (void)handleTwoFingerTap {
    MacroState *s = MacroState.shared;
    [s->_log closeIfOpen];
    [s cycleStrategy];
}

- (void)refreshDisplay {
    MacroState *s = MacroState.shared;
    _label.text = [NSString stringWithFormat:@"%@\n%@ms", [s statusText], [s intervalText]];

    if (s->_isActive) {
        _circle.backgroundColor = [UIColor colorWithRed:0.1 green:0.4 blue:0.1 alpha:0.9];
        _circle.layer.borderColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.3 alpha:1.0].CGColor;
    } else if (s->_isConfigMode) {
        _circle.backgroundColor = [UIColor colorWithRed:0.4 green:0.2 blue:0.0 alpha:0.9];
        _circle.layer.borderColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0].CGColor;
    } else {
        _circle.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.85];
        _circle.layer.borderColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:0.8].CGColor;
    }
}

@end

// ============================================================
// CONFIG CAPTURE WINDOW IMPL
// ============================================================

@implementation ConfigCaptureWindow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 99;
        self.backgroundColor = UIColor.clearColor;
        self.hidden = YES;

        // iOS 26 requires every UIWindow to have a rootViewController. Attach
        // a transparent dummy so UIKit's scene-lifecycle assertion passes.
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        self.rootViewController = vc;
        UIView *rootView = vc.view;

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        _dim.userInteractionEnabled = NO;
        [rootView addSubview:_dim];

        _hint = [[UILabel alloc] initWithFrame:CGRectMake(20, self.bounds.size.height/2 - 60,
                                                          self.bounds.size.width - 40, 120)];
        _hint.text = @"Tap the spot you want\nthe macro to repeat";
        _hint.textAlignment = NSTextAlignmentCenter;
        _hint.numberOfLines = 0;
        _hint.textColor = UIColor.whiteColor;
        _hint.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        _hint.userInteractionEnabled = NO;
        [rootView addSubview:_hint];

        _indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        _indicator.layer.cornerRadius = 18;
        _indicator.layer.borderWidth = 3;
        _indicator.layer.borderColor = [UIColor systemRedColor].CGColor;
        _indicator.backgroundColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.4];
        _indicator.hidden = YES;
        _indicator.userInteractionEnabled = NO;
        [rootView addSubview:_indicator];
    }
    return self;
}

- (void)showForConfig {
    _dim.hidden = NO;
    _hint.hidden = NO;
    _indicator.hidden = YES;
    // Just show — don't makeKeyAndVisible, same reason as the floating
    // button: we don't want the capture overlay to steal the scene's
    // keyWindow status.
    self.hidden = NO;
}

- (void)flashTarget:(CGPoint)point {
    _dim.hidden = YES;
    _hint.hidden = YES;
    _indicator.center = point;
    _indicator.hidden = NO;
    // Same reason as showForConfig: don't steal the keyWindow.
    self.hidden = NO;
}

- (void)hide {
    self.hidden = YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    MacroState *s = MacroState.shared;
    if (s->_isConfigMode) {
        [s setTarget:p];
    }
}

@end

// ============================================================
// UIApplication.sendEvent: SWIZZLE
// Capture real user touches (auto-tap fires via sendActionsForControlEvents:
// and does NOT go through sendEvent:, so this only sees intentional taps).
// When a touch ends within kTargetStopRadius of the recorded target while
// auto-tap is active, stop the macro.
// ============================================================

@implementation UIApplication (MacroStopOnTap)

- (void)macro_swizzledSendEvent:(UIEvent *)event {
    @try {
        MacroState *s = MacroState.shared;
        if (s->_isActive && event.type == UIEventTypeTouches) {
            UIWindow *kw = foregroundKeyWindow(self);
            if (!kw) {
                MACRO_LOG(@"swizzle: no foreground window, stop-on-tap can't evaluate");
            }
            for (UITouch *t in [event allTouches]) {
                if (t.phase != UITouchPhaseEnded) continue;
                if (!kw) break;
                CGPoint p = [t locationInView:kw];
                if (s->_button && CGRectContainsPoint(s->_button.frame, p)) {
                    MACRO_LOG(@"swizzle: touch on floating button, ignored");
                    continue;
                }
                CGFloat dx = p.x - s->_target.x;
                CGFloat dy = p.y - s->_target.y;
                CGFloat dist = sqrtf(dx * dx + dy * dy);
                MACRO_LOG(@"swizzle: touchEnd @ (%.0f,%.0f) dist=%.1f (radius=%.0f) target=(%.0f,%.0f)",
                             p.x, p.y, dist, kTargetStopRadius, s->_target.x, s->_target.y);
                if (dist < kTargetStopRadius) {
                    MACRO_LOG(@"swizzle: in radius — stopping macro");
                    dispatch_async(dispatch_get_main_queue(), ^{ [s stop]; });
                    break;
                }
            }
        }
    } @catch (NSException *e) {
        MACRO_LOG(@"swizzle exception: %@", e.reason);
    }
    [self macro_swizzledSendEvent:event];   // call original (swapped at +load)
}

+ (void)load {
    Method orig = class_getInstanceMethod(self, @selector(sendEvent:));
    Method swiz = class_getInstanceMethod(self, @selector(macro_swizzledSendEvent:));
    if (orig && swiz) {
        method_exchangeImplementations(orig, swiz);
        NSLog(@"[Macro] UIApplication.sendEvent: swizzle installed");
    } else {
        NSLog(@"[Macro] UIApplication.sendEvent: swizzle FAILED to install (orig=%p swiz=%p)", orig, swiz);
    }
}

@end

// ============================================================
// MACRO LOG IMPL
// ============================================================

@implementation MacroLog

+ (instancetype)shared {
    static MacroLog *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MacroLog alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = [NSMutableArray new];
    }
    return self;
}

+ (void)record:(NSString *)message {
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                  dateStyle:NSDateFormatterNoStyle
                                                  timeStyle:NSDateFormatterMediumStyle];
    NSString *full = [NSString stringWithFormat:@"[%@] %@", ts, message];

    [[self shared] appendLine:full];
    NSLog(@"[Macro] %@", message);
}

- (void)appendLine:(NSString *)line {
    @synchronized (_lines) {
        while (_lines.count >= 200) { [_lines removeObjectAtIndex:0]; }
        [_lines addObject:line];
    }
}

+ (NSString *)allLinesJoined {
    return [[self shared] allLinesJoinedInternal];
}

- (NSString *)allLinesJoinedInternal {
    @synchronized (_lines) {
        return [_lines componentsJoinedByString:@"\n"];
    }
}

+ (void)clear {
    [[self shared] clearInternal];
}

- (void)clearInternal {
    @synchronized (_lines) {
        [_lines removeAllObjects];
    }
}

+ (NSUInteger)lineCount {
    @synchronized ([self shared]->_lines) {
        return [self shared]->_lines.count;
    }
}

@end

// ============================================================
// LOG WINDOW IMPL
// ============================================================

@implementation LogWindow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Below the floating button (+100) and the capture overlay (+99)
        // so the button stays tappable while the log window is shown.
        self.windowLevel = UIWindowLevelAlert + 98;
        self.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:0.97];
        self.hidden = YES;

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = UIColor.clearColor;
        self.rootViewController = vc;
        UIView *rootView = vc.view;

        // Top: title + Close
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 30,
                                                                   self.bounds.size.width - 100, 40)];
        title.text = @"ISOSIO Macro Log";
        title.textColor = UIColor.whiteColor;
        title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        [rootView addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(self.bounds.size.width - 90, 30, 70, 40);
        [close setTitle:@"Close" forState:UIControlStateNormal];
        [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
        [rootView addSubview:close];

        // Middle: scrollable log text
        _textView = [[UITextView alloc] initWithFrame:CGRectMake(10, 80,
                                                                  self.bounds.size.width - 20,
                                                                  self.bounds.size.height - 200)];
        _textView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _textView.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
        _textView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        _textView.editable = NO;
        _textView.scrollEnabled = YES;
        _textView.alwaysBounceVertical = YES;
        _textView.layer.cornerRadius = 6;
        _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
        [rootView addSubview:_textView];

        // Bottom: action buttons
        CGFloat buttonY  = self.bounds.size.height - 90;
        CGFloat buttonH  = 50;
        CGFloat buttonW  = (self.bounds.size.width - 50) / 3;
        CGFloat gap      = 10;

        UIButton *copy = [self makeButton:@"Copy"
                                    frame:CGRectMake(10, buttonY, buttonW, buttonH)
                                    action:@selector(handleCopy)];
        [rootView addSubview:copy];

        UIButton *clear = [self makeButton:@"Clear"
                                     frame:CGRectMake(10 + buttonW + gap, buttonY, buttonW, buttonH)
                                     action:@selector(handleClear)];
        [rootView addSubview:clear];

        UIButton *start = [self makeButton:@"Start"
                                     frame:CGRectMake(10 + (buttonW + gap) * 2, buttonY, buttonW, buttonH)
                                     action:@selector(handleStart)];
        start.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.2 alpha:0.6];
        [rootView addSubview:start];

        // Strategy picker: 5 small buttons in a row, just above the text view.
        // Tapping sets the active strategy; active one is highlighted.
        NSMutableArray *btns = [NSMutableArray array];
        CGFloat stratY = 78;
        CGFloat stratH = 36;
        CGFloat stratW = (self.bounds.size.width - 60) / 5;
        NSArray *labels = @[ @"Control", @"Gesture", @"Access", @"IOKit", @"EarlG" ];
        for (NSInteger i = 0; i < 5; i++) {
            CGRect fr = CGRectMake(10 + i * (stratW + 2.5), stratY, stratW, stratH);
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = fr;
            b.tag = i;
            [b setTitle:labels[i] forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            b.layer.cornerRadius = 6;
            [b addTarget:self action:@selector(handleStrategy:) forControlEvents:UIControlEventTouchUpInside];
            [rootView addSubview:b];
            [btns addObject:b];
        }
        _strategyButtons = btns;
        [self refreshStrategyButtons];

        // Push the text view down to make room for the strategy row.
        CGRect tv = _textView.frame;
        tv.origin.y = stratY + stratH + 8;
        tv.size.height = self.bounds.size.height - tv.origin.y - (self.bounds.size.height - buttonY) - 8;
        _textView.frame = tv;
    }
    return self;
}

- (UIButton *)makeButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)show {
    [self refresh];
    self.hidden = NO;
    MACRO_LOG(@"Log window opened");
}

- (void)hide {
    self.hidden = YES;
}

- (void)closeIfOpen {
    if (!self.hidden) {
        self.hidden = YES;
        MACRO_LOG(@"Log window closed (auto, gesture fired)");
    }
}

- (void)handleCopy {
    NSString *text = [MacroLog allLinesJoined];
    [UIPasteboard generalPasteboard].string = text;
    MACRO_LOG(@"Copied %lu chars to clipboard", (unsigned long)text.length);
    // brief on-button feedback
    UIButton *sender = (UIButton *)[self viewWithTag:0] ?: nil;
    (void)sender;
}

- (void)handleClear {
    [MacroLog clear];
    [self refresh];
    MACRO_LOG(@"Log buffer cleared by user");
}

- (void)handleStart {
    MACRO_LOG(@"Start button pressed -> closing log window and toggling macro");
    [self hide];
    MacroState *s = MacroState.shared;
    if (!s->_isTargetSet) {
        [s enterConfigMode];
    } else {
        [s toggle];
    }
}

- (void)handleStrategy:(UIButton *)sender {
    TapStrategy s = (TapStrategy)sender.tag;
    [MacroState.shared setStrategy:s];
    [self refreshStrategyButtons];
}

- (void)refreshStrategyButtons {
    TapStrategy cur = [MacroState.shared currentStrategy];
    UIColor *active   = [UIColor colorWithRed:0.0 green:0.6 blue:0.4 alpha:0.85];
    UIColor *inactive = [UIColor colorWithWhite:1.0 alpha:0.18];
    for (UIButton *b in _strategyButtons) {
        BOOL isActive = ((TapStrategy)b.tag == cur);
        b.backgroundColor = isActive ? active : inactive;
        b.layer.borderWidth = isActive ? 1.5 : 0;
        b.layer.borderColor = UIColor.whiteColor.CGColor;
    }
}

- (void)refresh {
    _textView.text = [MacroLog allLinesJoined];
    if (_textView.text.length > 0) {
        NSRange bottom = NSMakeRange(_textView.text.length - 1, 1);
        [_textView scrollRangeToVisible:bottom];
    }
    [self refreshStrategyButtons];
}

@end

// ============================================================
// BOOTSTRAP
// ============================================================

static FloatingButton      *gButton  = nil;
static ConfigCaptureWindow *gCapture = nil;
static LogWindow           *gLog     = nil;

__attribute__((constructor))
static void initialize() {
    NSLog(@"[Macro] loaded");

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification * _Nonnull note) {
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect bFrame = CGRectMake(20, screen.size.height / 3.0,
                                   kButtonSize, kButtonSize);
        gButton = [[FloatingButton alloc] initWithFrame:bFrame];
        // Just show — do NOT makeKeyAndVisible. If we did, our 50x50 button
        // window would become the scene's keyWindow and auto-tap would
        // hitTest on the button instead of the host app's content.
        gButton.hidden = NO;

        gCapture = [[ConfigCaptureWindow alloc] initWithFrame:screen];
        gLog     = [[LogWindow alloc] initWithFrame:screen];

        [MacroState.shared attachCapture:gCapture];
        [MacroState.shared attachLog:gLog];

        MACRO_LOG(@"Button @ %@, capture + log ready", NSStringFromCGRect(bFrame));
        MACRO_LOG(@"Triple-tap the floating button to open the log window");
    }];
}
