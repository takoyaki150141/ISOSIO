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

@interface PanelWindow : UIWindow
@property (nonatomic, strong) MemorySearchView *searchView;
@property (nonatomic, strong) PointScanView *pointScanView;
- (void)showFeature:(NSInteger)featureID;
- (void)bgTapped:(UITapGestureRecognizer *)sender;
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
        // Visual style — match DLGMemUIView's expanded panel.
        self.backgroundColor = [UIColor blackColor];
        self.opaque = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = NO;
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowOffset  = CGSizeMake(0, 6);
        self.layer.shadowRadius  = 14.0;
        self.alpha = 0.95;

        // ---- Type selector (i32 / i64 / float / double) ----
        self.scType = [[UISegmentedControl alloc] initWithItems:@[@"i32", @"i64", @"f32", @"f64"]];
        self.scType.selectedSegmentIndex = 0;
        self.scType.frame = CGRectMake(20, 20, 370, 32);
        [self addSubview:self.scType];

        // ---- Value input + Search button ----
        self.tfValue = [[UITextField alloc] initWithFrame:CGRectMake(20, 60, 270, 36)];
        self.tfValue.borderStyle = UITextBorderStyleRoundedRect;
        self.tfValue.backgroundColor = [UIColor whiteColor];
        self.tfValue.textColor = [UIColor blackColor];
        self.tfValue.placeholder = @"値を入力 (例: 100)";
        self.tfValue.keyboardType = UIKeyboardTypeDefault;
        self.tfValue.spellCheckingType = UITextSpellCheckingTypeNo;
        self.tfValue.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.tfValue.autocorrectionType = UITextAutocorrectionTypeNo;
        [self addSubview:self.tfValue];

        self.btnSearch = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnSearch.frame = CGRectMake(298, 60, 92, 36);
        [self.btnSearch setTitle:@"検索" forState:UIControlStateNormal];
        [self.btnSearch addTarget:self action:@selector(onSearchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnSearch];

        // ---- Result label ----
        self.lblResult = [[UILabel alloc] initWithFrame:CGRectMake(20, 104, 370, 20)];
        self.lblResult.textColor = [UIColor whiteColor];
        self.lblResult.text = @"Found 0";
        [self addSubview:self.lblResult];

        // ---- Result table ----
        self.tvResult = [[UITableView alloc] initWithFrame:CGRectMake(20, 132, 370, 380) style:UITableViewStylePlain];
        self.tvResult.dataSource = self;
        self.tvResult.delegate = self;
        self.tvResult.backgroundColor = [UIColor clearColor];
        self.tvResult.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tvResult.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [self.tvResult registerClass:[UITableViewCell class] forCellReuseIdentifier:@"searchCell"];
        [self addSubview:self.tvResult];

        // ---- Action buttons (Reset / Refresh / Close) ----
        self.btnReset = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnReset.frame = CGRectMake(20, 520, 100, 36);
        [self.btnReset setTitle:@"リセット" forState:UIControlStateNormal];
        [self.btnReset addTarget:self action:@selector(onResetTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnReset];

        self.btnRefresh = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnRefresh.frame = CGRectMake(140, 520, 100, 36);
        [self.btnRefresh setTitle:@"更新" forState:UIControlStateNormal];
        [self.btnRefresh addTarget:self action:@selector(onRefreshTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnRefresh];

        self.btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnClose.frame = CGRectMake(260, 520, 100, 36);
        [self.btnClose setTitle:@"閉じる" forState:UIControlStateNormal];
        [self.btnClose addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnClose];
    }
    return self;
}

- (void)reload {
    auto& results = MemoryScanner::getInstance().getResults();
    self.lblResult.text = [NSString stringWithFormat:@"Found %lu", (unsigned long)results.size()];
    [self.tvResult reloadData];
}

- (void)onSearchTapped {
    NSString *valueStr = self.tfValue.text;
    if (valueStr.length == 0) return;
    int type = (int)self.scType.selectedSegmentIndex;
    MemoryScanner::getInstance().firstScan((ValueType)type, [valueStr UTF8String]);
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
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:13] ?: [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [UIColor colorWithRed:0.0 green:0.94 blue:1.0 alpha:1.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

    auto& results = MemoryScanner::getInstance().getResults();
    if ((NSUInteger)indexPath.row >= results.size()) return cell;
    auto& r = results[indexPath.row];
    NSString *addr = [NSString stringWithFormat:@"0x%llX", (unsigned long long)r.address];
    NSString *val  = readValueAsString(r.address, (int)r.type);
    cell.textLabel.text       = [NSString stringWithFormat:@"%@  =  %@", addr, val];
    cell.accessoryType        = UITableViewCellAccessoryDetailDisclosureButton;
    cell.accessoryView        = nil;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

#pragma mark - UITableViewDelegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Tap a row to pin it.
    auto& results = MemoryScanner::getInstance().getResults();
    if ((NSUInteger)indexPath.row >= results.size()) return;
    auto& r = results[indexPath.row];
    MemoryScanner::getInstance().pinAddress(r.address, (ValueType)r.type);
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
@implementation PointScanView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.opaque = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.masksToBounds = NO;
        self.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowOffset  = CGSizeMake(0, 6);
        self.layer.shadowRadius  = 14.0;
        self.alpha = 0.95;

        // Pinned count label
        self.lblPinned = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 310, 20)];
        self.lblPinned.textColor = [UIColor whiteColor];
        self.lblPinned.text = @"Pinned 0";
        [self addSubview:self.lblPinned];

        // Pinned table
        self.tvPinned = [[UITableView alloc] initWithFrame:CGRectMake(20, 48, 310, 380) style:UITableViewStylePlain];
        self.tvPinned.dataSource = self;
        self.tvPinned.delegate = self;
        self.tvPinned.backgroundColor = [UIColor clearColor];
        self.tvPinned.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tvPinned.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        [self.tvPinned registerClass:[UITableViewCell class] forCellReuseIdentifier:@"pinnedCell"];
        [self addSubview:self.tvPinned];

        // Close button
        self.btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
        self.btnClose.frame = CGRectMake(115, 440, 120, 36);
        [self.btnClose setTitle:@"閉じる" forState:UIControlStateNormal];
        [self.btnClose addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.btnClose];

        // 1Hz refresh timer: re-read every pinned address on a
        // background queue, then reload the table on main.
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
    auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
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
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:13] ?: [UIFont systemFontOfSize:13];

    auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
    if ((NSUInteger)indexPath.row >= pinned.size()) return cell;
    auto& p = pinned[indexPath.row];
    NSString *addr = [NSString stringWithFormat:@"0x%llX", (unsigned long long)p.address];
    NSString *val  = [NSString stringWithUTF8String:p.value.c_str()];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  =  %@", addr, val];
    return cell;
}

#pragma mark - UITableViewDelegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Tap a row to unpin.
    auto pinned = MemoryScanner::getInstance().copyPinnedAddresses();
    if ((NSUInteger)indexPath.row >= pinned.size()) return;
    auto& p = pinned[indexPath.row];
    MemoryScanner::getInstance().unpinAddress(p.address);
    [self reload];
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
@implementation PanelWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 99;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.opaque = NO;
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.userInteractionEnabled = YES;
        self.rootViewController = rootVC;

        // MemorySearchView — 410x560 centered
        CGRect searchFrame = CGRectMake((frame.size.width  - 410) / 2.0,
                                        (frame.size.height - 560) / 2.0,
                                        410, 560);
        self.searchView = [[MemorySearchView alloc] initWithFrame:searchFrame];
        self.searchView.host = self;
        self.searchView.hidden = YES;
        [rootVC.view addSubview:self.searchView];

        // PointScanView — 350x480 centered
        CGRect pointFrame  = CGRectMake((frame.size.width  - 350) / 2.0,
                                        (frame.size.height - 480) / 2.0,
                                        350, 480);
        self.pointScanView = [[PointScanView alloc] initWithFrame:pointFrame];
        self.pointScanView.host = self;
        self.pointScanView.hidden = YES;
        [rootVC.view addSubview:self.pointScanView];

        // Tap outside the visible panel to close.
        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)];
        bgTap.cancelsTouchesInView = NO;
        [rootVC.view addGestureRecognizer:bgTap];
    }
    return self;
}

- (void)showFeature:(NSInteger)featureID {
    self.searchView.hidden    = (featureID != 0);
    self.pointScanView.hidden = (featureID != 1);
    [self.searchView reload];
    [self.pointScanView reload];
    self.hidden = NO;
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
