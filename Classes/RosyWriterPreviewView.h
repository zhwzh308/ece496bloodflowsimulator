#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/glext.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>

@interface RosyWriterPreviewView : UIView
{
	int renderBufferWidth;
	int renderBufferHeight;
    // A reference to a Core Video OpenGLES texture cache.
	CVOpenGLESTextureCacheRef videoTextureCache;
    // must initialize an EAGLContext object before calling any OpenGL ES functions
	EAGLContext* oglContext;
    
    // The EAGLContext class also provides methods used to integrate OpenGL ES content with Core Animation.
	GLuint frameBufferHandle;
	GLuint colorBufferHandle;
    GLuint passThroughProgram;
}

- (void)displayPixelBuffer:(CVImageBufferRef)pixelBuffer;
//- (BOOL) CheckForExtension: (NSString *)searchName;

@end
