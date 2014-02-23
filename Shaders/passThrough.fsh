varying highp vec2 coordinate;
uniform sampler2D videoframe;
// Fragment shader
void main()
{
	gl_FragColor = texture2D(videoframe, coordinate);
}
