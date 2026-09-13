#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <objc/runtime.h>
#include <math.h>

// Exercise the real renderer with a deterministic, fully populated texture.
// Only simulation stepping is disabled; viewport setup and drawing are real GL.
static NSOpenGLContext *testedContext;
static NSOpenGLView *testedView;
static IMP originalFlush;
static NSUInteger failures;
static NSUInteger capturedFrames;

static void check(BOOL condition, const char *message)
{
    if(!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

static void keepInitialTexture(id self, SEL selector) {}

static BOOL pixelIsLit(GLint x, GLint y)
{
    GLubyte pixel[4] = {0};
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    return pixel[0] || pixel[1] || pixel[2];
}

static void inspectFrame(id self, SEL selector)
{
    if(self == testedContext) {
        GLint viewport[4];
        glGetIntegerv(GL_VIEWPORT, viewport);
        NSRect backingBounds = [testedView convertRectToBacking:[testedView bounds]];
        GLint width = (GLint)ceil(NSWidth(backingBounds));
        GLint height = (GLint)ceil(NSHeight(backingBounds));
        check(width > 0 && height > 0, "positive backing dimensions");
        check(viewport[0] == 0 && viewport[1] == 0 && viewport[2] == width && viewport[3] == height,
            "viewport matches the full view backing size");
        glReadBuffer(GL_BACK);
        check(pixelIsLit(width / 2, height / 2), "center is rendered");
        check(pixelIsLit(width - 1, height / 2), "right edge is rendered");
        check(pixelIsLit(width / 2, height - 1), "top edge is rendered");
        check(pixelIsLit(width - 1, height - 1), "top-right corner is rendered");
        check(glGetError() == GL_NO_ERROR, "frame has no OpenGL error");
        capturedFrames++;
    }
    ((void (*)(id, SEL))originalFlush)(self, selector);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if(argc != 2) {
            fprintf(stderr, "Usage: %s /path/to/GPULife.saver\n", argv[0]);
            return 2;
        }
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        if(![bundle load]) return 2;
        Class viewClass = NSClassFromString(@"GPULifeView");
        method_setImplementation(class_getInstanceMethod(viewClass, NSSelectorFromString(@"step")),
            (IMP)keepInitialTexture);
        originalFlush = method_setImplementation(class_getInstanceMethod([NSOpenGLContext class],
            @selector(flushBuffer)), (IMP)inspectFrame);

        NSOpenGLPixelFormatAttribute attrs[] = {NSOpenGLPFADoubleBuffer, 0};
        NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
        NSOpenGLContext *otherContext = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];

        for(NSNumber *zoom in @[@2, @3]) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 101, 79)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            NSOpenGLView *view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 101, 79)];
            [view setValue:@NO forKey:@"usesTimer"];
            [view setValue:zoom forKey:@"zoom"];
            [view setValue:@100 forKey:@"initialFill"];
            [window setContentView:view];
            testedView = view;
            testedContext = [view openGLContext];
            NSUInteger framesBefore = capturedFrames;
            [window orderFront:nil];
            [view display];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            check(capturedFrames > framesBefore, "draw an initial frame");
            framesBefore = capturedFrames;
            [window setContentSize:NSMakeSize(103, 81)];
            [view display];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            check(NSEqualSizes([view bounds].size, NSMakeSize(103, 81)), "view adopts the resized dimensions");
            check(capturedFrames > framesBefore, "draw a resized frame");

            // Detachment can invoke reshape without making this view's context
            // current. It must not corrupt the context for another display.
            testedContext = nil;
            testedView = nil;
            [otherContext makeCurrentContext];
            glViewport(11, 12, 13, 14);
            [window setContentView:nil];
            check([NSOpenGLContext currentContext] == otherContext,
                "detachment preserves the other current context");
            GLint viewport[4];
            glGetIntegerv(GL_VIEWPORT, viewport);
            check(viewport[0] == 11 && viewport[1] == 12 && viewport[2] == 13 && viewport[3] == 14,
                "detachment preserves the other view's viewport");
            [window orderOut:nil];
            [view release];
            [window release];
        }

        [NSOpenGLContext clearCurrentContext];
        [otherContext release];
        [format release];
        if(failures) return 1;
        puts("PASS: edge coverage on initial draw and resize, and OpenGL context isolation on detach");
    }
    return 0;
}
