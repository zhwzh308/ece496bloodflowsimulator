#import <AVFoundation/AVFoundation.h>
#import "RosyWriterPreviewView.h"
#import "RosyWriterVideoProcessor.h"

// this means view controller owns an instance of video processor.
@interface RosyWriterViewController : UIViewController <RosyWriterVideoProcessorDelegate>
{
    RosyWriterVideoProcessor *videoProcessor;
    
	UIView *previewView;
    RosyWriterPreviewView *oglView;
    UIBarButtonItem *recordButton;
    // First line noticible label showing the frame rate
	UILabel *frameRateLabel;
    // Second line label showing frame size W x H
	UILabel *dimensionsLabel;
    // Third line showing the pixel data type.
	UILabel *typeLabel;
    // CI stuff
    CIContext *ciContext;
    CIFilter *_vignette;

    NSTimer *timer;
	
	UIBackgroundTaskIdentifier backgroundRecordingID;
}

@property (nonatomic, retain) IBOutlet UIView *previewView;
@property (nonatomic, retain) IBOutlet UIBarButtonItem *recordButton;
@property (nonatomic, strong) id statsObserveToken;
@property (readwrite) BOOL shouldShowStats;

- (IBAction)toggleRecording:(id)sender;
- (IBAction)switchLabel:(UITapGestureRecognizer *)sender;

@end
