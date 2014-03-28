// Position as input variable for shader. Attribute is only available in the vertex shader.
attribute vec4 position;
attribute mediump vec4 textureCoordinate;
attribute vec4 color;
varying mediump vec2 coordinate;
varying vec4 fragmentColor;
// Vertex shader
void main()
{
	gl_Position = position * vec4(1,-1,1,1);
	coordinate = textureCoordinate.xy;
    fragmentColor = color;
}
