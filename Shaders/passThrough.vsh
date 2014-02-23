attribute vec4 position;
attribute mediump vec4 textureCoordinate;
varying mediump vec2 coordinate;
// Vertex shader
void main()
{
	gl_Position = position;
	coordinate = textureCoordinate.xy;
}
