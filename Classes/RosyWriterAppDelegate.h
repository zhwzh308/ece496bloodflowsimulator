#import <UIKit/UIKit.h>

@class RosyWriterViewController;

@interface RosyWriterAppDelegate : NSObject <UIApplicationDelegate> {
    //UIWindow *window;
    RosyWriterViewController *mainViewController;
}

@property (nonatomic, retain) IBOutlet UIWindow *window;
@property (nonatomic, retain) IBOutlet RosyWriterViewController *mainViewController;

@end
