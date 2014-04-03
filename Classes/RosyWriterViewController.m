/* ECE496: WENZHONG ZHANG
 * PREVIEW VIEW deals with the preview layer. The layer currently
 * shows the frame rate xx.xx FPS,
 * 1920 x 1080 frame size,
 * and the color format, in our case BGRA.
 * The color is organized this way because the speed of access is therefore optimized.
 */

#import <QuartzCore/QuartzCore.h>
#import "RosyWriterViewController.h"

// This inline code returns the degree (DEG) in radian (RAD).
static inline double radians (double degrees) { return degrees * (M_PI / 180); }

@implementation RosyWriterViewController
// On top of the video, there are two main functions to be rendered.
// 1. the entire view
// 2. the button to initiate record action
@synthesize previewView;
@synthesize recordButton;
@synthesize shouldShowStats;

- (void)updateLabels
{
	if (shouldShowStats) {
        // Get framerate from videoProcessor
        NSString *frameRateString = nil;
		NSString *dimensionsString = nil;
        if ([videoProcessor heartRate]) {
            frameRateString = [NSString stringWithFormat:@"%.2f FPS ", [videoProcessor videoFrameRate]];
            dimensionsString = [NSString stringWithFormat:@"%.0f BPM ", [videoProcessor heartRate]];
        }
        else {
            float result = [videoProcessor percentComplete] *100.0f;
            if (result >= 0.0f) {
                frameRateString = [NSString stringWithFormat:@"Detecting %.0f%%", result];
            } else {
                frameRateString = [NSString stringWithFormat:@"Warming up..."];
            }
            dimensionsString = [NSString stringWithFormat:@"Lightly press the back camera."];
        }
        
 		frameRateLabel.text = frameRateString;
 		dimensionsLabel.text = dimensionsString;
        if ([videoProcessor heartRate]) {
            [dimensionsLabel setBackgroundColor:[UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:0.25]];
        } else {
            [dimensionsLabel setBackgroundColor:[UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.25]];
        }
        if ([videoProcessor videoFrameRate] >= 20.0f) {
            [frameRateLabel setBackgroundColor:[UIColor colorWithRed:0.0 green:0.0 blue:1.0 alpha:0.25]];
        } else {
            [frameRateLabel setBackgroundColor:[UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.25]];
        }
 		
 	}
 	else {
 		frameRateLabel.text = @"";
 		[frameRateLabel setBackgroundColor:[UIColor clearColor]];
 		
 		dimensionsLabel.text = @"";
 		[dimensionsLabel setBackgroundColor:[UIColor clearColor]];
 	}
}

- (UILabel *)labelWithText:(NSString *)text yPosition:(CGFloat)yPosition
{
    // Bound the label, 200x40
	CGFloat labelWidth = 240.0;
	CGFloat labelHeight = 30.0;
	CGFloat xPosition = previewView.bounds.size.width - labelWidth - 10;
	CGRect labelFrame = CGRectMake(xPosition, yPosition, labelWidth, labelHeight);
	UILabel *label = [[UILabel alloc] initWithFrame:labelFrame];
    // 36 originally.
	[label setFont:[UIFont systemFontOfSize:18]];
	[label setLineBreakMode:NSLineBreakByWordWrapping];
	[label setTextAlignment:NSTextAlignmentRight];
	[label setTextColor:[UIColor whiteColor]];
	[label setBackgroundColor:[UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.25]];
	[[label layer] setCornerRadius: 4];
	[label setText:text];
	
	return [label autorelease];
}

- (void)applicationDidBecomeActive:(NSNotification*)notifcation
{
	// For performance reasons, we manually pause/resume the session when saving a recording.
	// If we try to resume the session in the background it will fail. Resume the session here as well to ensure we will succeed.
	[videoProcessor resumeCaptureSession];
}

// UIDeviceOrientationDidChangeNotification selector
- (void)deviceOrientationDidChange
{
	UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
	// Don't update the reference orientation when the device orientation is face up/down or unknown.
	if ( UIDeviceOrientationIsPortrait(orientation) || UIDeviceOrientationIsLandscape(orientation) )
		[videoProcessor setReferenceOrientation:orientation];
}

- (void)setupFilters
{
    _vignette = [[CIFilter filterWithName:@"CIVignette"] retain];
    [_vignette setValue:@1.0 forKey:@"inputIntensity"];
    [_vignette setValue:@16 forKey:@"inputRadius"];
}

- (void)viewDidLoad
{
	[super viewDidLoad];

    // Initialize the class responsible for managing AV capture session and asset writer
    videoProcessor = [[RosyWriterVideoProcessor alloc] init];
	videoProcessor.delegate = self;

	// Keep track of changes to the device orientation so we can update the video processor
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter addObserver:self selector:@selector(deviceOrientationDidChange) name:UIDeviceOrientationDidChangeNotification object:nil];
	[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    // Setup and start the capture session
    [videoProcessor setupAndStartCaptureSession];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:[UIApplication sharedApplication]];
    
    // Allocate OpenGL (PreviewView) view
	oglView = [[RosyWriterPreviewView alloc] initWithFrame:CGRectZero];

	oglView.transform = [videoProcessor transformFromCurrentVideoOrientationToOrientation:UIInterfaceOrientationPortrait];
    // Squeeze CIContext.
    // ciContext = [[CIContext init]]
    [previewView addSubview:oglView];
    
 	CGRect bounds = CGRectZero;
 	bounds.size = [self.previewView convertRect:self.previewView.bounds toView:oglView].size;
    
 	oglView.bounds = bounds;
    oglView.center = CGPointMake(previewView.bounds.size.width/2.0, previewView.bounds.size.height/2.0);
 	
 	// Set up labels, usse NO to turn this function off.
	shouldShowStats = YES;
	// Where to display these labels.
	frameRateLabel = [self labelWithText:@"" yPosition: (CGFloat) 30.0];
	[previewView addSubview:frameRateLabel];
	
	dimensionsLabel = [self labelWithText:@"" yPosition: (CGFloat) 75.0];
	[previewView addSubview:dimensionsLabel];
	
	//typeLabel = [self labelWithText:@"" yPosition: (CGFloat) 98.0];
	//[previewView addSubview:typeLabel];
}

- (void)cleanup
{
	[oglView release];
	oglView = nil;
    
    frameRateLabel = nil;
    dimensionsLabel = nil;
    //typeLabel = nil;
	
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
	[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

	[notificationCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:[UIApplication sharedApplication]];

    // Stop and tear down the capture session
	[videoProcessor stopAndTearDownCaptureSession];
	videoProcessor.delegate = nil;
    [videoProcessor release];
}

- (void)viewDidUnload 
{
	[super viewDidUnload];

	[self cleanup];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];

	timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(updateLabels) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated
{	
	[super viewDidDisappear:animated];

	[timer invalidate];
	timer = nil;
}

- (void)dealloc
{
	[self cleanup];

	[super dealloc];
}

- (IBAction)toggleRecording:(id)sender
{
	// Wait for the recording to start/stop before re-enabling the record button.
	[[self recordButton] setEnabled:NO];
	// Very simple two states.
	if ( [videoProcessor isRecording] ) {
		// The recordingWill/DidStop delegate methods will fire asynchronously in response to this call
		[videoProcessor stopRecording];
	}
	else {
		// The recordingWill/DidStart delegate methods will fire asynchronously in response to this call
        [videoProcessor startRecording];
	}
}

- (IBAction)switchLabel:(UITapGestureRecognizer *)sender {
	shouldShowStats = !shouldShowStats;
}

#pragma mark RosyWriterVideoProcessorDelegate

- (void)recordingWillStart
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[self recordButton] setEnabled:NO];	
		[[self recordButton] setTitle:@"Stop"];

		// Disable the idle timer while we are recording
		[UIApplication sharedApplication].idleTimerDisabled = YES;

		// Make sure we have time to finish saving the movie if the app is backgrounded during recording
		if ([[UIDevice currentDevice] isMultitaskingSupported])
			backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{}];
	});
}

- (void)recordingDidStart
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[self recordButton] setEnabled:YES];
	});
}

- (void)recordingWillStop
{
	dispatch_async(dispatch_get_main_queue(), ^{
		// Disable until saving to the camera roll is complete
		[[self recordButton] setTitle:@"Record"];
		[[self recordButton] setEnabled:NO];
		
		// Pause the capture session so that saving will be as fast as possible.
		// We resume the sesssion in recordingDidStop:
		[videoProcessor pauseCaptureSession];
	});
}

- (void)recordingDidStop
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[self recordButton] setEnabled:YES];
		
		[UIApplication sharedApplication].idleTimerDisabled = NO;

		[videoProcessor resumeCaptureSession];

		if ([[UIDevice currentDevice] isMultitaskingSupported]) {
			[[UIApplication sharedApplication] endBackgroundTask:backgroundRecordingID];
			backgroundRecordingID = UIBackgroundTaskInvalid;
		}
	});
}

- (void)pixelBufferReadyForDisplay:(CVPixelBufferRef)pixelBuffer
{
	// Don't make OpenGLES calls while in the background.
	if ( [UIApplication sharedApplication].applicationState != UIApplicationStateBackground )
		[oglView displayPixelBuffer:pixelBuffer];
}

@end
