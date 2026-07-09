#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <string>
#include <sstream>
#include <algorithm>
#include <cstdint>

#include "MemoryScanner.hpp"
#include "SpeedHack.hpp"
#include "inlined_html.hpp"

// Forward declarations
@class CheatEngineMessageHandler;
@class FloatingWindow;
@class OverlayWindow;

// Global Windows
static FloatingWindow *gFloatingWindow = nil;
static OverlayWindow *gOverlayWindow = nil;

// Safe reading helper from MemoryScanner.cpp
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

// Custom WKScriptMessageHandler to handle messages from the WebUI
@interface CheatEngineMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@end

@implementation CheatEngineMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"cheatEngine"]) return;
    
    NSDictionary *dict = message.body;
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    
    NSString *action = dict[@"action"];
    
    if ([action isEqualToString:@"firstScan"]) {
        NSString *typeStr = dict[@"type"];
        NSString *valStr = dict[@"value"];
        
        ValueType type = ValueType::Type_i32;
        if ([typeStr isEqualToString:@"i64"]) type = ValueType::Type_i64;
        else if ([typeStr isEqualToString:@"float"]) type = ValueType::Type_Float;
        else if ([typeStr isEqualToString:@"double"]) type = ValueType::Type_Double;
        
        // Scan in a background queue to keep UI responsive
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
}

@end

// Floating Circular Button Window
@interface FloatingWindow : UIWindow
@property (nonatomic, strong) UIButton *btnFloat;
@end

@implementation FloatingWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = [UIColor clearColor];
        
        // Circular float button design
        self.btnFloat = [UIButton buttonWithType:UIButtonTypeCustom];
        self.btnFloat.frame = self.bounds;
        self.btnFloat.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.08 alpha:0.85];
        self.btnFloat.layer.cornerRadius = frame.size.width / 2.0;
        self.btnFloat.layer.borderWidth = 2.0;
        self.btnFloat.layer.borderColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:0.8].CGColor;
        self.btnFloat.clipsToBounds = YES;
        
        // Inner text logo
        [self.btnFloat setTitle:@"AG" forState:UIControlStateNormal];
        [self.btnFloat setTitleColor:[UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        self.btnFloat.titleLabel.font = [UIFont fontWithName:@"Outfit-ExtraBold" size:16] ?: [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        
        // Drag gesture
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.btnFloat addGestureRecognizer:pan];
        
        [self.btnFloat addTarget:self action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnFloat];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // Bounds check to stay on screen
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    newCenter.x = MAX(self.frame.size.width / 2, MIN(screenBounds.size.width - self.frame.size.width / 2, newCenter.x));
    newCenter.y = MAX(self.frame.size.height / 2, MIN(screenBounds.size.height - self.frame.size.height / 2, newCenter.y));
    
    self.center = newCenter;
    [sender setTranslation:CGPointZero inView:self];
}

- (void)btnTapped {
    // Hide float window and show main WebUI window
    self.hidden = YES;
    gOverlayWindow.hidden = NO;
}

@end

// Full/Centered Glassmorphic WKWebView Overlay Window
@interface OverlayWindow : UIWindow
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) CheatEngineMessageHandler *msgHandler;
@end

@implementation OverlayWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 99;
        self.backgroundColor = [UIColor clearColor];
        
        // Configuration
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        self.msgHandler = [[CheatEngineMessageHandler alloc] init];
        [config.userContentController addScriptMessageHandler:self.msgHandler name:@"cheatEngine"];
        
        // Responsive size setup: center on iPad, fullscreen with margin on iPhone
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
        
        // Disable bounce
        self.webView.scrollView.bounces = NO;
        
        self.msgHandler.webView = self.webView;
        
        // Load inlined HTML
        NSString *htmlStr = [NSString stringWithUTF8String:CHEAT_UI_HTML];
        [self.webView loadHTMLString:htmlStr baseURL:nil];
        
        [self addSubview:self.webView];
        
        // Handle background clicks to dismiss or toggle
        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)];
        bgTap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:bgTap];
    }
    return self;
}

- (void)bgTapped:(UITapGestureRecognizer *)sender {
    CGPoint point = [sender locationInView:self.webView];
    // If tap is outside the webview, hide overlay and restore float button
    if (!CGRectContainsPoint(self.webView.bounds, point)) {
        self.hidden = YES;
        gFloatingWindow.hidden = NO;
    }
}

@end

// Tweak Initialization Constructor
__attribute__((constructor))
static void initializeCheatEngine() {
    NSLog(@"[Antigravity] Dylib loaded into target process!");
    
    // Start SpeedHack hooks (Fishhook)
    SpeedHack::getInstance().start();
    
    // Start background thread to freeze locked values
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        MemoryScanner::getInstance().updateLockedValues();
    });
    dispatch_resume(timer);
    
    // Setup UI when target application did finish launching
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        
        // 1. Setup floating window (starts visible)
        gFloatingWindow = [[FloatingWindow alloc] initWithFrame:CGRectMake(20, screenBounds.size.height / 3.0, 50, 50)];
        gFloatingWindow.hidden = NO;
        
        // 2. Setup WebUI Overlay window (starts hidden)
        gOverlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
        gOverlayWindow.hidden = YES;
        
        NSLog(@"[Antigravity] Cheat Engine Overlay UI initialized.");
    }];
    
    // Observer for closing the UI from WebView message
    [[NSNotificationCenter defaultCenter] addObserverForName:@"CheatEngineCloseUI" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        gOverlayWindow.hidden = YES;
        gFloatingWindow.hidden = NO;
    }];
}
