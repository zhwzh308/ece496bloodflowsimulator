// Fragment shader
varying highp vec2 coordinate;
// varying: special variables that can be passed from the vertex shader to the fragment shader
uniform sampler2D videoframe;
// Uniform data can be any type. It is used in both v and f. It cannot be modified in the GPU
varying lowp vec4 fragmentColor;
// using lowp to specify precision. others: mediump, highp
void main()
{
    // gl_FragColor = fragmentColor;
	gl_FragColor = texture2D(videoframe, coordinate);
}
