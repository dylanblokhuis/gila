#include <cstdlib>
#include <stdio.h>
#include <vector>
#include <slang.h>
#include <slang-com-ptr.h>

using namespace Slang;

slang::CompilerOptionValue makeCompilerOptionValueInt0(int value)
{
    slang::CompilerOptionValue result;
    result.intValue0 = value;
    return result;
}

slang::CompilerOptionValue makeCompilerOptionValueInt1(int value)
{
    slang::CompilerOptionValue result;
    result.intValue1 = value;
    return result;
}

slang::CompilerOptionValue makeCompilerOptionValueBool(bool value)
{
    slang::CompilerOptionValue result;
    result.intValue0 = value ? 1 : 0;
    result.intValue1 = value ? 1 : 0;
    return result;
}

slang::CompilerOptionValue makeCompilerOptionValueString0(const char *value)
{
    slang::CompilerOptionValue result;
    result.kind = slang::CompilerOptionValueKind::String;
    result.stringValue0 = value;
    return result;
}

slang::CompilerOptionValue makeCompilerOptionValueString1(const char *value)
{
    slang::CompilerOptionValue result;
    result.kind = slang::CompilerOptionValueKind::String;
    result.stringValue1 = value;
    return result;
}

slang::CompilerOptionValue makeCompilerOptionValueStringBoth(const char *value1, const char *value2)
{
    slang::CompilerOptionValue result;
    result.kind = slang::CompilerOptionValueKind::String;
    result.stringValue0 = value1;
    result.stringValue1 = value2;
    return result;
}

extern "C"
{
    void *compile_slang(
        const char *filepath_ptr,
        const char *entrypoint_ptr,
        const char *in_source_string,
        SlangStage stage,
        size_t *out_len,
        int *out_result)
    {
        ComPtr<slang::IGlobalSession> slangGlobalSession;
        slang::createGlobalSession(slangGlobalSession.writeRef());

        slang::SessionDesc sessionDesc = {};
        slang::TargetDesc targetDesc = {};
        targetDesc.format = SLANG_SPIRV;
        targetDesc.profile = slangGlobalSession->findProfile("spirv_1_5");
        targetDesc.flags = SLANG_TARGET_FLAG_GENERATE_SPIRV_DIRECTLY;
        targetDesc.forceGLSLScalarBufferLayout = true;

        std::vector<slang::CompilerOptionEntry> compilerOptionEntries;
        compilerOptionEntries.push_back({slang::CompilerOptionName::Stage, makeCompilerOptionValueInt0(stage)});
        // compilerOptionEntries.push_back({slang::CompilerOptionName::OptimizationLevel, makeCompilerOptionValueInt0(3)});

        targetDesc.compilerOptionEntries = compilerOptionEntries.data();

        sessionDesc.targets = &targetDesc;
        sessionDesc.targetCount = 1;

        ComPtr<slang::ISession> session;
        slangGlobalSession->createSession(sessionDesc, session.writeRef());

        slang::IModule *slangModule = nullptr;
        {
            slangModule = session->loadModuleFromSourceString("module", filepath_ptr, in_source_string);
            if (!slangModule)
            {
                *out_result = -1;
                return nullptr;
            }
        }

        ComPtr<slang::IEntryPoint> entryPoint;
        slangModule->findEntryPointByName(entrypoint_ptr, entryPoint.writeRef());

        std::vector<slang::IComponentType *> componentTypes;
        componentTypes.push_back(slangModule);
        componentTypes.push_back(entryPoint);

        ComPtr<slang::IComponentType> composedProgram;
        {
            ComPtr<slang::IBlob> diagnosticsBlob;
            SlangResult result = session->createCompositeComponentType(
                componentTypes.data(),
                componentTypes.size(),
                composedProgram.writeRef(),
                nullptr);

            if (SLANG_FAILED(result))
            {
                *out_result = -1;
                return nullptr;
            }
        }

        ComPtr<slang::IBlob> spirvCode;
        {
            ComPtr<slang::IBlob> diagnosticsBlob;
            SlangResult result = composedProgram->getEntryPointCode(
                0, 0, spirvCode.writeRef(), diagnosticsBlob.writeRef());

            if (SLANG_FAILED(result))
            {
                *out_result = -1;
                return nullptr;
            }
        }

        auto out_spirv = (void *)std::malloc(spirvCode->getBufferSize());
        std::memcpy(out_spirv, spirvCode->getBufferPointer(), spirvCode->getBufferSize());

        *out_len = spirvCode->getBufferSize();
        *out_result = 0;

        return out_spirv;       
    }
}