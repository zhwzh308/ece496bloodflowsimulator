#ifndef RosyWriter_ShaderUtilities_h
#define RosyWriter_ShaderUtilities_h
    
#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>
// compiles the source code strings that have been stored in the shader object specified by shader.
GLint glueCompileShader(GLenum target, GLsizei count, const GLchar **sources, GLuint *shader);

GLint glueLinkProgram(GLuint program);
GLint glueValidateProgram(GLuint program);
GLint glueGetUniformLocation(GLuint program, const GLchar *name);
// GLuint glCreateProgram (void);
// creates an empty program object and returns a non-zero value by which it can be referenced
GLint glueCreateProgram(const GLchar *vertSource, const GLchar *fragSource,
                        GLsizei attribNameCt, const GLchar **attribNames, 
                        const GLint *attribLocations,
                        GLsizei uniformNameCt, const GLchar **uniformNames,
                        GLint *uniformLocations,
                        GLuint *program);

#endif
