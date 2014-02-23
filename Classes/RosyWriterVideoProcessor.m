#import <MobileCoreServices/MobileCoreServices.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <Endian.h>
#import "RosyWriterVideoProcessor.h"

#define BYTES_PER_PIXEL 4
#define WR 0.299
#define WG 0.587
#define WB 0.114

@interface RosyWriterVideoProcessor ()

// Redeclared as readwrite so that we can write to the property and still be atomic with external readers.
@property (readwrite) Float64 videoFrameRate;
@property (readwrite) CGFloat heartRate;
@property (readwrite) CMVideoDimensions videoDimensions;
@property (readwrite) CMVideoCodecType videoType;

@property (readwrite, getter=isRecording) BOOL recording;

@property (readwrite) AVCaptureVideoOrientation videoOrientation;

@end

@implementation RosyWriterVideoProcessor

@synthesize delegate;
@synthesize videoFrameRate, videoDimensions, videoType;
@synthesize referenceOrientation;
@synthesize videoOrientation;
@synthesize recording;

- (id) init
{
    if (self = [super init]) {
        previousSecondTimestamps = [[NSMutableArray alloc] init];
        referenceOrientation = UIDeviceOrientationPortrait;
        
        // The temporary path for the video before saving it to the photo album
        movieURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), @"ECE496.MOV"]];
        [movieURL retain];
        previousFrameAverageGreen0 = 0.0f;
        previousFrameAverageGreen1 = previousFrameAverageGreen0;
        frame_number = 0;
        isUsingFrontCamera = NO;
		//tmp = (BOOL *)malloc(sizeof(BOOL) * 960 * 540 );
		_heartRate=0.0f;
		frontCamera = nil;
		backCamera = nil;
    }
    return self;
}

- (void)dealloc
{
    [previousSecondTimestamps release];
    [movieURL release];

	[super dealloc];
}

#pragma mark Utilities

- (void) calculateFramerateAtTimestamp:(CMTime) timestamp
{
	[previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
    
	CMTime oneSecond = CMTimeMake( 1, 1 );
	CMTime oneSecondAgo = CMTimeSubtract( timestamp, oneSecond );
    
	while( CMTIME_COMPARE_INLINE( [[previousSecondTimestamps objectAtIndex:0] CMTimeValue], <, oneSecondAgo ) )
		[previousSecondTimestamps removeObjectAtIndex:0];
	Float64 newRate = (Float64) [previousSecondTimestamps count];
	self.videoFrameRate = (self.videoFrameRate + newRate) / 2;
}
// Set tmp at row and col.

- (void) step1_pixelFromRGBtoYCbCr:(unsigned char *)p row:(int)row column:(int) col
{
	CGFloat Cb = 128.0f - 0.14822656f * p[2] - 0.290992188f*p[1] + 0.4392148f*p[0];
	CGFloat Cr = 128.0f + 0.4392148f * p[2] - (0.367789f * p[1]) - (0.07142578f* p[0]);
	tmp[row][col] = (Cb >= 77.0f && Cb <= 127.0f && Cr >= 133.0f && Cr <= 173.0f);
}

- (void)removeFile:(NSURL *)fileURL
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [fileURL path];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError *error;
        BOOL success = [fileManager removeItemAtPath:filePath error:&error];
		if (!success)
			[self showError:error];
    }
}

- (CGFloat)angleOffsetFromPortraitOrientationToOrientation:(AVCaptureVideoOrientation)orientation
{
	CGFloat angle = 0.0;
	switch (orientation) {
		case AVCaptureVideoOrientationPortrait:
			angle = 0.0;
			break;
		case AVCaptureVideoOrientationPortraitUpsideDown:
			angle = M_PI;
			break;
		case AVCaptureVideoOrientationLandscapeRight:
			angle = -M_PI_2;
			break;
		case AVCaptureVideoOrientationLandscapeLeft:
			angle = M_PI_2;
			break;
		default:
			break;
	}
	return angle;
}

- (CGAffineTransform)transformFromCurrentVideoOrientationToOrientation:(AVCaptureVideoOrientation)orientation
{
	CGAffineTransform transform = CGAffineTransformIdentity;

	// Calculate offsets from an arbitrary reference orientation (portrait)
	CGFloat orientationAngleOffset = [self angleOffsetFromPortraitOrientationToOrientation:orientation];
	CGFloat videoOrientationAngleOffset = [self angleOffsetFromPortraitOrientationToOrientation:self.videoOrientation];
	
	// Find the difference in angle between the passed in orientation and the current video orientation
	CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
	transform = CGAffineTransformMakeRotation(angleOffset);
	
	return transform;
}

#pragma mark Recording

- (void)saveMovieToCameraRoll
{
	ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
	[library writeVideoAtPathToSavedPhotosAlbum:movieURL
								completionBlock:^(NSURL *assetURL, NSError *error) {
									if (error)
										[self showError:error];
									else
										[self removeFile:movieURL];
									
									dispatch_async(movieWritingQueue, ^{
										recordingWillBeStopped = NO;
										self.recording = NO;
										
										[self.delegate recordingDidStop];
									});
								}];
	[library release];
}

- (void) writeSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType
{
	if ( assetWriter.status == AVAssetWriterStatusUnknown ) {
		
        if ([assetWriter startWriting]) {			
			[assetWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
		}
		else {
			[self showError:[assetWriter error]];
		}
	}
	
	if ( assetWriter.status == AVAssetWriterStatusWriting ) {
		
		if (mediaType == AVMediaTypeVideo) {
			if (assetWriterVideoIn.readyForMoreMediaData) {
				if (![assetWriterVideoIn appendSampleBuffer:sampleBuffer]) {
					[self showError:[assetWriter error]];
				}
			}
		}
		else if (mediaType == AVMediaTypeAudio) {
			if (assetWriterAudioIn.readyForMoreMediaData) {
				if (![assetWriterAudioIn appendSampleBuffer:sampleBuffer]) {
					[self showError:[assetWriter error]];
				}
			}
		}
	}
}

- (BOOL) setupAssetWriterAudioInput:(CMFormatDescriptionRef)currentFormatDescription
{
	const AudioStreamBasicDescription *currentASBD = CMAudioFormatDescriptionGetStreamBasicDescription(currentFormatDescription);

	size_t aclSize = 0;
	const AudioChannelLayout *currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(currentFormatDescription, &aclSize);
	NSData *currentChannelLayoutData = nil;
	
	// AVChannelLayoutKey must be specified, but if we don't know any better give an empty data and let AVAssetWriter decide.
	if ( currentChannelLayout && aclSize > 0 )
		currentChannelLayoutData = [NSData dataWithBytes:currentChannelLayout length:aclSize];
	else
		currentChannelLayoutData = [NSData data];
	
	NSDictionary *audioCompressionSettings = [NSDictionary dictionaryWithObjectsAndKeys:
											  [NSNumber numberWithInteger:kAudioFormatMPEG4AAC], AVFormatIDKey,
											  [NSNumber numberWithFloat:currentASBD->mSampleRate], AVSampleRateKey,
											  [NSNumber numberWithInt:64000], AVEncoderBitRatePerChannelKey,
											  [NSNumber numberWithInteger:currentASBD->mChannelsPerFrame], AVNumberOfChannelsKey,
											  currentChannelLayoutData, AVChannelLayoutKey,
											  nil];
	if ([assetWriter canApplyOutputSettings:audioCompressionSettings forMediaType:AVMediaTypeAudio]) {
		assetWriterAudioIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioCompressionSettings];
		assetWriterAudioIn.expectsMediaDataInRealTime = YES;
		if ([assetWriter canAddInput:assetWriterAudioIn])
			[assetWriter addInput:assetWriterAudioIn];
		else {
			NSLog(@"Couldn't add asset writer audio input.");
            return NO;
		}
	}
	else {
		NSLog(@"Couldn't apply audio output settings.");
        return NO;
	}
    
    return YES;
}

- (BOOL) setupAssetWriterVideoInput:(CMFormatDescriptionRef)currentFormatDescription 
{
	float bitsPerPixel;
	CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(currentFormatDescription);
	int numPixels = dimensions.width * dimensions.height;
	int bitsPerSecond;
	
	// Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
	if ( numPixels < (640 * 480) )
		bitsPerPixel = 4.05; // This bitrate matches the quality produced by AVCaptureSessionPresetMedium or Low.
	else
		bitsPerPixel = 11.4; // This bitrate matches the quality produced by AVCaptureSessionPresetHigh.
	
	bitsPerSecond = numPixels * bitsPerPixel;
	
	NSDictionary *videoCompressionSettings = [NSDictionary dictionaryWithObjectsAndKeys:
											  AVVideoCodecH264, AVVideoCodecKey,
											  [NSNumber numberWithInteger:dimensions.width], AVVideoWidthKey,
											  [NSNumber numberWithInteger:dimensions.height], AVVideoHeightKey,
											  [NSDictionary dictionaryWithObjectsAndKeys:
											   [NSNumber numberWithInteger:bitsPerSecond], AVVideoAverageBitRateKey,
											   [NSNumber numberWithInteger:30], AVVideoMaxKeyFrameIntervalKey,
											   nil], AVVideoCompressionPropertiesKey,
											  nil];
    //use an AVAssetWriter object to write media data to a new file of a specified audiovisual container type
	if ([assetWriter canApplyOutputSettings:videoCompressionSettings forMediaType:AVMediaTypeVideo]) {
		assetWriterVideoIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoCompressionSettings];
		assetWriterVideoIn.expectsMediaDataInRealTime = YES;
		assetWriterVideoIn.transform = [self transformFromCurrentVideoOrientationToOrientation:self.referenceOrientation];
		if ([assetWriter canAddInput:assetWriterVideoIn])
			[assetWriter addInput:assetWriterVideoIn];
		else {
			NSLog(@"Couldn't add asset writer video input.");
            return NO;
		}
	}
	else {
		NSLog(@"Couldn't apply video output settings.");
        return NO;
	}
    
    return YES;
}

- (void) startRecording
{
	dispatch_async(movieWritingQueue, ^{
	
		if ( recordingWillBeStarted || self.recording )
			return;

		recordingWillBeStarted = YES;

		// recordingDidStart is called from captureOutput:didOutputSampleBuffer:fromConnection: once the asset writer is setup
		[self.delegate recordingWillStart];

		// Remove the file if one with the same name already exists
		[self removeFile:movieURL];

		// Create an asset writer
		NSError *error;
		assetWriter = [[AVAssetWriter alloc] initWithURL:movieURL fileType:(NSString *)kUTTypeQuickTimeMovie error:&error];
		if (error)
			[self showError:error];
	});	
}

- (void) stopRecording
{
	dispatch_async(movieWritingQueue, ^{
		
		if ( recordingWillBeStopped || (self.recording == NO) )
			return;
		
		recordingWillBeStopped = YES;
		
		// recordingDidStop is called from saveMovieToCameraRoll
		[self.delegate recordingWillStop];
        //[assetWriter finishWriting]
        //[assetWriter finishWritingWithCompletionHandler:^(){
        //  NSLog (@"finished writing");
        //  This method returns immediately and causes its work to be performed asynchronously.
        //  }];

		if ([assetWriter finishWriting]) {
			[assetWriterAudioIn release];
			[assetWriterVideoIn release];
			[assetWriter release];
			assetWriter = nil;
			
			readyToRecordVideo = NO;
			readyToRecordAudio = NO;
			
			[self saveMovieToCameraRoll];
		}
		else {
			[self showError:[assetWriter error]];
		}
	});
}

#pragma mark Processing
- (void)fillInArray: (CVImageBufferRef)pixelBuffer
{
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	size_t bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
	// Total number of pixels.
	size_t bufferSize = bufferHeight * bufferWidth;
	unsigned char *pixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
	
	// Since the pixel is an unsigned char, the following variables are always ints.
	// Access pointer. Moving during the loop operation
    unsigned char *pixel = pixelBase;
    uint32_t sumOfRed = 0, sumOfGreen = 0; // max 4e+10, enough to sum bufferSize * 255
    for (int row = 0; row < bufferHeight; row++) {
        for (int col = 0; col < bufferWidth; col++) {
            //Cb = 128.0f - me - (0.331264f * pixel[1]) + (pixel[0] / 2.0f);
            sumOfRed += pixel[2];
            sumOfGreen += pixel[1];
            pixel += BYTES_PER_PIXEL;
        }
        pixel += BYTES_PER_PIXEL;
    }
    // runtime frame averages.
    arrayOfRedChannelAverage[frame_number] = ((double) sumOfRed) / bufferSize;
    arrayOfGreenChannelAverage[frame_number] = ((double) sumOfGreen) / bufferSize;
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
}

- (void)heartRateEstimate
{
	double min, max;
	min = arrayOfRedChannelAverage[0];
	max = min;
	for (int i = 0; i < frame_number; ++i){
		if (arrayOfRedChannelAverage[i] < min)
			min = arrayOfRedChannelAverage[i];
		else if (arrayOfRedChannelAverage[i] > max)
			max = arrayOfRedChannelAverage[i];
	}
	int num_emi_peaks, num_absop_peaks = 0;
	int max_emi_peaks = 500, max_absop_peaks = 500;
	double delta = 0.05;
	int minHR = 24;
	int maxHR = 240;
	/*
	int WINDOW_LENGTH = 0;
	if (frame_number > 255)
		WINDOW_LENGTH = 7;
	else if (frame_number > 150)
		WINDOW_LENGTH = 3;
	else if (frame_number > 90)
		WINDOW_LENGTH = 1;
	else
		WINDOW_LENGTH = 1;
	*/
	//[self movingAverage:WINDOW_LENGTH];
	
	int* peak_indices = (int*) malloc(sizeof(int)*max_emi_peaks);
	memset (peak_indices,0,sizeof(int)*max_emi_peaks);
	
	double* peak_values = (double*)malloc(sizeof(double)*max_emi_peaks);
	memset (peak_values,0,sizeof(double)*max_emi_peaks);
	// detect_peak
	if (!detect_peak(arrayOfRedChannelAverage, frame_number, &num_emi_peaks, max_emi_peaks, &num_absop_peaks, max_absop_peaks, delta, peak_indices, peak_values)) {
		NSLog(@"num_emi_peaks = %d\n",num_emi_peaks);
		NSLog(@"num_absop_peaks = %d\n",num_absop_peaks);
		if (num_emi_peaks > 2){
			
			if (differences != nil){
				free(differences);
				differences = NULL;
			}
			
			differences = (int *) malloc(sizeof(int)*(num_emi_peaks-1));
			memset(differences,0,sizeof(int)*(num_emi_peaks-1));
			sizeOfDifferences = num_emi_peaks-1;
			sizeOfCollectedData = frame_number;
			for (int i = 0; i < num_emi_peaks-1;++i){
				if (peak_values[i] < 255){ // it's counting mx = MAXDBL as a max
					
					// calculate the difference
					differences[i] = peak_indices[i+1] - peak_indices[i];
					
					// If that difference isn't within range, set the difference to 0
					// This must be interpreted by later code as being NULL
					
					if (60 * frame_number/(10.0f*differences[i]) < minHR
						||
						60 * frame_number/(10.0f*differences[i]) > maxHR){
						differences[i] = 0;
					}
				}
				else {
					// If the peak was greater than 255, it doesn't count and we don't have a valid difference.
					differences[i] = 0;
				}
				// print the calculated differences, for easier debugging!
				printf("%d - %d = %d\n", peak_indices[i+1],peak_indices[i],differences[i]);
			}
			
			//Sometimes the last one shows a false peak.
			// Calculate the average without it.
			// If it is more than 5 away from the average, don't count it.
			double tempSum = 0;
			for (int i = 0; i<num_emi_peaks-2;++i){
				tempSum += differences[i];
			}
			double tempAvg = tempSum/(num_emi_peaks-2);
			if (tempAvg - differences[num_emi_peaks-2] > 5){
				differences[num_emi_peaks-2] = 0;
			}
			
			double sum = 0;
			int numSums = 0;
			
			for (int i = 0; i < num_emi_peaks-1; ++i){
				if (differences[i] != 0){
					sum = sum + differences[i];
					numSums = numSums + 1;
				}
			}
			_heartRate = 60 * frame_number / (10 * sum/numSums);
			NSLog(@"Heart rate measured is %f", _heartRate);
		}
	}
}

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
				 )
{
    int     i = 1;
    double  mx;
    double  mn;
    int     mx_pos = 0;
    int     mn_pos = 0;
    int     is_detecting_emi = 0;// = emi_first;
    
    
    //mn = DBL_MAX;
    //mx = -DBL_MAX;
    
    mx = data[0];
    mn = data[0];
    
    *num_emi_peaks = 0;
    *num_absop_peaks = 0;
    
    int j = 0;
    
    if (data[i+1] > data[i])
        is_detecting_emi = 1;
    
    for(i = 1; i < data_count; ++i)
    {
        if(data[i] > mx)
        {
            mx_pos = i;
            mx = data[i];
        }
        if(data[i] < mn)
        {
            mn_pos = i;
            mn = data[i];
        }
        
        if(is_detecting_emi &&
           data[i] < mx - delta)
        {
            if(*num_emi_peaks >= max_emi_peaks) /* not enough spaces */
                return 1;
            
            //      emi_peaks[*num_emi_peaks] = mx_pos;
            ++ (*num_emi_peaks);
            
            is_detecting_emi = 0;
            
            i = mx_pos - 1;
            
            peaks_index[j] = mx_pos;
            peaks_values[j] = data[mx_pos];
            j = j+1;
            
            mn = data[mx_pos];
            mn_pos = mx_pos;
        }
        else if((!is_detecting_emi) &&
                data[i] > mn + delta)
        {
            if(*num_absop_peaks >= max_absop_peaks)
                return 2;
            
            //     absop_peaks[*num_absop_peaks] = mn_pos;
            ++ (*num_absop_peaks);
            
            is_detecting_emi = 1;
            
            i = mn_pos - 1;
            
            mx = data[mn_pos];
            mx_pos = data[mn_pos];
        }
    }
    
    return 0;
}

- (void)createBitmapsfromPixelBuffer: (CVImageBufferRef)pixelBuffer
{
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
	size_t bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
    
	unsigned char *pixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);

	// Since the pixel is an unsigned char, the following variables are always ints.
	// Access pointer. Moving during the loop operation
    unsigned char *pixel = pixelBase;
    // Condition 2: sufficient data is collected, we simulate HR.
		// Simulation source signal , will use the HR calculated from avg.
    //CGFloat hr_sim = 40.0f * (sinf(currentTime * 1.256637f) + sinf(2.8274333f * currentTime));// + 80.0f;
	CGFloat hr_sim = 40.0f * sinf(currentTime * 6.28f * [self heartRate] / 60.0f);
		// Step 1 and partial 2
    for (int row = 0; row < bufferHeight; row++) {
        for (int col = 0; col < bufferWidth; col++) {
            // Step 1. Chrominance threshold, large bitmap
            [self step1_pixelFromRGBtoYCbCr:pixel row:row column:col];
			
			// Step 2. Set low res bitmap
            if ( !( ((row+1) % 4) || ((col+1) % 4) ) ) {
					// that is, on row 3, 7, 11, etc
					// after col 3, 7, 11, etc inclusive
					
					// 1. Roll back and work on sum.
                int sum = tmp[row-3][col-3] + tmp[row-3][col-2] + tmp[row-3][col-1] + tmp[row-3][col];
					sum += tmp[row-2][col-3] + tmp[row-2][col-2] + tmp[row-2][col-1] + tmp[row-2][col];
					sum += tmp[row-1][col-3] + tmp[row-1][col-2] + tmp[row-1][col-1] + tmp[row-1][col];
					sum += tmp[row][col-3] + tmp[row][col-2] + tmp[row][col-1] + tmp[row][col];
                if (sum < 16) {
						// Optimized: this should still work because
						// 3/4 = 0, 7/4 = 1, ..., 956/4 = 239 in int arithmatic.
                    lesstemp[row/4][col/4] = 0;
                }
                else {
                    lesstemp[row/4][col/4] = 1;
                }
					// 2. Return to reality
			}
			pixel += BYTES_PER_PIXEL;
		}
		pixel += BYTES_PER_PIXEL;
	}
		/* Step 2 cont. Reduce both sides by 4 times. Problem: this is not proof yet.
		pixel = pixelBase;
        for (int row = 0; row < bufferHeight; row += 4) {
            for (int col = 0; col < bufferWidth; col += 4) {
                //check the 4by4 Y value
				unsigned char *pixelTemp = pixel;
			    SumY = 0.0f;
				for (int row = 0; row < 4; row++) {
					for (int col = 0; col < 4; col++){
						Y = 16.0f+0.256789f*pixelTemp[2]+0.5041289f*pixelTemp[1]+0.09790625f*pixelTemp[0];
						SumY += Y;
						pixelTemp += BYTES_PER_PIXEL;
					}
					pixelTemp += BYTES_PER_PIXEL;
				}
				pixelTemp = pixel;
				
				CGFloat Mu = SumY/16.0f;
				
				CGFloat stdDev = 0.0f;
				for (int row = 0; row < 4; row++) {
					for (int col = 0; col < 4; col++){
						Y = 16.0f+0.256789f*pixelTemp[2]+0.5041289f*pixelTemp[1]+0.09790625f*pixelTemp[0];
						stdDev += (Y-Mu)*(Y-Mu);
						pixelTemp += BYTES_PER_PIXEL;
					}
					pixelTemp += BYTES_PER_PIXEL;
				}
				stdDev = sqrtf(stdDev/16.0f);
				
                if ((stdDev >= 3.5f) && (lesstemp[row/4][col/4] == 1)) {
					lesstemp[row/4][col/4] = 1;
                }
                else {
					lesstemp[row/4][col/4] = 0;
                }
                pixel += 4 * BYTES_PER_PIXEL;
            }
            pixel += (3 * bufferWidth) * BYTES_PER_PIXEL;
        }
		 */
		// Step 3:
/*		pixel = pixelBase;
		CGFloat SumY = 0.0f;
		for (int row = 0; row < bufferHeight; row++) {
		    for (int col = 0; col < bufferWidth; col++){
				Y = 16.0f+0.256789f*pixel[2]+0.5041289f*pixel[1]+0.09790625f*pixel[0];
				SumY += Y;
				pixel += BYTES_PER_PIXEL;
			}
			pixel += BYTES_PER_PIXEL;
		}
		
		CGFloat Mu = SumY / (bufferHeight * bufferWidth);
        CGFloat stdDev = 0.0f;
		pixel = pixelBase;
		for (int row = 0; row < bufferHeight; row++) {
		    for (int col = 0; col < bufferWidth; col++){
				Y = 16.0f+0.256789f*pixel[2]+0.5041289f*pixel[1]+0.09790625f*pixel[0];
				// Average value
                stdDev += (Y-Mu)*(Y-Mu);
				
				pixel += BYTES_PER_PIXEL;
			}
			pixel += BYTES_PER_PIXEL;
		}
		stdDev = sqrtf(stdDev/(bufferHeight * bufferWidth));
*/
		
		// Finally: draw using bitmap
    pixel = pixelBase;
    for (int row = 0; row < bufferHeight; row++) {
        for (int col = 0; col < bufferWidth; col++) {
				//if (tmp[row][col]) {
            if (lesstemp[row/4][col/4]) {
                CGFloat to_color = ((float) pixel[2]) + hr_sim;
                if (to_color >= 255.0f) {
                    pixel[2] = 255;
                } else if (to_color <= 0.0f){
                    pixel[2] = 0;
                }
                else
                    pixel[2] = (unsigned char) to_color;
            }
            pixel += BYTES_PER_PIXEL;
        }
        pixel += BYTES_PER_PIXEL;
    }
	CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
}

#pragma mark Capture

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    
	if ( connection == videoConnection ) {
		
		// Get framerate
		CMTime timestamp = CMSampleBufferGetPresentationTimeStamp( sampleBuffer );
		[self calculateFramerateAtTimestamp:timestamp];
        currentTime = CMTimeGetSeconds(timestamp);
		// Get frame dimensions (for onscreen display)
		if (self.videoDimensions.width == 0 && self.videoDimensions.height == 0)
			self.videoDimensions = CMVideoFormatDescriptionGetDimensions( formatDescription );
		
		// Get buffer type
		if ( self.videoType == 0 )
			self.videoType = CMFormatDescriptionGetMediaSubType( formatDescription );
		if (frame_number < MAX_NUM_FRAMES) {
			if (frame_number == 10)
				[self switchDeviceTorchMode:backCamera];
			if (frame_number == MAX_NUM_FRAMES-10) {
				[self switchDeviceTorchMode:backCamera];
			}
            // Collect average color channel values for HR estimation
            // Synchronously process the pixel buffer
            [self fillInArray:CMSampleBufferGetImageBuffer(sampleBuffer)];
			frame_number++;
		}
        else {
            if (!isUsingFrontCamera) {
				[self heartRateEstimate];
                [self stopAndTearDownCaptureSession];
                isUsingFrontCamera = YES;
                [self setupAndStartCaptureSession];
            }
            else {
            // Start simulation
                [self createBitmapsfromPixelBuffer:CMSampleBufferGetImageBuffer(sampleBuffer)];
            //frame_number = 0;
            }
        }
		
		// Enqueue it for preview.  This is a shallow queue, so if image processing is taking too long,
		// we'll drop this frame for preview (this keeps preview latency low).
		OSStatus err = CMBufferQueueEnqueue(previewBufferQueue, sampleBuffer);
		if ( !err ) {
			dispatch_async(dispatch_get_main_queue(), ^{
				CMSampleBufferRef sbuf = (CMSampleBufferRef)CMBufferQueueDequeueAndRetain(previewBufferQueue);
				if (sbuf) {
					CVImageBufferRef pixBuf = CMSampleBufferGetImageBuffer(sbuf);
					[self.delegate pixelBufferReadyForDisplay:pixBuf];
					CFRelease(sbuf); // Destroy sbuf.
				}
			});
		}
	}
    
	CFRetain(sampleBuffer);
	CFRetain(formatDescription);
	dispatch_async(movieWritingQueue, ^{

		if ( assetWriter ) {
		
			BOOL wasReadyToRecord = (readyToRecordAudio && readyToRecordVideo);
			
			if (connection == videoConnection) {
				
				// Initialize the video input if this is not done yet
				if (!readyToRecordVideo)
					readyToRecordVideo = [self setupAssetWriterVideoInput:formatDescription];
				
				// Write video data to file
				if (readyToRecordVideo && readyToRecordAudio)
					[self writeSampleBuffer:sampleBuffer ofType:AVMediaTypeVideo];
			}
			else if (connection == audioConnection) {
				
				// Initialize the audio input if this is not done yet
				if (!readyToRecordAudio)
					readyToRecordAudio = [self setupAssetWriterAudioInput:formatDescription];
				
				// Write audio data to file
				if (readyToRecordAudio && readyToRecordVideo)
					[self writeSampleBuffer:sampleBuffer ofType:AVMediaTypeAudio];
			}
			
			BOOL isReadyToRecord = (readyToRecordAudio && readyToRecordVideo);
			if ( !wasReadyToRecord && isReadyToRecord ) {
				recordingWillBeStarted = NO;
				self.recording = YES;
				[self.delegate recordingDidStart];
			}
		}
		CFRelease(sampleBuffer);
		CFRelease(formatDescription);
	});
}

// Flash on

- (void) switchDeviceTorchMode:(AVCaptureDevice *)device
{
    if ([device isTorchModeSupported:AVCaptureTorchModeOn]) {
        NSError *error = nil;
        if ([device lockForConfiguration:&error]) {
            if ([device isTorchActive]) {
                [device setTorchMode:AVCaptureTorchModeOff];
            }
            else
                [device setTorchMode:AVCaptureTorchModeOn];
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"I am not an iPhone!\n");
        }
    }
}

// new : Turen off AF

- (void) switchDeviceAF:(AVCaptureDevice *)device
{
    //CGPoint autofocusPoint = CGPointMake(0.5f, 0.5f);
    if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
        NSError *error = nil;
        //[device setFocusPointOfInterest:autofocusPoint];
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:AVCaptureFocusModeLocked];
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"I gave up AE.\n");
        }
        
    }
}

// new : Turen off AE
- (void) switchDeviceAE:(AVCaptureDevice *)device {
    if ([device isExposureModeSupported:AVCaptureExposureModeLocked]) {
        NSError *error = nil;
        //CGPoint exposurePoint = autofocusPoint;
        //[device setExposurePointOfInterest:exposurePoint];
        if ([device lockForConfiguration:&error]) {
            [device setExposureMode:AVCaptureExposureModeLocked];
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"I gave up AF.\n");
        }
    }
}

// new : Turen off white balance
- (void) switchDeviceWhiteBalance:(AVCaptureDevice *)device {
    if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
        NSError *error = nil;
        if ([device lockForConfiguration:&error]) {
            [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeLocked];
            [device unlockForConfiguration];
        }
        else {
            NSLog(@"I gave up WB.\n");
        }
    }
}

- (AVCaptureDevice *)videoDeviceWithPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices)
        if ([device position] == position) {
            return device;
        }
    return nil;
}

- (AVCaptureDevice *)audioDevice
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
    if ([devices count] > 0)
        return [devices objectAtIndex:0];
    
    return nil;
}

- (BOOL) setupCaptureSession 
{
	/*
		Overview: RosyWriter uses separate GCD queues for audio and video capture.  If a single GCD queue
		is used to deliver both audio and video buffers, and our video processing consistently takes
		too long, the delivery queue can back up, resulting in audio being dropped.
		
		When recording, RosyWriter creates a third GCD queue for calls to AVAssetWriter.  This ensures
		that AVAssetWriter is not called to start or finish writing from multiple threads simultaneously.
		
		RosyWriter uses AVCaptureSession's default preset, AVCaptureSessionPresetHigh.
	 */
	 
    /*
	 * Create capture session
     * Instead of not configuring the preset, let's make it VGA
     * This way, we have no need to worry about selecting video area.
	 */
    captureSession = [[AVCaptureSession alloc] init];
    NSString *option = isUsingFrontCamera?AVCaptureSessionPreset640x480:AVCaptureSessionPresetiFrame960x540;
    if ([captureSession canSetSessionPreset:option]) {
        // Most resource efficient.
        captureSession.sessionPreset = option;
    }
    /*
	 * Create audio connection
	 */
    AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:[self audioDevice] error:nil];
    if ([captureSession canAddInput:audioIn])
        [captureSession addInput:audioIn];
	[audioIn release];
	
	AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
	dispatch_queue_t audioCaptureQueue = dispatch_queue_create("Audio Capture Queue", DISPATCH_QUEUE_SERIAL);
	[audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
	dispatch_release(audioCaptureQueue);
	if ([captureSession canAddOutput:audioOut])
		[captureSession addOutput:audioOut];
	audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
	[audioOut release];
    
	/*
	 * Create video connection: AVCaptureDevicePositionBack, rear camera
	 */
    NSArray *devices= [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    // Search device list for target devices.
    for (AVCaptureDevice *device in devices) {
        if(frontCamera && backCamera)
            break;
        else if (device.position == AVCaptureDevicePositionFront) {
            frontCamera = device;
        }
        else if (device.position == AVCaptureDevicePositionBack)
            backCamera = device;
    }
    AVCaptureDeviceInput *videoIn;
    if (isUsingFrontCamera) {
        videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:frontCamera error:nil];
		NSLog(@"Using Front camera");
    } else {
		NSLog(@"Using back camera");
        videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:backCamera error:nil];
    }
    if ([captureSession canAddInput:videoIn]) {
        [captureSession addInput:videoIn];
    }
	[videoIn release];
    
	AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
	/*
		RosyWriter prefers to discard late video frames early in the capture pipeline, since its
		processing can take longer than real-time on some platforms (such as iPhone 3GS).
		Clients whose image processing is faster than real-time should consider setting AVCaptureVideoDataOutput's
		alwaysDiscardsLateVideoFrames property to NO. 
	 */
    
    // Experiment: performance demaning setting. Set to yes for old platforms.
	[videoOut setAlwaysDiscardsLateVideoFrames:YES];
    // Camera pixel buffers are natively YUV but most image processing algorithms expect RBGA data.
	// [videoOut setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    // using kCVPixelFormatType_420YpCvCr88iPlanarFullRange, full-range (luma=[0,255] chroma=[1,255])
    
    NSDictionary *options = @{(id)kCVPixelBufferPixelFormatTypeKey:
                                  [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]};
    [videoOut setVideoSettings:options];
	dispatch_queue_t videoCaptureQueue = dispatch_queue_create("Video Capture Queue", DISPATCH_QUEUE_SERIAL);
	[videoOut setSampleBufferDelegate:self queue:videoCaptureQueue];
	dispatch_release(videoCaptureQueue);
	if ([captureSession canAddOutput:videoOut])
		[captureSession addOutput:videoOut];
	videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
	previewLayer = [[AVCaptureVideoPreviewLayer alloc]
                    initWithSession:captureSession];
	[previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
	[previewLayer setVideoGravity:AVLayerVideoGravityResizeAspect];
	self.videoOrientation = [videoConnection videoOrientation]; // AVLayerVideoGravityResize
	[videoOut release];
    
	return YES;
}

- (void) setupAndStartCaptureSession
{
	// Create a shallow queue for buffers going to the display for preview.
	OSStatus err = CMBufferQueueCreate(kCFAllocatorDefault, 1, CMBufferQueueGetCallbacksForUnsortedSampleBuffers(), &previewBufferQueue);
	if (err)
		[self showError:[NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:nil]];
	
	// Create serial queue for movie writing
	movieWritingQueue = dispatch_queue_create("Movie Writing Queue", DISPATCH_QUEUE_SERIAL);
	
    if ( !captureSession )
		[self setupCaptureSession];
	
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionStoppedRunningNotification:) name:AVCaptureSessionDidStopRunningNotification object:captureSession];
	
	if ( !captureSession.isRunning )
		[captureSession startRunning];
}

- (void) pauseCaptureSession
{
	if ( captureSession.isRunning )
		[captureSession stopRunning];
}

- (void) resumeCaptureSession
{
	if ( !captureSession.isRunning )
		[captureSession startRunning];
}

- (void)captureSessionStoppedRunningNotification:(NSNotification *)notification
{
	dispatch_async(movieWritingQueue, ^{
		if ( [self isRecording] ) {
			[self stopRecording];
		}
	});
}

- (void) stopAndTearDownCaptureSession
{
    [captureSession stopRunning];
	if (captureSession)
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:captureSession];
	[captureSession release];
	captureSession = nil;
	if (previewBufferQueue) {
		CFRelease(previewBufferQueue);
		previewBufferQueue = NULL;	
	}
	if (movieWritingQueue) {
		dispatch_release(movieWritingQueue);
		movieWritingQueue = NULL;
	}
}

#pragma mark Error Handling

- (void)showError:(NSError *)error
{
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^(void) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[error localizedDescription]
                                                            message:[error localizedFailureReason]
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
        [alertView show];
        [alertView release];
    });
}

@end
