#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import <objc/runtime.h>

// Load the real saver bundle, replacing only its OpenGL child with a counter.
// This models an extension host whose window stays logically visible while
// AppKit reports it as occluded, without needing a GPU or taking over the screen.
static NSUInteger frames;
static NSUInteger releases;

@interface TestAnimationOwner : NSObject
@property BOOL terminated;
@property pid_t processIdentifier;
- (BOOL)isTerminated;
- (NSString *)bundleIdentifier;
@end
@implementation TestAnimationOwner
- (BOOL)isTerminated { return self.terminated; }
- (NSString *)bundleIdentifier { return @"test.gpulife.presenting-app"; }
@end

static TestAnimationOwner *selectedOwner;
static id animationOwnerApplication(id saver, SEL selector) { return selectedOwner; }
static BOOL tracksSettingsPreview;
static NSArray *ownerWindows;
static BOOL shouldTrackSettingsPreview(id saver, SEL selector) { return tracksSettingsPreview; }
static id animationOwnerWindows(id saver, SEL selector) { return ownerWindows; }

static NSDictionary *windowInfo(unsigned int number, BOOL visible)
{
    return @{(id)kCGWindowNumber: @(number), (id)kCGWindowIsOnscreen: @(visible),
        (id)kCGWindowAlpha: @1};
}

static void checkWindowsOnNextFrame(ScreenSaverView *saver, NSArray *windows)
{
    ownerWindows = windows;
    [saver setValue:@0 forKey:@"nextPreviewWindowCheck"];
    [saver animateOneFrame];
}

static void postTermination(TestAnimationOwner *application)
{
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
        userInfo:@{NSWorkspaceApplicationKey: application}];
}

@interface TestLifeView : NSView
@end
@implementation TestLifeView
- (void)display { frames++; }
- (void)releaseOpenGLResources { releases++; }
@end

@interface TestWindow : NSWindow
@property BOOL testVisible;
@property NSWindowOcclusionState testOcclusion;
@end
@implementation TestWindow
- (BOOL)isVisible { return self.testVisible; }
- (NSWindowOcclusionState)occlusionState { return self.testOcclusion; }
@end

static void createTestLifeView(id saver, SEL selector)
{
    TestLifeView *child = [[TestLifeView alloc] initWithFrame:[saver bounds]];
    object_setIvar(saver, class_getInstanceVariable([saver class], "lifeView"), child);
    [saver addSubview:child];
}

static void check(BOOL condition, const char *message)
{
    if(!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        check(argc == 2, "pass the path to GPULife.saver");
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        check([bundle load], "load saver bundle");
        Class saverClass = [bundle principalClass];
        Method reinit = class_getInstanceMethod(saverClass, NSSelectorFromString(@"reinitLifeView"));
        method_setImplementation(reinit, (IMP)createTestLifeView);
        Method ownerLookup = class_getInstanceMethod(saverClass, NSSelectorFromString(@"animationOwnerApplication"));
        check(ownerLookup != NULL, "presenting-application lifecycle support exists");
        method_setImplementation(ownerLookup, (IMP)animationOwnerApplication);
        method_setImplementation(class_getInstanceMethod(saverClass, NSSelectorFromString(@"shouldTrackSettingsPreview")),
            (IMP)shouldTrackSettingsPreview);
        method_setImplementation(class_getInstanceMethod(saverClass, NSSelectorFromString(@"animationOwnerWindows")),
            (IMP)animationOwnerWindows);

        for(NSNumber *preview in @[@YES, @NO]) {
            TestWindow *window = [[TestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.testVisible = YES;
            ScreenSaverView *saver = [[saverClass alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                isPreview:[preview boolValue]];
            TestAnimationOwner *firstOwner = [[TestAnimationOwner alloc] init];
            firstOwner.processIdentifier = 123;
            TestAnimationOwner *secondOwner = [[TestAnimationOwner alloc] init];
            secondOwner.processIdentifier = 456;
            selectedOwner = firstOwner;
            [window setContentView:saver];
            [saver startAnimation];
            [saver animateOneFrame];
            NSUInteger initialFrames = frames;
            check(initialFrames > 0 && [[saver subviews] count] == 1, "initial frame");

            // Let the old two-second grace period expire.
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.2]];
            [saver animateOneFrame];
            check(frames > initialFrames && [[saver subviews] count] == 1,
                "occluded host must keep rendering beyond two seconds");

            window.testOcclusion = NSWindowOcclusionStateVisible;
            [saver animateOneFrame];
            window.testOcclusion = 0;
            initialFrames = frames;
            [saver animateOneFrame];
            check(frames > initialFrames, "occlusion changes must not blank the saver");

            postTermination(secondOwner);
            check([saver isAnimating], "unrelated application exit must not stop rendering");
            NSUInteger ownerReleases = releases;
            firstOwner.terminated = YES;
            postTermination(firstOwner);
            check(![saver isAnimating] && [[saver subviews] count] == 0 && releases == ownerReleases + 1,
                "presenting application exit stops animation and releases the renderer");
            initialFrames = frames;
            [saver animateOneFrame];
            check(frames == initialFrames && [[saver subviews] count] == 0,
                "late host callback must not restart an abandoned view");

            selectedOwner = secondOwner;
            [saver startAnimation];
            [saver animateOneFrame];
            postTermination(firstOwner);
            check([saver isAnimating] && frames > initialFrames,
                "new presenting application can restart; stale exit must not stop it");
            secondOwner.terminated = YES;
            [saver animateOneFrame];
            check(![saver isAnimating] && [[saver subviews] count] == 0,
                "missed termination notification is detected on the next frame");

            selectedOwner = nil;
            [saver startAnimation];
            [saver animateOneFrame];
            check([saver isAnimating] && [[saver subviews] count] == 1,
                "a host with no identifiable presenting application keeps normal lifecycle behavior");

            NSUInteger initialReleases = releases;
            [saver stopAnimation];
            check(releases == initialReleases + 1 && [[saver subviews] count] == 0,
                "stop must release rendering resources");
            [saver animateOneFrame];
            check([[saver subviews] count] == 0, "late frame after stop must not recreate resources");
            [saver startAnimation];
            [saver animateOneFrame];
            check([[saver subviews] count] == 1, "restart must recreate rendering view");

            [saver setHidden:YES];
            [saver animateOneFrame];
            check([[saver subviews] count] == 0, "hidden saver must release rendering view");
            [saver setHidden:NO];
            [saver animateOneFrame];
            check([[saver subviews] count] == 1, "unhidden saver must resume rendering");
            window.testVisible = NO;
            [saver animateOneFrame];
            check([[saver subviews] count] == 0, "invisible window must release rendering view");
            window.testVisible = YES;
            [saver animateOneFrame];
            [saver removeFromSuperview];
            check([[saver subviews] count] == 0, "detaching must release rendering view");
            [saver stopAnimation];
            [saver release];
            [window release];
            [firstOwner release];
            [secondOwner release];
        }
        tracksSettingsPreview = YES;
        TestAnimationOwner *settings = [[TestAnimationOwner alloc] init];
        settings.processIdentifier = 789;
        selectedOwner = settings;
        TestWindow *window = [[TestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.testVisible = YES;
        // Tahoe's Settings preview also starts an instance with isPreview=NO.
        ScreenSaverView *saver = [[saverClass alloc] initWithFrame:NSMakeRect(0, 0, 320, 200) isPreview:NO];
        [window setContentView:saver];
        ownerWindows = @[windowInfo(10, YES)];
        [saver startAnimation];
        NSTimeInterval configuredInterval = [saver animationTimeInterval];
        [saver animateOneFrame];
        check([[saver valueForKey:@"previewWindowNumber"] unsignedIntValue] == 0,
            "wait for the dialog instead of binding to its parent during startup");
        checkWindowsOnNextFrame(saver, @[windowInfo(20, YES), windowInfo(10, YES)]);
        check([[saver valueForKey:@"previewWindowNumber"] unsignedIntValue] == 20,
            "bind to the dialog once it appears");

        checkWindowsOnNextFrame(saver, @[windowInfo(20, NO), windowInfo(10, NO)]);
        check([saver isAnimating] && [[saver subviews] count] == 0,
            "hiding Settings pauses rendering without retiring the preview");
        NSUInteger framesBefore = frames;
        checkWindowsOnNextFrame(saver, @[windowInfo(20, YES), windowInfo(10, YES)]);
        check(frames > framesBefore && [[saver subviews] count] == 1,
            "the same preview resumes after Settings returns");
        checkWindowsOnNextFrame(saver, nil);
        check([saver isAnimating] && [[saver subviews] count] == 1,
            "unavailable window metadata must not blank an active preview");
        // A delayed startup notification must not discard the window we
        // already know about just as the user clicks Done.
        [saver performSelector:NSSelectorFromString(@"settingsPreviewWasRequested:")
            withObject:[NSNotification notificationWithName:@"request" object:@"789"]];
        checkWindowsOnNextFrame(saver, @[windowInfo(20, NO), windowInfo(10, YES)]);
        check([saver isAnimating] && [[saver subviews] count] == 0 && !settings.terminated &&
            [saver animationTimeInterval] == 0.5,
            "Done stops rendering while Settings remains running");
        framesBefore = frames;
        [saver animateOneFrame];
        check(frames == framesBefore && [[saver subviews] count] == 0,
            "callbacks while the dialog is dismissed must not recreate the renderer");
        [saver performSelector:NSSelectorFromString(@"settingsPreviewWasRequested:")
            withObject:[NSNotification notificationWithName:@"request" object:@"456"]];
        check([[saver valueForKey:@"previewWindowNumber"] unsignedIntValue] == 20,
            "a request for another Settings process must not reset this preview");
        [saver performSelector:NSSelectorFromString(@"settingsPreviewWasRequested:")
            withObject:[NSNotification notificationWithName:@"request" object:@"789"]];
        checkWindowsOnNextFrame(saver, @[windowInfo(20, NO), windowInfo(10, YES)]);
        check(frames == framesBefore, "wait for the replacement dialog before resuming");
        checkWindowsOnNextFrame(saver, @[windowInfo(21, YES), windowInfo(20, NO), windowInfo(10, YES)]);
        check(frames > framesBefore && [[saver valueForKey:@"previewWindowNumber"] unsignedIntValue] == 21,
            "a request from the configuration host binds the reused renderer to the new dialog");
        checkWindowsOnNextFrame(saver, @[windowInfo(21, NO), windowInfo(10, YES)]);
        framesBefore = frames;
        checkWindowsOnNextFrame(saver, @[windowInfo(21, YES), windowInfo(10, YES)]);
        check(frames > framesBefore && [saver animationTimeInterval] == configuredInterval,
            "reopening resumes the existing view and frame rate without startAnimation");
        [saver stopAnimation];
        framesBefore = frames;
        [saver animateOneFrame];
        check(frames == framesBefore, "a stopped instance must not resume from late callbacks");
        [saver startAnimation];
        [saver animateOneFrame];
        check(frames > framesBefore, "explicit restart can use the same dialog window ID");

        TestWindow *newWindow = [[TestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        newWindow.testVisible = YES;
        ScreenSaverView *newSaver = [[saverClass alloc] initWithFrame:NSMakeRect(0, 0, 320, 200) isPreview:NO];
        [newWindow setContentView:newSaver];
        [newSaver startAnimation];
        [newSaver animateOneFrame];
        check(![saver isAnimating] && [[saver subviews] count] == 0 && [newSaver isAnimating],
            "a new Settings instance retires the old one even before the next window poll");
        checkWindowsOnNextFrame(newSaver, @[]);
        check(![newSaver isAnimating] && [[newSaver subviews] count] == 0,
            "destroying both dialog and parent stops the preview");
        [saver stopAnimation];
        [newSaver stopAnimation];
        [window setContentView:nil];
        [newWindow setContentView:nil];
        [saver release];
        [newSaver release];
        [window release];
        [newWindow release];
        [settings release];
        puts("PASS: lifecycle, owner exit, Settings dismissal, hide/resume, and preview replacement");
    }
    return 0;
}
