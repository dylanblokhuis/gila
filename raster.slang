// Incoming to vertex shader
struct vertexInfo
{
  [[vk::location(0)]] float2 position : POSITION;
  [[vk::location(1)]] float3 color : COLOR;
};

// Vertex shader to pixel shader
struct v2p
{
  float3 color : COLOR;
  float4 sv_position : SV_Position; // Specify the position of a vertex in screen space (after projection).
};

// Vertex shader
[shader("vertex")]
v2p vertexMain(vertexInfo input)
{
  v2p output;
  output.color = input.color; // Pass through, will be interpolated
  output.sv_position = float4(input.position, 0.0, 1.0);

  return output;
}

// Pixel shader
[shader("pixel")]
float4 fragmentMain(v2p input) : SV_Target
{
  return float4(input.color, 1.0);
}