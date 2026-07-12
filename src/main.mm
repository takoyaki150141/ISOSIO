#import <UIKit/UIKit.h>
#include <string>
#include <sstream>
#include <algorithm>
#include <cstdint>
#include <cstring>  // std::memcpy
#include <mach/mach.h>
#include <mach/vm_region.h>

#include "MemoryScanner.hpp"
#include "SpeedHack.hpp"

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

// Read a value at the given address based on the type and return
// it as a NSString.  Used by MemorySearchView to display the
// current value of each search result in the table cell.
//   type = 0 → i32, 1 → i64, 2 → float, 3 → double
// Returns "?" if the read fails (e.g. unmapped page).
static NSString* readValueAsString(uintptr_t address, int type) {
    kern_return_t kr;
    vm_offset_t data;
    mach_msg_type_number_t data_size;
    switch (type) {
        case 0: { // Type_i32
            int32_t v;
            data_size = 0;
            kr = vm_read(mach_task_self(), address, 4, &data, &data_size);
            if (kr != KERN_SUCCESS || data_size != 4) return @"?";
            memcpy(&v, (void*)data, 4);
            vm_deallocate(mach_task_self(), data, data_size);
            return [NSString stringWithFormat:@"%d", v];
        }
        case 1: { // Type_i64
            int64_t v;
            data_size = 0;
            kr = vm_read(mach_task_self(), address, 8, &data, &data_size);
            if (kr != KERN_SUCCESS || data_size != 8) return @"?";
            memcpy(&v, (void*)data, 8);
            vm_deallocate(mach_task_self(), data, data_size);
            return [NSString stringWithFormat:@"%lld", (long long)v];
        }
        case 2: { // Type_Float
            float v;
            data_size = 0;
            kr = vm_read(mach_task_self(), address, 4, &data, &data_size);
            if (kr != KERN_SUCCESS || data_size != 4) return @"?";
            memcpy(&v, (void*)data, 4);
            vm_deallocate(mach_task_self(), data, data_size);
            return [NSString stringWithFormat:@"%f", v];
        }
        case 3: { // Type_Double
            double v;
            data_size = 0;
            kr = vm_read(mach_task_self(), address, 8, &data, &data_size);
            if (kr != KERN_SUCCESS || data_size != 8) return @"?";
            memcpy(&v, (void*)data, 8);
            vm_deallocate(mach_task_self(), data, data_size);
            return [NSString stringWithFormat:@"%f", v];
        }
    }
    return @"?";
}

// ============================================================
// @interface DECLARATIONS
// ============================================================

@interface FloatingView : UIView
@property (nonatomic, strong) UIButton *btnFloat;
@property (nonatomic, strong) UIButton *btnMemorySearch;
@property (nonatomic, strong) UIButton *btnPointScan;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGRect collapsedFrame;
@property (nonatomic, weak) UIWindow *hostWindow;
- (void)handlePan:(UIPanGestureRecognizer *)sender;
- (void)handleTap:(UITapGestureRecognizer *)sender;
- (void)btnTapped;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)optionMemorySearchTapped;
- (void)optionPointScanTapped;
- (void)openFeature:(NSInteger)featureID;
@end

@interface FloatingWindow : UIWindow
@property (nonatomic, strong) FloatingView *floatingView;
@end

// Native UIKit replacement for the old WKWebView-based overlay.
// Same shape and behaviour as DLGMemor's DLGMemUIView, but
// split into two specialised panels: one for memory search,
// one for point scan.  No HTML, no JS bridge, no Python —
// just UITableView + UISegmentedControl + UITextField.
@interface EditView : UIView
@property (nonatomic, weak) UIWindow *host;
@property (nonatomic, assign) uintptr_t targetAddress;
@property (nonatomic, assign) int targetType;
@property (nonatomic, strong) UITextField *tfValue;
- (void)setupWithAddress:(uintptr_t)address type:(int)type;
@end

@interface MemorySearchView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) UIWindow *host;
@property (nonatomic, strong) UISegmentedControl *scType;
@property (nonatomic, strong) UITextField *tfValue;
@property (nonatomic, strong) UIButton *btnSearch;
@property (nonatomic, strong) UILabel *lblResult;
@property (nonatomic, strong) UITableView *tvResult;
@property (nonatomic, strong) UIButton *btnReset;
@property (nonatomic, strong) UIButton *btnRefresh;
@property (nonatomic, strong) UIButton *btnClose;
- (void)reload;
@end

@interface PointScanView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) UIWindow *host;
@property (nonatomic, strong) UILabel *lblPinned;
@property (nonatomic, strong) UITableView *tvPinned;
@property (nonatomic, strong) UIButton *btnClose;
@property (nonatomic, strong) dispatch_source_t refreshTimer;
- (void)reload;
@end

@interface FileEditorView : UIView
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSString *filePath;
@property (nonatomic, weak) id host;
- (void)loadFile:(NSString *)path;
@end

@interface FileManagerView : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) id host;
@property (nonatomic, strong) NSString *currentPath;
@property (nonatomic, strong) NSArray *files;
@property (nonatomic, strong) UITableView *tableView;
- (void)reload;
@end

@interface PanelWindow : UIWindow
@property (nonatomic, strong) MemorySearchView *searchView;
@property (nonatomic, strong) PointScanView *pointScanView;
@property (nonatomic, strong) FileManagerView *fileManagerView;
@property (nonatomic, strong) FileEditorView *fileEditorView;
@property (nonatomic, strong) EditView *editView;
@property (nonatomic, strong) UISegmentedControl *tabBar;
- (void)showFeature:(NSInteger)featureID;
- (void)showEditForAddress:(uintptr_t)address type:(int)type;
- (void)showFileEditor:(NSString *)path;
@end

// ============================================================
// GLOBAL VARIABLES
// ============================================================

static FloatingWindow *gFloatingWindow = nil;
static PanelWindow *gPanelWindow = nil;

// ============================================================
// FloatingView (the little AG chip + 2-option menu)
// ============================================================
//
// 2 states, like DLGMemUIView's rcCollapsedFrame/rcExpandedFrame:
//   collapsed  → 50x50 black circle, alpha 0.5, no shadow
//   expanded   → 200x180 black panel, cornerRadius 18, alpha 0.8,
//                drop shadow (0.45 / 0,6 / 14), 2 option buttons
//   transitions → 0.25s with UIViewAnimationOptionBeginFromCurrentState
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

@implementation FloatingView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // ----- Visual style (on the view, not the window) -----
        self.backgroundColor = [UIColor blackColor];
        self.opaque = YES;
        self.layer.masksToBounds = NO;
        self.layer.cornerRadius = kCollapsedSize / 2.0;
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.0;
        self.layer.shadowOffset  = CGSizeMake(0, kShadowOffsetY);
        self.layer.shadowRadius  = kShadowRadius;
        self.alpha = kCollapsedAlpha;

        self.collapsedFrame = CGRectMake(0, 0, kCollapsedSize, kCollapsedSize);
        self.expanded = NO;

        // ---- Main button (the AG circle) ----
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

        [self.btnFloat addTarget:self action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnFloat];

        // ---- Pan gesture: on the view, not the button. ----
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // ---- Tap gesture: DLGMemor-style "tap empty area to collapse". ----
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        tap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:tap];

        // ---- Option buttons (system-button style: white text, no background) ----
        CGFloat optionY1 = kExpandedCircleSize + 10;
        CGFloat optionY2 = optionY1 + kOptionHeight + kOptionVerticalGap;
        UIFont  *optionFont = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

        self.btnMemorySearch = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnMemorySearch.frame = CGRectMake(0, optionY1, kExpandedWidth, kOptionHeight);
        self.btnMemorySearch.alpha = 0.0;
        self.btnMemorySearch.hidden = YES;
        [self.btnMemorySearch setTitle:@"🔍  Search" forState:UIControlStateNormal];
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
        [self.btnPointScan setTitle:@"📌  Stored" forState:UIControlStateNormal];
        [self.btnPointScan setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.btnPointScan.titleLabel.font = optionFont;
        self.btnPointScan.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.btnPointScan.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        [self.btnPointScan addTarget:self action:@selector(optionPointScanTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnPointScan];

        UIButton *btnFile = [UIButton buttonWithType:UIButtonTypeSystem];
        btnFile.frame = CGRectMake(0, optionY2 + kOptionHeight + kOptionVerticalGap, kExpandedWidth, kOptionHeight);
        btnFile.alpha = 0.0;
        btnFile.tag = 100; // FileManager tag
        [btnFile setTitle:@"📂  Files" forState:UIControlStateNormal];
        [btnFile setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btnFile.titleLabel.font = optionFont;
        btnFile.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btnFile.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        [btnFile addTarget:self action:@selector(optionFileManagerTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnFile];
    }
    return self;
}

- (void)optionFileManagerTapped {
    [self openFeature:2];
}

- (void)handlePan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];

    NSLog(@"[FloatingView] handlePan state=%d t=(%.1f,%.1f) hostWin=%@ winFrame=%@",
          (int)sender.state, translation.x, translation.y,
          self.hostWindow, NSStringFromCGRect(self.hostWindow.frame));

    CGRect wf = self.hostWindow.frame;
    wf.origin.x += translation.x;
    wf.origin.y += translation.y;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    wf.origin.x = MAX(0, MIN(screenBounds.size.width  - wf.size.width,  wf.origin.x));
    wf.origin.y = MAX(0, MIN(screenBounds.size.height - wf.size.height, wf.origin.y));

    self.hostWindow.frame = wf;
    [sender setTranslation:CGPointZero inView:self];

    self.collapsedFrame = wf;

    NSLog(@"[FloatingView] handlePan DONE new winFrame=%@", NSStringFromCGRect(wf));
}

- (void)handleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) return;

    CGPoint pt = [sender locationInView:self];

    if (CGRectContainsPoint(self.btnFloat.frame, pt))        return;
    if (CGRectContainsPoint(self.btnMemorySearch.frame, pt)) return;
    if (CGRectContainsPoint(self.btnPointScan.frame, pt))   return;

    if (self.expanded) {
        [self setExpanded:NO animated:YES];
    }
}

- (void)btnTapped {
    NSLog(@"[FloatingView] btnTapped expanded=%d", self.expanded);
    if (self.expanded) {
        [self setExpanded:NO animated:YES];
    } else {
        [self setExpanded:YES animated:YES];
    }
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;

    CGRect targetViewFrame;
    if (expanded) {
        targetViewFrame = CGRectMake(0, 0, kExpandedWidth, kExpandedHeight);
    } else {
        targetViewFrame = CGRectMake(0, 0, kCollapsedSize, kCollapsedSize);
    }
    CGRect bigCircle   = CGRectMake(0, 0, kExpandedCircleSize, kExpandedCircleSize);
    CGRect smallCircle = CGRectMake(0, 0, kCollapsedSize, kCollapsedSize);

    if (expanded) {
        self.btnMemorySearch.hidden = NO;
        self.btnPointScan.hidden   = NO;

        CGRect newWf;
        newWf.size   = targetViewFrame.size;
        newWf.origin = self.collapsedFrame.origin;
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        newWf.origin.x = MAX(0, MIN(screenBounds.size.width  - newWf.size.width,  newWf.origin.x));
        newWf.origin.y = MAX(0, MIN(screenBounds.size.height - newWf.size.height, newWf.origin.y));
        self.collapsedFrame.origin = newWf.origin;

        void (^expandAnim)(void) = ^{
            self.frame = targetViewFrame;
            self.alpha = kExpandedAlpha;
            self.layer.cornerRadius  = kExpandedCornerRadius;
            self.layer.shadowOpacity = kShadowOpacityExpanded;
            self.btnFloat.frame = bigCircle;
            self.btnFloat.layer.cornerRadius = kExpandedCircleSize / 2.0;
            self.btnMemorySearch.alpha = 1.0;
            self.btnPointScan.alpha   = 1.0;
            
            UIButton *btnFile = (UIButton *)[self viewWithTag:100];
            if (btnFile) btnFile.alpha = 1.0;

            if (self.hostWindow != nil) {
                self.hostWindow.frame = newWf;
            }
        };
        void (^expandDone)(BOOL) = ^(BOOL finished) {
            self.frame = targetViewFrame;
            self.alpha = kExpandedAlpha;
            self.layer.cornerRadius  = kExpandedCornerRadius;
            self.layer.shadowOpacity = kShadowOpacityExpanded;
            if (self.hostWindow != nil) {
                self.hostWindow.frame = newWf;
            }
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
        CGRect newWf;
        newWf.size   = targetViewFrame.size;
        newWf.origin = self.collapsedFrame.origin;

        void (^collapseAnim)(void) = ^{
            self.alpha = kCollapsedAlpha;
            self.layer.cornerRadius  = kCollapsedSize / 2.0;
            self.layer.shadowOpacity = 0.0;
            self.btnFloat.frame = smallCircle;
            self.btnFloat.layer.cornerRadius = kCollapsedSize / 2.0;
            self.btnMemorySearch.alpha = 0.0;
            self.btnPointScan.alpha   = 0.0;
            
            UIButton *btnFile = (UIButton *)[self viewWithTag:100];
            if (btnFile) btnFile.alpha = 0.0;

            if (self.hostWindow != nil) {
                self.hostWindow.frame = newWf;
            }
        };
        void (^collapseDone)(BOOL) = ^(BOOL finished) {
            self.frame = targetViewFrame;
            self.alpha = kCollapsedAlpha;
            self.layer.cornerRadius  = kCollapsedSize / 2.0;
            self.layer.shadowOpacity = 0.0;
            self.btnMemorySearch.hidden = YES;
            self.btnPointScan.hidden   = YES;
            if (self.hostWindow != nil) {
                self.hostWindow.frame = newWf;
            }
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
    // Collapse the menu, then hand off to the panel.
    [self setExpanded:NO animated:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAnimDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.hostWindow != nil) self.hostWindow.hidden = YES;
        if (gPanelWindow != nil) {
            [gPanelWindow showFeature:featureID];
        }
    });
}

@end

@implementation FloatingWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.opaque = NO;
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.userInteractionEnabled = YES;
        self.rootViewController = rootVC;

        self.floatingView = [[FloatingView alloc] initWithFrame:
            CGRectMake(0, 0, frame.size.width, frame.size.height)];
        self.floatingView.hostWindow = self;
        [rootVC.view addSubview:self.floatingView];
    }
    return self;
}

@end

// ============================================================
// MemorySearchView
// ============================================================
//
// Native UIKit panel for memory search.  Same role as
// DLGMemUIView's search pane — UITextField for the value,
// UISegmentedControl for the type, UITableView for the
// results, action buttons along the bottom.
//
// No HTML, no JS bridge, no Python: results come straight from
// MemoryScanner::getInstance().getResults() and the value for
// each cell is read at display time via readValueAsString().
//
@implementation MemorySearchView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        CGFloat w = frame.size.width;
        CGFloat h = frame.size.height;

        self.scType = [[UISegmentedControl alloc] initWithItems:@[@"i32", @"i64", @"f32", @"f64"]];
        self.scType.selectedSegmentIndex = 0;
        self.scType.frame = CGRectMake(10, 10, w - 20, 32);
        self.scType.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        self.scType.selectedSegmentTintColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
        NSDictionary *attr = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
        [self.scType setTitleTextAttributes:attr forState:UIControlStateNormal];
        [self.scType setTitleTextAttributes:attr forState:UIControlStateSelected];
        [self addSubview:self.scType];

        UIView *searchBarBg = [[UIView alloc] initWithFrame:CGRectMake(10, 55, w - 20, 44)];
        searchBarBg.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        searchBarBg.layer.cornerRadius = 8.0;
        [self addSubview:searchBarBg];

        self.tfValue = [[UITextField alloc] initWithFrame:CGRectMake(20, 55, w - 120, 44)];
        self.tfValue.backgroundColor = [UIColor clearColor];
        self.tfValue.textColor = [UIColor whiteColor];
        self.tfValue.placeholder = @"Enter value...";
        self.tfValue.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        
        // Keyboard toolbar with Done button
        UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self.tfValue action:@selector(resignFirstResponder)];
        toolbar.items = @[flex, done];
        self.tfValue.inputAccessoryView = toolbar;
        
        [self addSubview:self.tfValue];

        self.btnSearch = [UIButton buttonWithType:UIButtonTypeCustom];
        self.btnSearch.frame = CGRectMake(w - 100, 55, 90, 44);
        [self.btnSearch setTitle:@"Search" forState:UIControlStateNormal];
        [self.btnSearch setTitleColor:[UIColor colorWithRed:0.0 green:0.6 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
        [self.btnSearch addTarget:self action:@selector(onSearchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnSearch];

        self.lblResult = [[UILabel alloc] initWithFrame:CGRectMake(10, 105, w - 20, 20)];
        self.lblResult.textColor = [UIColor grayColor];
        self.lblResult.font = [UIFont systemFontOfSize:14];
        self.lblResult.text = @"Found 0";
        [self addSubview:self.lblResult];

        self.tvResult = [[UITableView alloc] initWithFrame:CGRectMake(0, 130, w, h - 170) style:UITableViewStylePlain];
        self.tvResult.dataSource = self;
        self.tvResult.delegate = self;
        self.tvResult.backgroundColor = [UIColor clearColor];
        self.tvResult.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [self.tvResult registerClass:[UITableViewCell class] forCellReuseIdentifier:@"searchCell"];
        [self addSubview:self.tvResult];

        self.btnReset = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnReset.frame = CGRectMake(10, h - 35, 100, 30);
        [self.btnReset setTitle:@"Reset" forState:UIControlStateNormal];
        [self.btnReset setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0] forState:UIControlStateNormal];
        [self.btnReset addTarget:self action:@selector(onResetTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnReset];

        self.btnRefresh = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnRefresh.frame = CGRectMake(w - 110, h - 35, 100, 30);
        [self.btnRefresh setTitle:@"Refresh" forState:UIControlStateNormal];
        [self.btnRefresh addTarget:self action:@selector(onRefreshTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnRefresh];
    }
    return self;
}

- (void)reload {
    std::vector<ScanResult>& results = MemoryScanner::getInstance().getResults();
    self.lblResult.text = [NSString stringWithFormat:@"Found %lu", (unsigned long)results.size()];
    
    if (MemoryScanner::getInstance().getIsFirstScan()) {
        [self.btnSearch setTitle:@"First Scan" forState:UIControlStateNormal];
        self.scType.enabled = YES;
    } else {
        [self.btnSearch setTitle:@"Next Scan" forState:UIControlStateNormal];
        self.scType.enabled = NO; // Lock type during refinement
    }
    
    [self.tvResult reloadData];
}

- (void)onSearchTapped {
    NSString *valueStr = self.tfValue.text;
    if (valueStr.length == 0) return;
    
    [self.tfValue resignFirstResponder]; // Hide keyboard
    
    if (MemoryScanner::getInstance().getIsFirstScan()) {
        int type = (int)self.scType.selectedSegmentIndex;
        MemoryScanner::getInstance().firstScan((ValueType)type, [valueStr UTF8String]);
    } else {
        MemoryScanner::getInstance().nextScan([valueStr UTF8String]);
    }
    [self reload];
}

- (void)onResetTapped {
    MemoryScanner::getInstance().clear();
    [self reload];
}

- (void)onRefreshTapped {
    [self.tvResult reloadData];
}

- (void)onCloseTapped {
    if (self.host != nil) self.host.hidden = YES;
    if (gFloatingWindow != nil) gFloatingWindow.hidden = NO;
}

#pragma mark - UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MemoryScanner::getInstance().getResults().size();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"searchCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:14] ?: [UIFont systemFontOfSize:14];
    
    std::vector<ScanResult>& results = MemoryScanner::getInstance().getResults();
    if ((NSUInteger)indexPath.row >= results.size()) return cell;
    ScanResult& r = results[indexPath.row];
    
    NSString *addr = [NSString stringWithFormat:@"0x%llX", (unsigned long long)r.address];
    NSString *val  = readValueAsString(r.address, (int)r.type);
    
    // IGG style: Address on left, Value on right with a badge
    cell.textLabel.text = addr;
    
    UILabel *valLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
    valLabel.text = val;
    valLabel.textColor = [UIColor whiteColor];
    valLabel.textAlignment = NSTextAlignmentRight;
    valLabel.font = [UIFont boldSystemFontOfSize:14];
    
    UIView *accessoryView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 160, 30)];
    [accessoryView addSubview:valLabel];
    
    // Type badge like "i32" in blue
    UILabel *typeBadge = [[UILabel alloc] initWithFrame:CGRectMake(125, 5, 30, 20)];
    NSArray *types = @[@"i32", @"i64", @"f32", @"f64"];
    typeBadge.text = types[(int)r.type];
    typeBadge.textColor = [UIColor whiteColor];
    typeBadge.backgroundColor = [UIColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:1.0];
    typeBadge.font = [UIFont boldSystemFontOfSize:10];
    typeBadge.textAlignment = NSTextAlignmentCenter;
    typeBadge.layer.cornerRadius = 4.0;
    typeBadge.layer.masksToBounds = YES;
    [accessoryView addSubview:typeBadge];
    
    cell.accessoryView = accessoryView;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

#pragma mark - UITableViewDelegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    std::vector<ScanResult>& results = MemoryScanner::getInstance().getResults();
    if ((NSUInteger)indexPath.row >= results.size()) return;
    ScanResult& r = results[indexPath.row];
    if (gPanelWindow != nil) {
        [gPanelWindow showEditForAddress:r.address type:(int)r.type];
    }
}

@end

// ============================================================
// PointScanView
// ============================================================
//
// Native UIKit panel for the point scan.  Lists every pinned
// address with its current value, refreshed at 1Hz by a
// background dispatch_source_t.  Tap a row to unpin.
//
@implementation EditView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.95];
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = YES;

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 200, 30)];
        titleLabel.text = @"Edit Value";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [self addSubview:titleLabel];

        self.tfValue = [[UITextField alloc] initWithFrame:CGRectMake(20, 60, 260, 40)];
        self.tfValue.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        self.tfValue.textColor = [UIColor whiteColor];
        self.tfValue.layer.cornerRadius = 8.0;
        self.tfValue.textAlignment = NSTextAlignmentCenter;
        self.tfValue.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        
        UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 300, 44)];
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self.tfValue action:@selector(resignFirstResponder)];
        toolbar.items = @[flex, done];
        self.tfValue.inputAccessoryView = toolbar;
        
        [self addSubview:self.tfValue];

        UIButton *btnModify = [UIButton buttonWithType:UIButtonTypeSystem];
        btnModify.frame = CGRectMake(20, 110, 260, 44);
        btnModify.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
        btnModify.layer.cornerRadius = 8.0;
        [btnModify setTitle:@"Modify" forState:UIControlStateNormal];
        [btnModify setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btnModify addTarget:self action:@selector(onModifyTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnModify];

        UIButton *btnPin = [UIButton buttonWithType:UIButtonTypeSystem];
        btnPin.frame = CGRectMake(20, 160, 260, 44);
        btnPin.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
        btnPin.layer.cornerRadius = 8.0;
        [btnPin setTitle:@"Pin / Stored" forState:UIControlStateNormal];
        [btnPin setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btnPin addTarget:self action:@selector(onPinTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnPin];

        UIButton *btnMemory = [UIButton buttonWithType:UIButtonTypeSystem];
        btnMemory.frame = CGRectMake(20, 210, 260, 44);
        btnMemory.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
        btnMemory.layer.cornerRadius = 8.0;
        [btnMemory setTitle:@"Memory Viewer" forState:UIControlStateNormal];
        [btnMemory setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btnMemory addTarget:self action:@selector(onMemoryTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnMemory];

        UIButton *btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
        btnClose.frame = CGRectMake(20, 260, 260, 44);
        [btnClose setTitle:@"Close" forState:UIControlStateNormal];
        [btnClose addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnClose];
    }
    return self;
}

- (void)onMemoryTapped {
    // Memory viewer placeholder
    self.hidden = YES;
}

- (void)setupWithAddress:(uintptr_t)address type:(int)type {
    self.targetAddress = address;
    self.targetType = type;
    NSString *val = readValueAsString(address, type);
    self.tfValue.text = val;
}

- (void)onModifyTapped {
    NSString *val = self.tfValue.text;
    MemoryScanner::getInstance().modifyValue(self.targetAddress, (ValueType)self.targetType, [val UTF8String]);
    self.hidden = YES;
}

- (void)onPinTapped {
    MemoryScanner::getInstance().pinAddress(self.targetAddress, (ValueType)self.targetType);
    self.hidden = YES;
}

- (void)onCloseTapped {
    self.hidden = YES;
}

@end

@implementation PointScanView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        CGFloat w = frame.size.width;
        CGFloat h = frame.size.height;

        self.lblPinned = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, w - 20, 20)];
        self.lblPinned.textColor = [UIColor grayColor];
        self.lblPinned.font = [UIFont systemFontOfSize:14];
        self.lblPinned.text = @"Pinned 0";
        [self addSubview:self.lblPinned];

        self.tvPinned = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, w, h - 40) style:UITableViewStylePlain];
        self.tvPinned.dataSource = self;
        self.tvPinned.delegate = self;
        self.tvPinned.backgroundColor = [UIColor clearColor];
        self.tvPinned.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [self.tvPinned registerClass:[UITableViewCell class] forCellReuseIdentifier:@"pinnedCell"];
        [self addSubview:self.tvPinned];

        self.refreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        dispatch_source_set_timer(self.refreshTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.1 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.refreshTimer, ^{
            MemoryScanner::getInstance().refreshPinned();
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reload];
            });
        });
        dispatch_resume(self.refreshTimer);
    }
    return self;
}

- (void)dealloc {
    if (self.refreshTimer != nil) {
        dispatch_source_cancel(self.refreshTimer);
    }
}

- (void)reload {
    std::vector<PinnedAddress> pinned = MemoryScanner::getInstance().copyPinnedAddresses();
    self.lblPinned.text = [NSString stringWithFormat:@"Pinned %lu", (unsigned long)pinned.size()];
    [self.tvPinned reloadData];
}

- (void)onCloseTapped {
    if (self.host != nil) self.host.hidden = YES;
    if (gFloatingWindow != nil) gFloatingWindow.hidden = NO;
}

#pragma mark - UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MemoryScanner::getInstance().copyPinnedAddresses().size();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pinnedCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:14] ?: [UIFont systemFontOfSize:14];

    std::vector<PinnedAddress> pinned = MemoryScanner::getInstance().copyPinnedAddresses();
    if ((NSUInteger)indexPath.row >= pinned.size()) return cell;
    PinnedAddress& p = pinned[indexPath.row];
    
    NSString *addr = [NSString stringWithFormat:@"0x%llX", (unsigned long long)p.address];
    NSString *val  = [NSString stringWithUTF8String:p.value.c_str()];
    
    cell.textLabel.text = addr;
    
    UILabel *valLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
    valLabel.text = val;
    valLabel.textColor = [UIColor whiteColor];
    valLabel.textAlignment = NSTextAlignmentRight;
    valLabel.font = [UIFont boldSystemFontOfSize:14];
    
    cell.accessoryView = valLabel;
    return cell;
}

#pragma mark - UITableViewDelegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    std::vector<PinnedAddress> pinned = MemoryScanner::getInstance().copyPinnedAddresses();
    if ((NSUInteger)indexPath.row >= pinned.size()) return;
    PinnedAddress& p = pinned[indexPath.row];
    if (gPanelWindow != nil) {
        [gPanelWindow showEditForAddress:p.address type:(int)p.type];
    }
}

@end

// ============================================================
// PanelWindow
// ============================================================
//
// Transparent container that hosts MemorySearchView and
// PointScanView as subviews of the rootViewController's view.
// Only one view is visible at a time (toggled by showFeature:).
// A tap on the empty area (outside the visible panel) closes
// the window and re-shows the floating AG chip — same UX as
// the old WKWebView's bgTapped: behaviour.
//
@implementation FileEditorView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, frame.size.width - 150, 30)];
        titleLabel.text = @"Edit File";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [self addSubview:titleLabel];

        UIButton *btnSave = [UIButton buttonWithType:UIButtonTypeSystem];
        btnSave.frame = CGRectMake(frame.size.width - 70, 5, 60, 30);
        [btnSave setTitle:@"Save" forState:UIControlStateNormal];
        [btnSave addTarget:self action:@selector(onSaveTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnSave];

        UIButton *btnCancel = [UIButton buttonWithType:UIButtonTypeSystem];
        btnCancel.frame = CGRectMake(frame.size.width - 140, 5, 60, 30);
        [btnCancel setTitle:@"Cancel" forState:UIControlStateNormal];
        [btnCancel setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        [btnCancel addTarget:self action:@selector(onCancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnCancel];

        self.textView = [[UITextView alloc] initWithFrame:CGRectMake(0, 40, frame.size.width, frame.size.height - 40)];
        self.textView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        self.textView.textColor = [UIColor greenColor];
        self.textView.font = [UIFont fontWithName:@"Menlo-Regular" size:12] ?: [UIFont systemFontOfSize:12];
        
        UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 44)];
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self.textView action:@selector(resignFirstResponder)];
        toolbar.items = @[flex, done];
        self.textView.inputAccessoryView = toolbar;

        [self addSubview:self.textView];
    }
    return self;
}

- (void)loadFile:(NSString *)path {
    self.filePath = path;
    NSError *error;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content) {
        self.textView.text = content;
    } else {
        self.textView.text = @"[Error: Could not read file as UTF-8 text]";
    }
}

- (void)onSaveTapped {
    NSError *error;
    [self.textView.text writeToFile:self.filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    self.hidden = YES;
}

- (void)onCancelTapped {
    self.hidden = YES;
}
@end

@implementation FileManagerView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        self.currentPath = [paths firstObject];

        UIButton *btnBack = [UIButton buttonWithType:UIButtonTypeSystem];
        btnBack.frame = CGRectMake(10, 5, 80, 30);
        [btnBack setTitle:@"⬅ Back" forState:UIControlStateNormal];
        [btnBack addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btnBack];

        self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, frame.size.width, frame.size.height - 40) style:UITableViewStylePlain];
        self.tableView.dataSource = self;
        self.tableView.delegate = self;
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"fileCell"];
        [self addSubview:self.tableView];
        
        [self reload];
    }
    return self;
}

- (void)goBack {
    if ([self.currentPath isEqualToString:@"/"]) return;
    self.currentPath = [self.currentPath stringByDeletingLastPathComponent];
    if ([self.currentPath isEqualToString:@""]) self.currentPath = @"/";
    [self reload];
}

- (void)reload {
    NSError *error;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.currentPath error:&error];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSString *name in contents) {
        if (![name hasPrefix:@"."]) [filtered addObject:name];
    }
    self.files = [filtered sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"fileCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    
    NSString *name = self.files[indexPath.row];
    NSString *fullPath = [self.currentPath stringByAppendingPathComponent:name];
    
    BOOL isDir;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
    [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];
    
    if (isDir) {
        cell.textLabel.text = [NSString stringWithFormat:@"📁  %@", name];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        unsigned long long size = [attrs fileSize];
        NSString *sizeStr;
        if (size > 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.1f MB", size / (1024.0 * 1024.0)];
        else if (size > 1024) sizeStr = [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
        else sizeStr = [NSString stringWithFormat:@"%llu B", size];
        
        cell.textLabel.text = [NSString stringWithFormat:@"📄  %@ (%@)", name, sizeStr];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = self.files[indexPath.row];
    NSString *newPath = [self.currentPath stringByAppendingPathComponent:name];
    
    BOOL isDir;
    [[NSFileManager defaultManager] fileExistsAtPath:newPath isDirectory:&isDir];
    
    if (isDir) {
        self.currentPath = newPath;
        [self reload];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Edit (Text)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (self.host != nil) {
                [(PanelWindow *)self.host showFileEditor:newPath];
            }
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showRenameAlert:name path:newPath];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        
        if (self.host != nil) {
            [((PanelWindow *)self.host).rootViewController presentViewController:alert animated:YES completion:nil];
        }
    }
}

- (void)showRenameAlert:(NSString *)oldName path:(NSString *)oldPath {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = oldName;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = alert.textFields.firstObject.text;
        if (newName.length == 0) return;
        NSString *newPath = [self.currentPath stringByAppendingPathComponent:newName];
        [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:nil];
        [self reload];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    if (self.host != nil) {
        [((PanelWindow *)self.host).rootViewController presentViewController:alert animated:YES completion:nil];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSString *name = self.files[indexPath.row];
        NSString *fullPath = [self.currentPath stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
        [self reload];
    }
}
@end

@implementation PanelWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 99;
        self.backgroundColor = [UIColor blackColor];
        
        UIViewController *rootVC = [[UIViewController alloc] init];
        self.rootViewController = rootVC;
        
        self.tabBar = [[UISegmentedControl alloc] initWithItems:@[@"Search", @"Stored", @"Files"]];
        self.tabBar.frame = CGRectMake(10, 40, frame.size.width - 20, 40);
        self.tabBar.selectedSegmentIndex = 0;
        [self.tabBar addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
        [rootVC.view addSubview:self.tabBar];

        UIButton *btnClose = [UIButton buttonWithType:UIButtonTypeCustom];
        btnClose.frame = CGRectMake(frame.size.width - 50, 40, 40, 40);
        btnClose.backgroundColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0];
        btnClose.layer.cornerRadius = 20;
        [btnClose setTitle:@"✕" forState:UIControlStateNormal];
        [btnClose setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btnClose addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
        [rootVC.view addSubview:btnClose];

        CGRect contentFrame = CGRectMake(0, 90, frame.size.width, frame.size.height - 90);
        
        self.searchView = [[MemorySearchView alloc] initWithFrame:contentFrame];
        self.searchView.host = self;
        [rootVC.view addSubview:self.searchView];

        self.pointScanView = [[PointScanView alloc] initWithFrame:contentFrame];
        self.pointScanView.host = self;
        self.pointScanView.hidden = YES;
        [rootVC.view addSubview:self.pointScanView];

        self.fileManagerView = [[FileManagerView alloc] initWithFrame:contentFrame];
        self.fileManagerView.host = self;
        self.fileManagerView.hidden = YES;
        [rootVC.view addSubview:self.fileManagerView];

        self.fileEditorView = [[FileEditorView alloc] initWithFrame:contentFrame];
        self.fileEditorView.host = self;
        self.fileEditorView.hidden = YES;
        [rootVC.view addSubview:self.fileEditorView];

        self.editView = [[EditView alloc] initWithFrame:CGRectMake((frame.size.width - 300)/2, (frame.size.height - 300)/2, 300, 300)];
        self.editView.host = self;
        self.editView.hidden = YES;
        [rootVC.view addSubview:self.editView];
    }
    return self;
}

- (void)showFileEditor:(NSString *)path {
    [self.fileEditorView loadFile:path];
    self.fileEditorView.hidden = NO;
    [self.rootViewController.view bringSubviewToFront:self.fileEditorView];
}

- (void)tabChanged:(UISegmentedControl *)sender {
    [self showFeature:sender.selectedSegmentIndex];
}

- (void)showFeature:(NSInteger)featureID {
    self.searchView.hidden = (featureID != 0);
    self.pointScanView.hidden = (featureID != 1);
    self.fileManagerView.hidden = (featureID != 2);
    self.tabBar.selectedSegmentIndex = featureID;
    self.hidden = NO;
}

- (void)showEditForAddress:(uintptr_t)address type:(int)type {
    [self.editView setupWithAddress:address type:type];
    self.editView.hidden = NO;
    [self.rootViewController.view bringSubviewToFront:self.editView];
}

- (void)closePanel {
    self.hidden = YES;
    if (gFloatingWindow != nil) {
        gFloatingWindow.hidden = NO;
    }
}

- (void)bgTapped:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) return;
    UIView *root = self.rootViewController.view;
    CGPoint pt = [sender locationInView:root];
    // If the tap landed on the visible panel, let the panel's
    // own controls handle it.  Otherwise, close the panel and
    // re-show the floating chip (also re-expand its menu so
    // the user can quickly switch features).
    if (!self.searchView.hidden    && CGRectContainsPoint(self.searchView.frame,    pt)) return;
    if (!self.pointScanView.hidden && CGRectContainsPoint(self.pointScanView.frame, pt)) return;

    self.hidden = YES;
    if (gFloatingWindow != nil) {
        gFloatingWindow.hidden = NO;
        [gFloatingWindow.floatingView setExpanded:YES animated:YES];
    }
}

@end

// ============================================================
// TWEAK INITIALIZATION
// ============================================================

__attribute__((constructor))
static void initializeCheatEngine() {
    NSLog(@"[Antigravity] Dylib loaded into target process!");

    SpeedHack::getInstance().start();

    // Locked-value timer: re-write any locked addresses every
    // 50ms so a frozen game value stays at the user's target.
    dispatch_source_t lockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    dispatch_source_set_timer(lockTimer,
                              DISPATCH_TIME_NOW,
                              50 * NSEC_PER_MSEC,
                              5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(lockTimer, ^{
        MemoryScanner::getInstance().updateLockedValues();
    });
    dispatch_resume(lockTimer);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {

        CGRect screenBounds = [UIScreen mainScreen].bounds;

        // Floating AG chip + 2-option menu.
        gFloatingWindow = [[FloatingWindow alloc] initWithFrame:CGRectMake(20,
                                                                            screenBounds.size.height / 3.0,
                                                                            50, 50)];
        gFloatingWindow.hidden = NO;

        // Native UIKit panel window (memory search + point scan).
        gPanelWindow = [[PanelWindow alloc] initWithFrame:screenBounds];
        gPanelWindow.hidden = YES;

        NSLog(@"[Antigravity] UI initialized (native UIKit, no HTML/JS bridge).");
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:@"CheatEngineCloseUI"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        if (gPanelWindow != nil) gPanelWindow.hidden = YES;
        if (gFloatingWindow != nil) gFloatingWindow.hidden = NO;
    }];
}
