#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CMBufferQueue.h>
#define MAX_NUM_FRAMES 250
@protocol RosyWriterVideoProcessorDelegate;

@interface RosyWriterVideoProcessor : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate> 
{  
    id <RosyWriterVideoProcessorDelegate> delegate;
	
    // From interface POV, they are atomic; within the class, they are readwrite.
    // Thus videoFrameRate videoDimensions videoType are redeclared in m file.
	NSMutableArray *previousSecondTimestamps;
	Float64 videoFrameRate;
	CMVideoDimensions videoDimensions;
	CMVideoCodecType videoType;

    // Capture session parameters
	AVCaptureSession *captureSession;
    AVCaptureVideoPreviewLayer *previewLayer;
	AVCaptureConnection *audioConnection;
	AVCaptureConnection *videoConnection;
    AVCaptureDevice *frontCamera;
    AVCaptureDevice *backCamera;
    // To send to preview.
	CMBufferQueueRef previewBufferQueue;
	
    // Asset writer parameters
	NSURL *movieURL;
	AVAssetWriter *assetWriter;
	AVAssetWriterInput *assetWriterAudioIn;
	AVAssetWriterInput *assetWriterVideoIn;
	dispatch_queue_t movieWritingQueue;
    
	AVCaptureVideoOrientation referenceOrientation;
	AVCaptureVideoOrientation videoOrientation;
    CGFloat previousFrameAverageGreen0;
    CGFloat previousFrameAverageGreen1;
    
    /* Added by team */
    int frame_number;
    CGFloat currentTime;
    int *differences;
    int sizeOfDifferences;
    int sizeOfCollectedData;
    BOOL isUsingFrontCamera;
	double arrayOfRedChannelAverage[MAX_NUM_FRAMES];
	double arrayOfGreenChannelAverage[MAX_NUM_FRAMES];
    BOOL tmp[540][960];
    BOOL lesstemp[135][240];
    /* CIImage
    CIContext *ciContext;*/
    
	// Only accessed on movie writing queue
    BOOL readyToRecordAudio; 
    BOOL readyToRecordVideo;
	BOOL recordingWillBeStarted;
	BOOL recordingWillBeStopped;

	BOOL recording;
}

@property (readwrite, assign) id <RosyWriterVideoProcessorDelegate> delegate;

@property (readonly) Float64 videoFrameRate;
@property (nonatomic, readonly) CGFloat heartRate;
@property (readonly) CMVideoDimensions videoDimensions;
@property (readonly) CMVideoCodecType videoType;

@property (readwrite) AVCaptureVideoOrientation referenceOrientation;

//- (void) setReferenceOrientation:(AVCaptureVideoOrientation)referenceOrientation;
- (CGAffineTransform)transformFromCurrentVideoOrientationToOrientation:(AVCaptureVideoOrientation)orientation;

- (void) showError:(NSError*)error;

- (void) setupAndStartCaptureSession;
- (void) stopAndTearDownCaptureSession;

- (void) startRecording;
- (void) stopRecording;

- (void) pauseCaptureSession; // Pausing while a recording is in progress will cause the recording to be stopped and saved.
- (void) resumeCaptureSession;
int detect_peak(
				const double*   data, /* the data */
				int             data_count, /* row count of data */
				//       int*            emi_peaks, /* emission peaks will be put here */
				int*            num_emi_peaks, /* number of emission peaks found */
				int             max_emi_peaks, /* maximum number of emission peaks */
				//       int*            absop_peaks, /* absorption peaks will be put here */
				int*            num_absop_peaks, /* number of absorption peaks found */
				int             max_absop_peaks, /* maximum number of absorption peaks
												  */
				double          delta,//, /* delta used for distinguishing peaks */
				//       int             emi_first /* should we search emission peak first of
				//                                  absorption peak first? */
				int*         peaks_index,
				double*         peaks_values
				);

@property(readonly, getter=isRecording) BOOL recording;

@end

@protocol RosyWriterVideoProcessorDelegate <NSObject>

@required
- (void)pixelBufferReadyForDisplay:(CVPixelBufferRef)pixelBuffer; // In view controller
- (void)recordingWillStart;
- (void)recordingDidStart;
- (void)recordingWillStop;
- (void)recordingDidStop;
@end
