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
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach/mach_time.h>

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
// HELPERS
// ============================================================

// iOS 13+ replacement for UIApplication.keyWindow. Returns the key window of
// the active foreground scene, or nil if there isn't one.
static UIWindow *foregroundKeyWindow(UIApplication *app) {
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindow *w = ((UIWindowScene *)scene).keyWindow;
            if (w) return w;
        }
    }
    return nil;
}

// ============================================================
// FORWARD DECLARATIONS
// ============================================================

@class FloatingButton;
@class ConfigCaptureWindow;

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
}
+ (instancetype)shared;
- (void)attachButton:(FloatingButton *)button;
- (void)attachCapture:(ConfigCaptureWindow *)capture;
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

- (void)toggle {
    if (_isActive) [self stop];
    else           [self start];
    [_button refreshDisplay];
}

- (void)start {
    if (_isActive) return;
    if (!_isTargetSet) {
        [self enterConfigMode];
        return;
    }
    _isActive = YES;
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kIntervals[gIntervalIndex]
                                              target:self
                                            selector:@selector(performTap)
                                            userInfo:nil
                                             repeats:YES];
    [_button refreshDisplay];
}

- (void)stop {
    _isActive = NO;
    [_timer invalidate];
    _timer = nil;
    [_button refreshDisplay];
}

- (void)enterConfigMode {
    _isConfigMode = YES;
    _isTargetSet = NO;
    _isActive = NO;
    [_timer invalidate];
    _timer = nil;
    [_capture showForConfig];
    [_button refreshDisplay];
}

- (void)setTarget:(CGPoint)p {
    _target = p;
    _isTargetSet = YES;
    _isConfigMode = NO;
    [_capture flashTarget:p];
    [_button refreshDisplay];
    // After a short flash, return key window to the app
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [_capture hide];
    });
}

- (void)cycleInterval {
    gIntervalIndex = (gIntervalIndex + 1) % kIntervalCount;
    if (_isActive) {
        [_timer invalidate];
        _timer = [NSTimer scheduledTimerWithTimeInterval:kIntervals[gIntervalIndex]
                                                  target:self
                                                selector:@selector(performTap)
                                                userInfo:nil
                                                 repeats:YES];
    }
    [_button refreshDisplay];
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

    // Find the active foreground window
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.hidden && w.screen == UIScreen.mainScreen) {
                        targetWindow = w;
                        break;
                    }
                }
            }
            if (targetWindow) break;
        }
    }
    if (!targetWindow) targetWindow = foregroundKeyWindow(UIApplication.sharedApplication);
    if (!targetWindow) return;

    UIView *hit = [targetWindow hitTest:target withEvent:nil];
    if (!hit) return;

    // Strategy 1: find a UIControl and fire its action
    UIControl *ctrl = [self findControlIn:hit];
    if (ctrl) {
        [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    // Strategy 2: trigger a UITapGestureRecognizer
    UITapGestureRecognizer *tap = [self findTapGestureIn:hit];
    if (tap && tap.state == UIGestureRecognizerStatePossible) {
        // Synthesize a recognizer fire. Note: this is a best-effort fallback.
        [tap setState:UIGestureRecognizerStateRecognized];
        return;
    }
    // Nothing to do — game / non-UIKit content. User needs IOKit fallback (jailbreak).
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

        // Backing view: covers the whole window, makes the whole square tappable
        CGRect backingFrame = CGRectInset(self.bounds, -kButtonTouchPadding, -kButtonTouchPadding);
        _backing = [[UIView alloc] initWithFrame:backingFrame];
        _backing.backgroundColor = UIColor.clearColor;
        _backing.userInteractionEnabled = YES;
        [self addSubview:_backing];

        // Visible circle (slightly smaller than the window for visual margin)
        CGRect circleFrame = CGRectInset(self.bounds, 3, 3);
        _circle = [[UIView alloc] initWithFrame:circleFrame];
        _circle.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.85];
        _circle.layer.cornerRadius = circleFrame.size.width / 2.0;
        _circle.layer.borderWidth = 2.0;
        _circle.layer.borderColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:0.8].CGColor;
        _circle.userInteractionEnabled = NO;
        [self addSubview:_circle];

        _label = [[UILabel alloc] initWithFrame:_circle.bounds];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        _label.textColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:1.0];
        _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        [self addSubview:_label];

        // Gestures
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap)];
        [self addGestureRecognizer:single];

        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap)];
        dbl.numberOfTapsRequired = 2;
        [self addGestureRecognizer:dbl];
        [single requireGestureRecognizerToFail:dbl];

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
    if (s->_isConfigMode) return;   // already waiting for a screen tap
    if (!s->_isTargetSet) {
        [s enterConfigMode];
    } else {
        [s toggle];
    }
}

- (void)handleDoubleTap {
    [MacroState.shared cycleInterval];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [MacroState.shared enterConfigMode];
    }
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

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        _dim.userInteractionEnabled = NO;
        [self addSubview:_dim];

        _hint = [[UILabel alloc] initWithFrame:CGRectMake(20, self.bounds.size.height/2 - 60,
                                                          self.bounds.size.width - 40, 120)];
        _hint.text = @"Tap the spot you want\nthe macro to repeat";
        _hint.textAlignment = NSTextAlignmentCenter;
        _hint.numberOfLines = 0;
        _hint.textColor = UIColor.whiteColor;
        _hint.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        _hint.userInteractionEnabled = NO;
        [self addSubview:_hint];

        _indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        _indicator.layer.cornerRadius = 18;
        _indicator.layer.borderWidth = 3;
        _indicator.layer.borderColor = [UIColor systemRedColor].CGColor;
        _indicator.backgroundColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.4];
        _indicator.hidden = YES;
        _indicator.userInteractionEnabled = NO;
        [self addSubview:_indicator];
    }
    return self;
}

- (void)showForConfig {
    _dim.hidden = NO;
    _hint.hidden = NO;
    _indicator.hidden = YES;
    self.hidden = NO;
    [self makeKeyAndVisible];
}

- (void)flashTarget:(CGPoint)point {
    _dim.hidden = YES;
    _hint.hidden = YES;
    _indicator.center = point;
    _indicator.hidden = NO;
    [self makeKeyAndVisible];
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
            for (UITouch *t in [event allTouches]) {
                if (t.phase != UITouchPhaseEnded) continue;
                if (!kw) break;
                CGPoint p = [t locationInView:kw];
                // Ignore taps landing on the floating button itself
                if (s->_button && CGRectContainsPoint(s->_button.frame, p)) continue;
                CGFloat dx = p.x - s->_target.x;
                CGFloat dy = p.y - s->_target.y;
                if (sqrtf(dx * dx + dy * dy) < kTargetStopRadius) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [s stop]; });
                    break;
                }
            }
        }
    } @catch (NSException *e) {
        // never crash on the swizzle path
    }
    [self macro_swizzledSendEvent:event];   // call original (swapped at +load)
}

+ (void)load {
    Method orig = class_getInstanceMethod(self, @selector(sendEvent:));
    Method swiz = class_getInstanceMethod(self, @selector(macro_swizzledSendEvent:));
    if (orig && swiz) {
        method_exchangeImplementations(orig, swiz);
    }
}

@end

// ============================================================
// BOOTSTRAP
// ============================================================

static FloatingButton      *gButton  = nil;
static ConfigCaptureWindow *gCapture = nil;

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
        [gButton makeKeyAndVisible];

        gCapture = [[ConfigCaptureWindow alloc] initWithFrame:screen];
        [MacroState.shared attachCapture:gCapture];

        NSLog(@"[Macro] button @ %@, capture ready", NSStringFromCGRect(bFrame));
    }];
}
