#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import <objc/runtime.h>

// Load the real saver bundle, replacing only its OpenGL child with a counter.
// This models an extension host whose window stays logically visible while
// AppKit reports it as occluded, without needing a GPU or taking over the screen.
static NSUInteger frames;
static NSUInteger releases;

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

        for(NSNumber *preview in @[@YES, @NO]) {
            TestWindow *window = [[TestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 200)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.testVisible = YES;
            ScreenSaverView *saver = [[saverClass alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)
                isPreview:[preview boolValue]];
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
        }
        puts("PASS: preview and fullscreen visibility, stop, restart, hide, and detach");
    }
    return 0;
}
