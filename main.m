/*

#import <UIKit/UIKit.h>

int main(int argc, char *argv[]) {
    
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    int retVal = UIApplicationMain(argc, argv, nil, nil);
    [pool release];
    return retVal;
}
*/

// Adopting Storyboard style: 2014-01-05
#import <UIKit/UIKit.h>
#import "RosyWriterAppDelegate.h"

int main(int argc, char *argv[]) {
    
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RosyWriterAppDelegate class]));
    }
}
