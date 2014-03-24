// Fragment shader
varying highp vec2 coordinate;
// varying: special variables that can be passed from the vertex shader to the fragment shader
uniform sampler2D videoframe;
// Uniform data can be any type. It is used in both v and f. It cannot be modified in the GPU
varying lowp vec4 fragmentColor;
// using lowp to specify precision. others: mediump, highp

const mediump mat4 rgbToYuv = mat4( 0.257,  0.439,  -0.148, 0.06,
                                   0.504, -0.368,  -0.291, 0.5,
                                   0.098, -0.071,   0.439, 0.5,
                                   0.0,     0.0,     0.0, 1.0);

const mediump mat4 yuvToRgb = mat4( 1.164,  1.164,  1.164,  -0.07884,
                                   2.018, -0.391,    0.0,  1.153216,
                                   0.0, -0.813,  1.596,  0.53866,
                                   0.0,    0.0,    0.0,  1.0);

// uniform mediump float centre, range;
void main()
{
    gl_FragColor = texture2D(videoframe, coordinate);
}
