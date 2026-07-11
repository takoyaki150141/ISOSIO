#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <string>
#include <sstream>
#include <algorithm>
#include <cstdint>
#include <cstring>  // std::memcpy用

#include "MemoryScanner.hpp"
#include "SpeedHack.hpp"
#include "inlined_html.hpp"

// ============================================================
// HELPER FUNCTIONS
// ============================================================

template<typename T>
static bool readMemorySafe(uintptr_t address, T& outValue) {
    vm_size_t read_size = sizeof(T);
    vm_offset_t data;
    mach_msg_type_number_t data_size;
    kern_return_t kr = vm_read(mach_task_self(), address, read_size, &data, &data_size);
    if (kr == KERN_SUCCESS && data_size == read_size) {
        std::memcpy(&outValue, reinterpret_cast<void*>(data), read_size);
        vm_deallocate(mach_task_self(), data, data_size);
        return true;
    }
    return false;
}

// ============================================================
// ALL @interface DECLARATIONS
// ============================================================

@interface CheatEngineMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@end

@interface FloatingWindow : UIWindow
@property (nonatomic, strong) UIButton *btnFloat;
@property (nonatomic, strong) UIButton *btnMemorySearch;
@property (nonatomic, strong) UIButton *btnPointScan;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGRect collapsedFrame;
- (void)handlePan:(UIPanGestureRecognizer *)sender;
- (void)btnTapped;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)optionMemorySearchTapped;
- (void)optionPointScanTapped;
- (void)openFeature:(NSInteger)featureID;
@end

@interface OverlayWindow : UIWindow
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) CheatEngineMessageHandler *msgHandler;
- (void)bgTapped:(UITapGestureRecognizer *)sender;
- (void)applyCurrentFeature;
@end

// ============================================================
// GLOBAL VARIABLES
// ============================================================

static FloatingWindow *gFloatingWindow = nil;
static OverlayWindow *gOverlayWindow = nil;

// Current feature requested by the user from the floating menu.
// -1 = no feature chosen yet (just collapsed), 0 = memory search,
// 1 = point scan.  Read by OverlayWindow.applyCurrentFeature to
// tell the WKWebView which view to show via window.setFeature.
static NSInteger gCurrentFeature = -1;

// ============================================================
// IMPLEMENTATIONS
// ============================================================

@implementation CheatEngineMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"cheatEngine"]) return;
    
    NSDictionary *dict = message.body;
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    
    @try {
        NSString *action = dict[@"action"];
        
        if ([action isEqualToString:@"firstScan"]) {
            NSString *typeStr = dict[@"type"];
            NSString *valStr = dict[@"value"];
            
            ValueType type = ValueType::Type_i32;
            if ([typeStr isEqualToString:@"i64"]) type = ValueType::Type_i64;
            else if ([typeStr isEqualToString:@"float"]) type = ValueType::Type_Float;
            else if ([typeStr isEqualToString:@"double"]) type = ValueType::Type_Double;
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                MemoryScanner::getInstance().firstScan(type, [valStr UTF8String]);
                auto& results = MemoryScanner::getInstance().getResults();
                size_t totalCount = results.size();
                size_t displayCount = std::min(totalCount, (size_t)100);
                
                std::stringstream ss;
                ss << "[";
                for (size_t i = 0; i < displayCount; i++) {
                    ss << "{\"address\":" << results[i].address << ",\"value\":\"";
                    
                    std::string currentVal = "";
                    if (type == ValueType::Type_i32) {
                        int32_t val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_i64) {
                        int64_t val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_Float) {
                        float val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_Double) {
                        double val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    }
                    ss << currentVal << "\"}";
                    if (i < displayCount - 1) ss << ",";
                }
                ss << "]";
                
                std::string json = ss.str();
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *js = [NSString stringWithFormat:@"window.updateResults('%s'); window.onScanComplete(%lu);", json.c_str(), totalCount];
                    [self.webView evaluateJavaScript:js completionHandler:nil];
                });
            });
        }
        else if ([action isEqualToString:@"nextScan"]) {
            NSString *valStr = dict[@"value"];
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                MemoryScanner::getInstance().nextScan([valStr UTF8String]);
                auto& results = MemoryScanner::getInstance().getResults();
                size_t totalCount = results.size();
                size_t displayCount = std::min(totalCount, (size_t)100);
                
                std::stringstream ss;
                ss << "[";
                for (size_t i = 0; i < displayCount; i++) {
                    ss << "{\"address\":" << results[i].address << ",\"value\":\"";
                    
                    std::string currentVal = "";
                    ValueType type = results[i].type;
                    if (type == ValueType::Type_i32) {
                        int32_t val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_i64) {
                        int64_t val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_Float) {
                        float val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    } else if (type == ValueType::Type_Double) {
                        double val;
                        if (readMemorySafe(results[i].address, val)) currentVal = std::to_string(val);
                    }
                    ss << currentVal << "\"}";
                    if (i < displayCount - 1) ss << ",";
                }
                ss << "]";
                
                std::string json = ss.str();
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *js = [NSString stringWithFormat:@"window.updateResults('%s'); window.onScanComplete(%lu);", json.c_str(), totalCount];
                    [self.webView evaluateJavaScript:js completionHandler:nil];
                });
            });
        }
        else if ([action isEqualToString:@"modify"]) {
            NSNumber *addrNum = dict[@"address"];
            NSString *typeStr = dict[@"type"];
            NSString *valStr = dict[@"value"];
            uintptr_t address = [addrNum unsignedLongLongValue];
            
            ValueType type = ValueType::Type_i32;
            if ([typeStr isEqualToString:@"i64"]) type = ValueType::Type_i64;
            else if ([typeStr isEqualToString:@"float"]) type = ValueType::Type_Float;
            else if ([typeStr isEqualToString:@"double"]) type = ValueType::Type_Double;
            
            MemoryScanner::getInstance().modifyValue(address, type, [valStr UTF8String]);
        }
        else if ([action isEqualToString:@"lock"]) {
            NSNumber *addrNum = dict[@"address"];
            NSString *typeStr = dict[@"type"];
            NSString *valStr = dict[@"value"];
            uintptr_t address = [addrNum unsignedLongLongValue];
            
            ValueType type = ValueType::Type_i32;
            if ([typeStr isEqualToString:@"i64"]) type = ValueType::Type_i64;
            else if ([typeStr isEqualToString:@"float"]) type = ValueType::Type_Float;
            else if ([typeStr isEqualToString:@"double"]) type = ValueType::Type_Double;
            
            MemoryScanner::getInstance().lockValue(address, type, [valStr UTF8String]);
        }
        else if ([action isEqualToString:@"unlock"]) {
            NSNumber *addrNum = dict[@"address"];
            uintptr_t address = [addrNum unsignedLongLongValue];
            MemoryScanner::getInstance().unlockValue(address);
        }
        // -------- Point-scan / pin --------
        else if ([action isEqualToString:@"pin"]) {
            NSNumber *addrNum = dict[@"address"];
            NSString *typeStr = dict[@"type"];
            uintptr_t address = [addrNum unsignedLongLongValue];
            ValueType type = ValueType::Type_i32;
            if ([typeStr isEqualToString:@"i64"]) type = ValueType::Type_i64;
            else if ([typeStr isEqualToString:@"float"]) type = ValueType::Type_Float;
            else if ([typeStr isEqualToString:@"double"]) type = ValueType::Type_Double;
            MemoryScanner::getInstance().pinAddress(address, type);
            // Send the updated pinned list back to the UI.
            auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
            std::stringstream ss;
            ss << "[";
            for (size_t i = 0; i < pinned.size(); ++i) {
                if (i > 0) ss << ",";
                ss << "{\"address\":" << pinned[i].address
                   << ",\"type\":\"";
                switch (pinned[i].type) {
                    case ValueType::Type_i32: ss << "i32"; break;
                    case ValueType::Type_i64: ss << "i64"; break;
                    case ValueType::Type_Float: ss << "float"; break;
                    case ValueType::Type_Double: ss << "double"; break;
                }
                ss << "\",\"value\":\"" << pinned[i].value << "\"}";
            }
            ss << "]";
            std::string json = ss.str();
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *js = [NSString stringWithFormat:@"window.updatePinned('%s');", json.c_str()];
                [self.webView evaluateJavaScript:js completionHandler:nil];
            });
        }
        else if ([action isEqualToString:@"unpin"]) {
            NSNumber *addrNum = dict[@"address"];
            uintptr_t address = [addrNum unsignedLongLongValue];
            MemoryScanner::getInstance().unpinAddress(address);
        }
        else if ([action isEqualToString:@"refreshPinned"]) {
            // Re-read every pinned address from memory in-place
            // then push the new values to the UI.
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                MemoryScanner::getInstance().refreshPinned();
                auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
                std::stringstream ss;
                ss << "[";
                for (size_t i = 0; i < pinned.size(); ++i) {
                    if (i > 0) ss << ",";
                    ss << "{\"address\":" << pinned[i].address
                       << ",\"type\":\"";
                    switch (pinned[i].type) {
                        case ValueType::Type_i32: ss << "i32"; break;
                        case ValueType::Type_i64: ss << "i64"; break;
                        case ValueType::Type_Float: ss << "float"; break;
                        case ValueType::Type_Double: ss << "double"; break;
                    }
                    ss << "\",\"value\":\"" << pinned[i].value << "\"}";
                }
                ss << "]";
                std::string json = ss.str();
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *js = [NSString stringWithFormat:@"window.updatePinned('%s');", json.c_str()];
                    [self.webView evaluateJavaScript:js completionHandler:nil];
                });
            });
        }
        else if ([action isEqualToString:@"getPinned"]) {
            // Synchronous snapshot of the pin list, no re-read.
            auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
            std::stringstream ss;
            ss << "[";
            for (size_t i = 0; i < pinned.size(); ++i) {
                if (i > 0) ss << ",";
                ss << "{\"address\":" << pinned[i].address
                   << ",\"type\":\"";
                switch (pinned[i].type) {
                    case ValueType::Type_i32: ss << "i32"; break;
                    case ValueType::Type_i64: ss << "i64"; break;
                    case ValueType::Type_Float: ss << "float"; break;
                    case ValueType::Type_Double: ss << "double"; break;
                }
                ss << "\",\"value\":\"" << pinned[i].value << "\"}";
            }
            ss << "]";
            std::string json = ss.str();
            NSString *js = [NSString stringWithFormat:@"window.updatePinned('%s');", json.c_str()];
            [self.webView evaluateJavaScript:js completionHandler:nil];
        }
        else if ([action isEqualToString:@"setSpeed"]) {
            NSNumber *speedNum = dict[@"speed"];
            double speed = [speedNum doubleValue];
            SpeedHack::getInstance().setSpeed(speed);
        }
        else if ([action isEqualToString:@"clear"]) {
            MemoryScanner::getInstance().clear();
        }
        else if ([action isEqualToString:@"close"]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CheatEngineCloseUI" object:nil];
        }
    } @catch (NSException *exception) {
        NSLog(@"[Antigravity] Exception in message handling: %@", exception.reason);
    }
}

@end

// ============================================================
// FloatingWindow
// ============================================================
//
// Visual / interaction model ported from DLGMemor's DLGMemUIView
// (see DLGMemor/memui/views/DLGMemUIView.m).  DLGMemor is the
// reference for drawing, menu display, and tap; we re-implement
// the same patterns here without touching DLGMemor.
//
//   collapsed  → 50x50 black circle ("AG") with a cyan border.
//                cornerRadius = width/2, alpha = 0.5, no shadow.
//   expanded   → 200x180 black panel, cornerRadius = 18pt,
//                alpha = 0.8, drop shadow (0.45 / 0,6 / 14pt).
//                The "AG" chip grows to 60x60 at the top-left,
//                and two option buttons fade in below it.
//
// Tapping the AG chip toggles expand/collapse (user preference).
// Tapping an option opens the OverlayWindow with that feature.
// Tapping the empty area of the panel also collapses — same as
// DLGMemor's handleGesture: tap-anywhere-but-the-textfield-to-
// collapse pattern, generalised to "anywhere-but-a-button".
//
// All animations use UIViewAnimationOptionBeginFromCurrentState
// for smooth state-to-state transitions, 0.25s duration, and
// animate the panel's frame, cornerRadius, alpha, and shadow
// opacity in the same block (the same combo DLGMemor uses).
//
static const CGFloat kCollapsedSize         = 50.0;
static const CGFloat kExpandedCircleSize    = 60.0;
static const CGFloat kExpandedWidth         = 200.0;
static const CGFloat kExpandedHeight        = 180.0;
static const CGFloat kOptionHeight          = 44.0;
static const CGFloat kOptionVerticalGap     = 4.0;
static const CGFloat kCollapsedAlpha        = 0.5;
static const CGFloat kExpandedAlpha         = 0.8;
static const CGFloat kExpandedCornerRadius  = 18.0;
static const CGFloat kShadowOpacityExpanded = 0.45;
static const CGFloat kShadowOffsetY         = 6.0;
static const CGFloat kShadowRadius          = 14.0;
static const NSTimeInterval kAnimDuration   = 0.25;

@implementation FloatingWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 100;
        // backgroundColor flips to black when expanded (see
        // setExpanded:animated:).  Cleared back to transparent
        // on collapse so the host app shows through.
        self.backgroundColor = [UIColor clearColor];

        // iOS 15+ 対応: rootViewController を設定
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        self.rootViewController = rootVC;

        // ----- Layer style (DLGMemor pattern) -----
        // masksToBounds must be NO so the shadow can extend
        // outside the window's frame.  cornerRadius and
        // shadowOpacity are animated in setExpanded:animated:.
        self.layer.masksToBounds = NO;
        self.layer.cornerRadius = kCollapsedSize / 2.0;
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.0;             // no shadow when collapsed
        self.layer.shadowOffset  = CGSizeMake(0, kShadowOffsetY);
        self.layer.shadowRadius  = kShadowRadius;
        self.alpha = kCollapsedAlpha;               // 0.5 when collapsed

        // Remember the small circle's frame on screen so the
        // window can grow from this exact anchor when expanded.
        self.collapsedFrame = CGRectMake(frame.origin.x, frame.origin.y, kCollapsedSize, kCollapsedSize);
        self.expanded = NO;

        // ---- Main button (the circle) ----
        self.btnFloat = [UIButton buttonWithType:UIButtonTypeCustom];
        self.btnFloat.frame = CGRectMake(0, 0, kCollapsedSize, kCollapsedSize);
        self.btnFloat.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.85];
        self.btnFloat.layer.cornerRadius = kCollapsedSize / 2.0;
        self.btnFloat.layer.borderWidth = 2.0;
        self.btnFloat.layer.borderColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:0.8].CGColor;
        self.btnFloat.clipsToBounds = YES;

        [self.btnFloat setTitle:@"AG" forState:UIControlStateNormal];
        [self.btnFloat setTitleColor:[UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        self.btnFloat.titleLabel.font = [UIFont fontWithName:@"Outfit-ExtraBold" size:16] ?: [UIFont systemFontOfSize:16 weight:UIFontWeightBold];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.btnFloat addGestureRecognizer:pan];

        [self.btnFloat addTarget:self action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnFloat];

        // ---- Tap gesture: DLGMemor-style "tap empty area to
        //      collapse".  Always active; the handler decides
        //      what to do based on tap location + state.  We
        //      set cancelsTouchesInView = NO so the AG button
        //      and option buttons still receive their own
        //      touchUpInside events. ----
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        tap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:tap];

        // ---- Option buttons (DLGMemor system-button style:
        //      white text, no background, no border — just text
        //      on the panel's black background).  Hidden by
        //      default; shown + faded in by setExpanded:. ----
        CGFloat optionY1 = kExpandedCircleSize + 10;
        CGFloat optionY2 = optionY1 + kOptionHeight + kOptionVerticalGap;
        UIFont  *optionFont = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

        self.btnMemorySearch = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnMemorySearch.frame = CGRectMake(0, optionY1, kExpandedWidth, kOptionHeight);
        self.btnMemorySearch.alpha = 0.0;
        self.btnMemorySearch.hidden = YES;
        [self.btnMemorySearch setTitle:@"🔍  メモリ検索" forState:UIControlStateNormal];
        [self.btnMemorySearch setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.btnMemorySearch.titleLabel.font = optionFont;
        self.btnMemorySearch.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.btnMemorySearch.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        [self.btnMemorySearch addTarget:self action:@selector(optionMemorySearchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnMemorySearch];

        self.btnPointScan = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnPointScan.frame = CGRectMake(0, optionY2, kExpandedWidth, kOptionHeight);
        self.btnPointScan.alpha = 0.0;
        self.btnPointScan.hidden = YES;
        [self.btnPointScan setTitle:@"📌  ポイントスキャン" forState:UIControlStateNormal];
        [self.btnPointScan setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.btnPointScan.titleLabel.font = optionFont;
        self.btnPointScan.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.btnPointScan.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        [self.btnPointScan addTarget:self action:@selector(optionPointScanTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnPointScan];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    // Clamp to screen bounds (don't let the button go off-screen)
    // but DO NOT snap to the nearest edge.  The user dragged it
    // somewhere specific, so on release the button stays exactly
    // where they put it.
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    newCenter.x = MAX(self.frame.size.width / 2, MIN(screenBounds.size.width - self.frame.size.width / 2, newCenter.x));
    newCenter.y = MAX(self.frame.size.height / 2, MIN(screenBounds.size.height - self.frame.size.height / 2, newCenter.y));

    self.center = newCenter;
    [sender setTranslation:CGPointZero inView:self];

    // Keep the collapsed-anchor's origin synced with the window's
    // current top-left.  The circle is at (0, 0) inside the window
    // in both states, so window origin = circle origin.  This
    // makes the expand/collapse animation always grow from the
    // spot the user last dragged the button to.
    CGRect cur = self.collapsedFrame;
    cur.origin = self.frame.origin;
    self.collapsedFrame = cur;
}

// DLGMemor-style "tap empty area to collapse".  The recogniser
// fires for every tap on the panel; we let the AG button and the
// two option buttons handle their own taps (they sit on top of
// the panel) and only collapse when the user tapped the "blank"
// area around them.  Same logic as DLGMemUIView.handleGesture:,
// just adapted to a button-based menu instead of a text-field
// menu.
- (void)handleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) return;

    CGPoint pt = [sender locationInView:self];

    if (CGRectContainsPoint(self.btnFloat.frame, pt))       return;  // btnTapped
    if (CGRectContainsPoint(self.btnMemorySearch.frame, pt)) return;  // optionMemorySearchTapped
    if (CGRectContainsPoint(self.btnPointScan.frame, pt))   return;  // optionPointScanTapped

    if (self.expanded) {
        [self setExpanded:NO animated:YES];
    }
}

- (void)btnTapped {
    // Tap on the circle in either state toggles expand/collapse.
    if (self.expanded) {
        [self setExpanded:NO animated:YES];
    } else {
        [self setExpanded:YES animated:YES];
    }
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;

    CGFloat x = self.collapsedFrame.origin.x;
    CGFloat y = self.collapsedFrame.origin.y;

    if (expanded) {
        // Make the option buttons visible immediately so they
        // can be hit-tested while the spring animation runs.
        self.btnMemorySearch.hidden = NO;
        self.btnPointScan.hidden   = NO;

        CGRect targetFrame = CGRectMake(x, y, kExpandedWidth, kExpandedHeight);
        CGRect bigCircle   = CGRectMake(0, 0, kExpandedCircleSize, kExpandedCircleSize);

        void (^expandAnim)(void) = ^{
            self.frame = targetFrame;
            self.backgroundColor = [UIColor blackColor];
            self.alpha = kExpandedAlpha;
            self.layer.cornerRadius  = kExpandedCornerRadius;
            self.layer.shadowOpacity = kShadowOpacityExpanded;
            self.btnFloat.frame = bigCircle;
            self.btnFloat.layer.cornerRadius = kExpandedCircleSize / 2.0;
            self.btnMemorySearch.alpha = 1.0;
            self.btnPointScan.alpha   = 1.0;
        };
        void (^expandDone)(BOOL) = ^(BOOL finished) {
            // Final-state pin (DLGMemor does the same in its
            // expand completion block to avoid animation
            // rounding on the last frame).
            self.frame = targetFrame;
            self.backgroundColor = [UIColor blackColor];
            self.alpha = kExpandedAlpha;
            self.layer.cornerRadius  = kExpandedCornerRadius;
            self.layer.shadowOpacity = kShadowOpacityExpanded;
        };

        if (animated) {
            [UIView animateWithDuration:kAnimDuration
                                  delay:0.0f
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:expandAnim
                             completion:expandDone];
        } else {
            expandAnim();
            expandDone(YES);
        }
    } else {
        CGRect targetFrame = CGRectMake(x, y, kCollapsedSize, kCollapsedSize);
        CGRect smallCircle = CGRectMake(0, 0, kCollapsedSize, kCollapsedSize);

        void (^collapseAnim)(void) = ^{
            self.alpha = kCollapsedAlpha;
            self.layer.cornerRadius  = kCollapsedSize / 2.0;
            self.layer.shadowOpacity = 0.0;
            self.btnFloat.frame = smallCircle;
            self.btnFloat.layer.cornerRadius = kCollapsedSize / 2.0;
            self.btnMemorySearch.alpha = 0.0;
            self.btnPointScan.alpha   = 0.0;
        };
        void (^collapseDone)(BOOL) = ^(BOOL finished) {
            self.frame = targetFrame;
            self.backgroundColor = [UIColor clearColor];
            self.alpha = kCollapsedAlpha;
            self.layer.cornerRadius  = kCollapsedSize / 2.0;
            self.layer.shadowOpacity = 0.0;
            self.btnMemorySearch.hidden = YES;
            self.btnPointScan.hidden   = YES;
        };

        if (animated) {
            [UIView animateWithDuration:kAnimDuration
                                  delay:0.0f
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:collapseAnim
                             completion:collapseDone];
        } else {
            collapseAnim();
            collapseDone(YES);
        }
    }
}

- (void)optionMemorySearchTapped {
    [self openFeature:0];
}

- (void)optionPointScanTapped {
    [self openFeature:1];
}

- (void)openFeature:(NSInteger)featureID {
    gCurrentFeature = featureID;

    // Collapse the menu (animated) so the user gets visual
    // feedback that their tap registered, then hand off to the
    // overlay after the collapse animation finishes.
    [self setExpanded:NO animated:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAnimDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.hidden = YES;
        gOverlayWindow.hidden = NO;
        [gOverlayWindow applyCurrentFeature];
    });
}

@end

@implementation OverlayWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 99;
        self.backgroundColor = [UIColor clearColor];
        
        // iOS 15+ 対応: rootViewController を設定
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        self.rootViewController = rootVC;
        
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        self.msgHandler = [[CheatEngineMessageHandler alloc] init];
        [config.userContentController addScriptMessageHandler:self.msgHandler name:@"cheatEngine"];
        
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        CGFloat width = MIN(screenSize.width - 40, 760.0);
        CGFloat height = MIN(screenSize.height - 40, 480.0);
        CGRect webFrame = CGRectMake((screenSize.width - width) / 2.0, (screenSize.height - height) / 2.0, width, height);
        
        self.webView = [[WKWebView alloc] initWithFrame:webFrame configuration:config];
        self.webView.backgroundColor = [UIColor clearColor];
        self.webView.scrollView.backgroundColor = [UIColor clearColor];
        self.webView.opaque = NO;
        self.webView.layer.cornerRadius = 18.0;
        self.webView.clipsToBounds = YES;
        self.webView.scrollView.bounces = NO;
        
        self.msgHandler.webView = self.webView;
        
        NSString *htmlStr = [NSString stringWithUTF8String:CHEAT_UI_HTML];
        [self.webView loadHTMLString:htmlStr baseURL:nil];
        
        [self addSubview:self.webView];
        
        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)];
        bgTap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:bgTap];
    }
    return self;
}

- (void)bgTapped:(UITapGestureRecognizer *)sender {
    CGPoint point = [sender locationInView:self.webView];
    if (!CGRectContainsPoint(self.webView.bounds, point)) {
        self.hidden = YES;
        gFloatingWindow.hidden = NO;
        gCurrentFeature = -1;  // reset; next expand starts fresh
        // Re-expand the floating menu so the user can quickly
        // switch to a different feature without an extra tap.
        [gFloatingWindow setExpanded:YES animated:YES];
    }
}

// Pushes the current feature (gCurrentFeature) into the WKWebView
// by calling window.setFeature('search' | 'points').  The HTML
// side is expected to define window.setFeature to switch the
// visible view.  Safe to call when the JS function isn't defined
// yet — we just no-op in that case.
- (void)applyCurrentFeature {
    NSString *feature = nil;
    switch (gCurrentFeature) {
        case 0:  feature = @"search"; break;
        case 1:  feature = @"points"; break;
        default: feature = nil;       break;
    }
    if (feature == nil) return;
    NSString *js = [NSString stringWithFormat:
        @"try { if (window.setFeature) { window.setFeature('%@'); } } catch (e) {}", feature];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}

@end

// ============================================================
// TWEAK INITIALIZATION
// ============================================================

__attribute__((constructor))
static void initializeCheatEngine() {
    NSLog(@"[Antigravity] Dylib loaded into target process!");
    
    SpeedHack::getInstance().start();

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        MemoryScanner::getInstance().updateLockedValues();
    });
    dispatch_resume(timer);

    // Point-scan refresh timer: every 1.0s, re-read every pinned
    // address and push the new values to the WKWebView.  Only
    // touches the UI if the user has at least one pinned address,
    // so when there are no pins it's a no-op cost-wise.
    dispatch_source_t pinnedTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_timer(pinnedTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(pinnedTimer, ^{
        auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
        if (pinned.empty()) return;  // no pins, skip everything
        MemoryScanner::getInstance().refreshPinned();
        // Re-build the JSON after the refresh and push to the UI.
        std::stringstream ss;
        ss << "[";
        for (size_t i = 0; i < pinned.size(); ++i) {
            if (i > 0) ss << ",";
            ss << "{\"address\":" << pinned[i].address
               << ",\"type\":\"";
            switch (pinned[i].type) {
                case ValueType::Type_i32: ss << "i32"; break;
                case ValueType::Type_i64: ss << "i64"; break;
                case ValueType::Type_Float: ss << "float"; break;
                case ValueType::Type_Double: ss << "double"; break;
            }
            ss << "\",\"value\":\"" << pinned[i].value << "\"}";
        }
        ss << "]";
        std::string json = ss.str();
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *kw = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if (s.activationState == UISceneActivationStateForegroundActive &&
                        [s isKindOfClass:[UIWindowScene class]]) {
                        for (UIWindow *w in ((UIWindowScene *)s).windows) {
                            if ([w isKindOfClass:[NSClassFromString(@"OverlayWindow") class]]) { kw = w; break; }
                        }
                    }
                    if (kw != nil) break;
                }
            }
            WKWebView *web = [kw valueForKey:@"webView"];
            if (web != nil) {
                NSString *js = [NSString stringWithFormat:@"window.updatePinned('%s');", json.c_str()];
                [web evaluateJavaScript:js completionHandler:nil];
            }
        });
    });
    dispatch_resume(pinnedTimer);
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        
        gFloatingWindow = [[FloatingWindow alloc] initWithFrame:CGRectMake(20, screenBounds.size.height / 3.0, 50, 50)];
        gFloatingWindow.hidden = NO;
        
        gOverlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
        gOverlayWindow.hidden = YES;
        
        NSLog(@"[Antigravity] Cheat Engine Overlay UI initialized.");
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CheatEngineCloseUI" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        gOverlayWindow.hidden = YES;
        gFloatingWindow.hidden = NO;
    }];
}