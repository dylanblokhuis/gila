pub usingnamespace @cImport({
    @cDefine("GLFW_INCLUDE_VULKAN", "1");
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("spirv_reflect/spirv_reflect.h");
    @cInclude("vk_mem_alloc.h");
});
