//
//  GPULifeSaverView.m
//  GPULife
//
//  Created by Michael Ash on 5/13/05.
//  Copyright 2005 __MyCompanyName__. All rights reserved.
//

#import "GPULifeSaverView.h"

#import "GPULifeView.h"


@interface GPULifeView (GPULifeSaverViewPrivate)
- (void)releaseOpenGLResources;
@end


@implementation GPULifeSaverView

static NSString * const kLimitFPSDefaultsName = @"LimitFPS";
static NSString * const kLimitFPSValueDefaultsName = @"LimitFPSValue";
static NSString * const kDisplayFPSDefaultsName = @"DisplayFPS";
static NSString * const kZoomDefaultsName = @"Zoom";
static NSString * const kInitialFillDefaultsName = @"InitialFill";
static NSString * const kGenerationDefaultsName = @"GenerationRate";
static NSString * const kCornerColorsDefaultsName = @"CornerColors";
static NSString * const kSettingsPreviewStarted = @"GPULifeSettingsPreviewStarted";
static NSString * const kSettingsPreviewRequested = @"com.mikeash.GPULife.settingsPreviewRequested";

+ (void)initialize
{
	[[ScreenSaverDefaults defaultsForModuleWithName:
		[[NSBundle bundleForClass:[self class]] bundleIdentifier]] registerDefaults:
		[NSDictionary dictionaryWithObjectsAndKeys:
			[NSNumber numberWithBool:YES], kLimitFPSDefaultsName,
			[NSNumber numberWithDouble:30.0], kLimitFPSValueDefaultsName,
			[NSNumber numberWithBool:NO], kDisplayFPSDefaultsName,
			[NSNumber numberWithInt:2], kZoomDefaultsName,
			[NSNumber numberWithInt:12], kInitialFillDefaultsName,
			[NSNumber numberWithInt:1], kGenerationDefaultsName,
			[NSArchiver archivedDataWithRootObject:[NSArray arrayWithObjects:
				[NSColor redColor], [NSColor blueColor], [NSColor greenColor], [NSColor whiteColor], nil]],
			kCornerColorsDefaultsName,
			nil]];
}

- (GPULifeColor3)structForNSColor:(NSColor *)c
{
	GPULifeColor3 ret;
	c = [c colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
	[c getRed:&ret.r green:&ret.g blue:&ret.b alpha:NULL];
	float max = MAX(MAX(ret.r, ret.g), ret.b);

	// make sure the color isn't too black so the shader can still find it
	if(max < 0.101)
	{
		if(max == 0.0)
			ret.r = ret.g = ret.b = 0.101;
		else
		{
			ret.r *= 0.101 / max;
			ret.g *= 0.101 / max;
			ret.b *= 0.101 / max;
		}
	}
	return ret;
}

- (void)reinitLifeView
{
	[self releaseLifeView];

	lifeView = [[GPULifeView alloc] initWithFrame:[self bounds]];
	[lifeView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[lifeView setUsesTimer:NO];

	ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:
		[[NSBundle bundleForClass:[self class]] bundleIdentifier]];
	[lifeView setShowsFPS:[defaults boolForKey:kDisplayFPSDefaultsName]];
	[lifeView setZoom:[defaults integerForKey:kZoomDefaultsName]];
	[lifeView setGenerationRate:[defaults integerForKey:kGenerationDefaultsName]];
	[lifeView setInitialFill:[defaults integerForKey:kInitialFillDefaultsName]];

	GPULifeColor3 colorsArray[4];
	NSArray *colors = [NSUnarchiver unarchiveObjectWithData:[defaults objectForKey:kCornerColorsDefaultsName]];
	int i;
	for(i = 0; i < 4; i++)
		colorsArray[i] = [self structForNSColor:[colors objectAtIndex:i]];
	[lifeView setCornerColors:colorsArray];

	[self addSubview:lifeView];
}

- (void)releaseLifeView
{
	[lifeView removeFromSuperview];
	[lifeView releaseOpenGLResources];
	[lifeView release];
	lifeView = nil;
}

- (BOOL)shouldRenderLifeView
{
	NSWindow *window = [self window];
	if(!window || ![window isVisible] || [self isHiddenOrHasHiddenAncestor])
		return NO;

	// The legacy host can present our surface from another process while its
	// own window reports itself occluded. Occlusion is not a reliable signal
	// to stop drawing; use the saver lifecycle and explicit hiding instead.
	return YES;
}

- (void)dealloc
{
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
	[animationOwner release];
	[self releaseLifeView];
	[colorWells release];
	[configureSheet release];
	[super dealloc];
}

- (NSRunningApplication *)animationOwnerApplication
{
	// The legacy host can keep its windows and animation callbacks alive after
	// the application presenting them exits. Only apply this workaround there.
	NSString *hostIdentifier = [[NSBundle mainBundle] bundleIdentifier];
	if(![hostIdentifier hasPrefix:@"com.apple.ScreenSaver.Engine.legacyScreenSaver"])
		return nil;

	for(NSString *identifier in @[@"com.apple.ScreenSaver.Engine", @"com.apple.systempreferences"])
		for(NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier])
			if(![application isTerminated])
				return application;

	return nil;
}

- (void)stopForTerminatedAnimationOwner
{
	NSLog(@"GPULife: stopping animation after presenting application (pid %d) exited",
		[animationOwner processIdentifier]);
	[self stopAnimation];
}

- (void)animationOwnerDidTerminate:(NSNotification *)notification
{
	if(![NSThread isMainThread])
	{
		[self performSelectorOnMainThread:_cmd withObject:notification waitUntilDone:NO];
		return;
	}

	NSRunningApplication *application = [[notification userInfo] objectForKey:NSWorkspaceApplicationKey];
	if(animationOwner && application && [application processIdentifier] == [animationOwner processIdentifier])
		[self stopForTerminatedAnimationOwner];
}

- (BOOL)shouldTrackSettingsPreview
{
	// Tahoe presents the preview in a separate sheet window, but leaves the
	// legacy host's full-size rendering window visible after dismissing it.
	return [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion >= 26 &&
		[[animationOwner bundleIdentifier] isEqualToString:@"com.apple.systempreferences"];
}

- (id)initWithFrame:(NSRect)frame isPreview:(BOOL)preview
{
	self = [super initWithFrame:frame isPreview:preview];
	if(self)
	{
		NSRunningApplication *owner = [self animationOwnerApplication];
		if([[owner bundleIdentifier] isEqualToString:@"com.apple.systempreferences"])
			// Settings creates a new configuration view in a second host when
			// reopening its dialog, but reuses the old rendering view. Notify
			// that renderer to bind to the new dialog's window ID.
			[[NSDistributedNotificationCenter defaultCenter] postNotificationName:kSettingsPreviewRequested
				object:[NSString stringWithFormat:@"%d", [owner processIdentifier]]
				userInfo:nil deliverImmediately:YES];
	}
	return self;
}

- (void)settingsPreviewWasRequested:(NSNotification *)notification
{
	if(![NSThread isMainThread])
	{
		[self performSelectorOnMainThread:_cmd withObject:notification waitUntilDone:NO];
		return;
	}
	if(!tracksSettingsPreview || ![[notification object] isEqualToString:
		[NSString stringWithFormat:@"%d", [animationOwner processIdentifier]]])
		return;
	previewRebindRequested = YES;
	nextPreviewWindowCheck = 0;
}

- (NSArray *)animationOwnerWindows
{
	// Only window IDs, owning PIDs, levels and visibility are needed. Window
	// titles and screen capture permission are deliberately not required.
	NSArray *windows = [(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionAll,
		kCGNullWindowID) autorelease];
	if(!windows)
		return nil;
	NSMutableArray *ownerWindows = [NSMutableArray array];
	for(NSDictionary *window in windows)
		if([[window objectForKey:(id)kCGWindowOwnerPID] intValue] == [animationOwner processIdentifier] &&
			[[window objectForKey:(id)kCGWindowLayer] intValue] == 0)
			[ownerWindows addObject:window];
	return ownerWindows;
}

- (BOOL)settingsPreviewCanRender
{
	if(!tracksSettingsPreview)
		return YES;
	NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
	if(now < nextPreviewWindowCheck)
		return settingsPreviewVisible;
	nextPreviewWindowCheck = now + 0.5;
	NSArray *windows = [self animationOwnerWindows];
	if(!windows)
		return settingsPreviewVisible;

	if(!previewWindowNumber || previewRebindRequested)
	{
		// WindowServer lists windows front to back. Wait for both the sheet
		// and its parent, rather than accidentally binding to the parent while
		// the sheet is still being created.
		NSMutableArray *visibleWindows = [NSMutableArray array];
		for(NSDictionary *window in windows)
			if([[window objectForKey:(id)kCGWindowIsOnscreen] boolValue] &&
				[[window objectForKey:(id)kCGWindowAlpha] doubleValue] > 0.0)
				[visibleWindows addObject:window];
		if([visibleWindows count] >= 2)
		{
			previewWindowNumber = [[[visibleWindows objectAtIndex:0] objectForKey:(id)kCGWindowNumber] unsignedIntValue];
			previewParentWindowNumber = [[[visibleWindows objectAtIndex:1] objectForKey:(id)kCGWindowNumber] unsignedIntValue];
			previewRebindRequested = NO;
		}
		else if(!previewWindowNumber)
			return settingsPreviewVisible;
	}

	NSDictionary *preview = nil;
	NSDictionary *parent = nil;
	for(NSDictionary *window in windows)
	{
		CGWindowID number = [[window objectForKey:(id)kCGWindowNumber] unsignedIntValue];
		if(number == previewWindowNumber) preview = window;
		if(number == previewParentWindowNumber) parent = window;
	}
	if(!preview && !parent)
	{
		NSLog(@"GPULife: stopping closed Settings preview");
		[self stopAnimation];
		return NO;
	}
	BOOL visible = [[preview objectForKey:(id)kCGWindowIsOnscreen] boolValue];
	if(visible != settingsPreviewVisible)
	{
		settingsPreviewVisible = visible;
		[self setAnimationTimeInterval:visible ? activeAnimationTimeInterval : 0.5];
		NSLog(@"GPULife: %@ Settings preview rendering", visible ? @"resuming" : @"pausing");
	}
	// Done hides the sheet but Settings may reuse this exact view without
	// calling startAnimation again. Keep only a slow visibility check so it
	// can resume, with no renderer allocated while the dialog is hidden.
	// Occlusion does not remove a window from WindowServer's onscreen list.
	return settingsPreviewVisible;
}

- (void)settingsPreviewDidStart:(NSNotification *)notification
{
	if([notification object] != self &&
		[[[notification userInfo] objectForKey:@"ownerPID"] intValue] == [animationOwner processIdentifier])
		[self stopAnimation];
}

- (void)startAnimation
{
	NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
	[workspaceCenter removeObserver:self name:NSWorkspaceDidTerminateApplicationNotification object:nil];
	[animationOwner release];
	animationOwner = [[self animationOwnerApplication] retain];
	if(animationOwner)
		[workspaceCenter addObserver:self selector:@selector(animationOwnerDidTerminate:)
			name:NSWorkspaceDidTerminateApplicationNotification object:nil];
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center removeObserver:self name:kSettingsPreviewStarted object:nil];
	NSDistributedNotificationCenter *distributedCenter = [NSDistributedNotificationCenter defaultCenter];
	[distributedCenter removeObserver:self name:kSettingsPreviewRequested object:nil];
	tracksSettingsPreview = [self shouldTrackSettingsPreview];
	settingsPreviewVisible = YES;
	previewRebindRequested = NO;
	previewWindowNumber = previewParentWindowNumber = 0;
	nextPreviewWindowCheck = 0;
	if(tracksSettingsPreview)
	{
		[distributedCenter addObserver:self selector:@selector(settingsPreviewWasRequested:)
			name:kSettingsPreviewRequested object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
		// A reopened sheet can reuse its window ID. Retire the previous
		// instance before it can resume alongside this new preview.
		[center postNotificationName:kSettingsPreviewStarted object:self
			userInfo:@{@"ownerPID": @([animationOwner processIdentifier])}];
		[center addObserver:self selector:@selector(settingsPreviewDidStart:)
			name:kSettingsPreviewStarted object:nil];
	}

	if(!lifeView && [self shouldRenderLifeView])
		[self reinitLifeView];

	ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:
		[[NSBundle bundleForClass:[self class]] bundleIdentifier]];
	if([defaults boolForKey:kLimitFPSDefaultsName])
		[self setAnimationTimeInterval:1.0 / [[defaults objectForKey:kLimitFPSValueDefaultsName] doubleValue]];
	else
		[self setAnimationTimeInterval:0.0];
	activeAnimationTimeInterval = [self animationTimeInterval];
    [super startAnimation];
	[self settingsPreviewCanRender];
}

- (void)stopAnimation
{
	[super stopAnimation];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:kSettingsPreviewStarted object:nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:kSettingsPreviewRequested object:nil];
	tracksSettingsPreview = NO;
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
		name:NSWorkspaceDidTerminateApplicationNotification object:nil];
	[animationOwner release];
	animationOwner = nil;
	[self releaseLifeView];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
	if(!newWindow)
		[self releaseLifeView];

	[super viewWillMoveToWindow:newWindow];
}

- (void)viewDidHide
{
	[self releaseLifeView];
	[super viewDidHide];
}

- (void)drawRect:(NSRect)rect
{
}

- (void)animateOneFrame
{
	// Also check the retained application object in case a termination event
	// was missed while the host was suspended. Do not restart abandoned views.
	if(animationOwner && [animationOwner isTerminated])
	{
		[self stopForTerminatedAnimationOwner];
		return;
	}

	if(![self isAnimating] || ![self shouldRenderLifeView])
	{
		[self releaseLifeView];
		return;
	}
	if(![self settingsPreviewCanRender])
	{
		[self releaseLifeView];
		return;
	}

	if(!lifeView)
		[self reinitLifeView];
	else if(!NSEqualRects([lifeView frame], [self bounds]))
		[lifeView setFrame:[self bounds]];

	[lifeView display];
}

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (void)fillDictionary:(NSMutableDictionary*)dict withColorWellsInView:(NSView *)superview
{
	NSEnumerator *enumerator = [[superview subviews] objectEnumerator];
	NSView *view;
	while((view = [enumerator nextObject]))
	{
		if([view isKindOfClass:[NSColorWell class]])
			[dict setObject:view forKey:[NSNumber numberWithInt:[view tag]]];
		else
			[self fillDictionary:dict withColorWellsInView:view];
	}
}

- (NSWindow*)configureSheet
{
	if(!configureSheet)
	{
		[NSBundle loadNibNamed:@"ScreenSaver" owner:self];

		NSMutableDictionary *tempDict = [[NSMutableDictionary alloc] init];
		[self fillDictionary:tempDict withColorWellsInView:colorWellBox];
		[colorWells release];
		colorWells = [tempDict copy];
		[tempDict release];
	}

	ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:[[NSBundle bundleForClass:[self class]] bundleIdentifier]];

	[limitFPSCheckbox setState:[defaults boolForKey:kLimitFPSDefaultsName] ? NSOnState : NSOffState];
	double fpsLimit = [[defaults objectForKey:kLimitFPSValueDefaultsName] doubleValue];;
	[fpsSlider setDoubleValue:fpsLimit];
	[fpsField setDoubleValue:fpsLimit];
	[displayFPSCheckbox setState:[defaults boolForKey:kDisplayFPSDefaultsName] ? NSOnState : NSOffState];
	int zoom = [defaults integerForKey:kZoomDefaultsName];
	[zoomSlider setIntValue:zoom];
	[zoomField setIntValue:zoom];
	[initialFillSlider setIntValue:[defaults integerForKey:kInitialFillDefaultsName]];
	[generationField setIntValue:[defaults integerForKey:kGenerationDefaultsName]];

	NSArray *colors = [NSUnarchiver unarchiveObjectWithData:[defaults objectForKey:kCornerColorsDefaultsName]];
	int i;
	for(i = 0; i < 4; i++)
		[[colorWells objectForKey:[NSNumber numberWithInt:i]] setColor:[colors objectAtIndex:i]];

	[self limitFPSChecked:limitFPSCheckbox];

    return configureSheet;
}

- (void)limitFPSChecked:sender
{
	[fpsSlider setEnabled:[sender state] == NSOnState];
	[fpsField setEnabled:[sender state] == NSOnState];
}

- (void)limitFPSSlider:sender
{
	double fpsLimit = [fpsSlider doubleValue];
	[fpsField setDoubleValue:fpsLimit];
}

- (void)limitFPSField:sender
{
	double fpsLimit = [fpsField doubleValue];
	[fpsSlider setDoubleValue:fpsLimit];
}

- (void)ok:sender
{
	ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:[[NSBundle bundleForClass:[self class]] bundleIdentifier]];

	[defaults setBool:[limitFPSCheckbox state] == NSOnState forKey:kLimitFPSDefaultsName];
	[defaults setObject:[NSNumber numberWithDouble:[fpsField doubleValue]] forKey:kLimitFPSValueDefaultsName];
	[defaults setBool:[displayFPSCheckbox state] == NSOnState forKey:kDisplayFPSDefaultsName];
	[defaults setInteger:[zoomField intValue] forKey:kZoomDefaultsName];
	[defaults setInteger:[initialFillSlider intValue] forKey:kInitialFillDefaultsName];
	[defaults setInteger:[generationField intValue] forKey:kGenerationDefaultsName];

	NSMutableArray *array = [NSMutableArray array];
	int i;
	for(i = 0; i < 4; i++)
		[array addObject:[[colorWells objectForKey:[NSNumber numberWithInt:i]] color]];
	[defaults setObject:[NSArchiver archivedDataWithRootObject:array] forKey:kCornerColorsDefaultsName];

	[defaults synchronize];

	[NSApp endSheet:configureSheet];

	if(lifeView)
		[self reinitLifeView];

	[[NSColorPanel sharedColorPanel] orderOut:nil];
}

- (void)cancel:sender
{
	[NSApp endSheet:configureSheet];

	[[NSColorPanel sharedColorPanel] orderOut:nil];
}

@end
