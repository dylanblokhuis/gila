//  Severity | Facility | Code
//     ---------|----------|-----
//     31       |    30-16 | 15-0
const SlangResult = packed struct(c_int) {
    severity: u1,
    facility: u15,
    code: u16,

    pub fn hasFailed(self: SlangResult) bool {
        return self.severity < 0;
    }

    pub fn hasSucceeded(self: SlangResult) bool {
        return self.severity >= 0;
    }

    pub fn getFacility(self: SlangResult) u15 {
        return self.facility;
    }
    pub fn getCode(self: SlangResult) u16 {
        return self.code;
    }
};
const SlangUint32 = c_uint;
const SlangInt32 = c_int;
const SlangInt = c_int;
const SlangUInt = c_uint;
const SlangSSizeT = c_int;
const SlangSizeT = c_uint;
const SlangBool = bool;
const SlangSession = opaque {};
const SlangCompileRequest = opaque {};
const SlangProfileID = c_uint;

const SlangCompileTarget = enum(c_int) {
    SLANG_TARGET_UNKNOWN,
    SLANG_TARGET_NONE,
    SLANG_GLSL,
    SLANG_GLSL_VULKAN_DEPRECATED, //< deprecated and removed: just use `SLANG_GLSL`.
    SLANG_GLSL_VULKAN_ONE_DESC_DEPRECATED, //< deprecated and removed.
    SLANG_HLSL,
    SLANG_SPIRV,
    SLANG_SPIRV_ASM,
    SLANG_DXBC,
    SLANG_DXBC_ASM,
    SLANG_DXIL,
    SLANG_DXIL_ASM,
    SLANG_C_SOURCE, //< The C language
    SLANG_CPP_SOURCE, //< C++ code for shader kernels.
    SLANG_HOST_EXECUTABLE, //< Standalone binary executable (for hosting CPU/OS)
    SLANG_SHADER_SHARED_LIBRARY, //< A shared library/Dll for shader kernels (for hosting CPU/OS)
    SLANG_SHADER_HOST_CALLABLE, //< A CPU target that makes the compiled shader code available to be run immediately
    SLANG_CUDA_SOURCE, //< Cuda source
    SLANG_PTX, //< PTX
    SLANG_CUDA_OBJECT_CODE, //< Object code that contains CUDA functions.
    SLANG_OBJECT_CODE, //< Object code that can be used for later linking
    SLANG_HOST_CPP_SOURCE, //< C++ code for host library or executable.
    SLANG_HOST_HOST_CALLABLE, //< Host callable host code (ie non kernel/shader)
    SLANG_CPP_PYTORCH_BINDING, //< C++ PyTorch binding code.
    SLANG_METAL, //< Metal shading language
    SLANG_METAL_LIB, //< Metal library
    SLANG_METAL_LIB_ASM, //< Metal library assembly
    SLANG_HOST_SHARED_LIBRARY, //< A shared library/Dll for host code (for hosting CPU/OS)
    SLANG_TARGET_COUNT_OF,
};

pub extern fn spGetBuildTagString() [*c]u8;
pub extern fn spCreateSession() *SlangSession;
pub extern fn spDestroySession(session: *SlangSession) void;

pub extern fn spCreateCompileRequest(session: *SlangSession) *SlangCompileRequest;
pub extern fn spDestroyCompileRequest(request: *SlangCompileRequest) void;

/// when it returns 0, it means the profile is not found
pub extern fn spFindProfile(session: *SlangSession, name: [*c]const u8) SlangProfileID;
pub extern fn spSetTargetProfile(request: *SlangCompileRequest, target_index: c_int, profile: SlangProfileID) void;
pub extern fn spAddCodeGenTarget(request: *SlangCompileRequest, target: SlangCompileTarget) c_int;
// spComputeStringHash
// spReflectionTypeLayout_GetMatrixLayoutMode
// spReflectionUserAttribute_GetArgumentCount
// spReflectionTypeLayout_GetSize
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeType
// spReflection_getHashedString
// spReflectionEntryPoint_getVarLayout
// spReflectionVariableLayout_getStage
// spReflectionEntryPoint_getNameOverride
// spSetTargetProfile
// spSetDumpIntermediates
// spReflectionTypeParameter_GetConstraintCount
// spReflectionTypeLayout_getSubObjectRangeSpaceOffset
// spReflectionType_GetFieldByIndex
// spReflectionEntryPoint_getComputeWaveSize
// spProcessCommandLineArguments
// spReflectionTypeLayout_getBindingRangeBindingCount
// spReflection_GetParameterCount
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeDescriptorCount
// spReflectionEntryPoint_getName
// spSetWriter
// spReflectionType_GetResourceAccess
// spSessionCheckPassThroughSupport
// spSetGlobalGenericArgs
// spGetWriter
// spReflectionTypeLayout_GetFieldCount
// spAddBuiltins
// spIsParameterLocationUsed
// spReflection_getGlobalParamsTypeLayout
// spAddEntryPointEx
// spReflectionVariableLayout_GetSemanticName
// spGetDiagnosticOutput
// spReflectionTypeLayout_GetElementTypeLayout
// spGetCompileTimeProfile
// spExtractRepro
// spReflectionTypeLayout_findFieldIndexByName
// spReflectionTypeLayout_GetElementStride
// spReflectionVariable_GetType
// spAddEntryPoint
// spReflectionVariableLayout_GetSemanticIndex
// spReflectionTypeLayout_getBindingRangeLeafVariable
// spReflectionTypeLayout_GetCategoryCount
// spReflectionTypeParameter_GetName
// spSetDumpIntermediatePrefix
// spReflectionType_getSpecializedTypeArgType
// spReflectionType_GetName
// spReflectionTypeLayout_getSubObjectRangeOffset
// spReflectionTypeLayout_getBindingRangeType
// spReflectionTypeLayout_getSubObjectRangeBindingRangeIndex
// spReflectionVariable_FindModifier
// spLoadReproAsFileSystem
// spDestroySession
// spFindProfile
// spReflectionEntryPoint_hasDefaultConstantBuffer
// spSessionSetSharedLibraryLoader
// spGetTranslationUnitSource
// spSetDebugInfoLevel
// spGetReflection
// spReflection_getGlobalConstantBufferSize
// spReflectionType_GetScalarType
// spSetTargetForceGLSLScalarBufferLayout
// spGetContainerCode
// spReflectionVariableLayout_GetVariable
// spSetDefaultModuleName
// spSetTypeNameForEntryPointExistentialTypeParam
// spReflectionTypeLayout_GetParameterCategory
// spReflectionParameter_GetBindingIndex
// spSetDebugInfoFormat
// spSaveRepro
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeIndexOffset
// spSetTargetMatrixLayoutMode
// spReflection_getEntryPointCount
// spReflectionTypeLayout_getKind
// spReflectionVariableLayout_GetOffset
// spCompileRequest_getEntryPoint
// spGetTargetHostCallable
// spReflectionEntryPoint_getStage
// spSetOutputContainerFormat
// spCompileRequest_getSession
// spReflectionType_GetUserAttribute
// spGetBuildTagString
// spSetLineDirectiveMode
// spReflectionTypeLayout_getBindingRangeDescriptorSetIndex
// spReflectionVariableLayout_GetTypeLayout
// spCreateSession
// spGetDiagnosticOutputBlob
// spReflection_FindTypeByName
// spSetTargetUseMinimumSlangOptimization
// spGetEntryPointCodeBlob
// spReflectionTypeLayout_getBindingRangeCount
// spGetEntryPointSource
// spReflectionUserAttribute_GetArgumentValueInt
// spLoadRepro
// spReflectionTypeLayout_getExplicitCounterBindingRangeOffset
// spSetDiagnosticFlags
// spReflectionType_GetElementCount
// spReflectionTypeLayout_getDescriptorSetSpaceOffset
// spReflectionEntryPoint_getParameterCount
// spCreateCompileRequest
// spReflectionTypeLayout_getBindingRangeDescriptorRangeCount
// spCompile
// spAddTargetCapability
// spReflectionTypeLayout_getContainerVarLayout
// spReflectionType_GetKind
// spReflectionType_GetUserAttributeCount
// spReflectionTypeParameter_GetConstraintByIndex
// spReflectionTypeLayout_GetStride
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeCategory
// spReflection_getHashedStringCount
// spSetPassThrough
// spReflectionTypeLayout_GetCategoryByIndex
// spAddTranslationUnitSourceFile
// spGetDependencyFilePath
// spReflectionVariable_GetName
// spReflectionVariableLayout_GetSpace
// spGetDependencyFileCount
// spReflectionTypeLayout_getSubObjectRangeCount
// spReflectionUserAttribute_GetArgumentValueFloat
// spReflectionType_GetElementType
// spSetCodeGenTarget
// spReflectionUserAttribute_GetArgumentType
// spReflectionTypeLayout_getGenericParamIndex
// spOverrideDiagnosticSeverity
// spReflectionTypeLayout_getAlignment
// spGetTranslationUnitCount
// spReflectionTypeLayout_getBindingRangeFirstDescriptorRangeIndex
// spReflectionUserAttribute_GetName
// spReflectionType_GetResourceResultType
// spAddTranslationUnitSourceString
// spSetMatrixLayoutMode
// spReflection_getGlobalParamsVarLayout
// spReflectionTypeLayout_GetType
// spAddSearchPath
// spTranslationUnit_addPreprocessorDefine
// spReflectionTypeLayout_getSpecializedTypePendingDataVarLayout
// spReflectionTypeLayout_GetElementVarLayout
// spReflectionEntryPoint_getParameterByIndex
// spSetFileSystem
// spSetTargetLineDirectiveMode
// spReflectionTypeLayout_getPendingDataTypeLayout
// spCompileRequest_getProgram
// spReflectionType_FindUserAttributeByName
// spSetIgnoreCapabilityCheck
// spSessionGetSharedLibraryLoader
// spDestroyCompileRequest
// spReflection_findEntryPointByName
// spGetDiagnosticFlags
// spReflectionEntryPoint_getComputeThreadGroupSize
// spAddTranslationUnitSourceBlob
// spReflection_GetTypeParameterCount
// spReflectionTypeLayout_GetFieldByIndex
// spReflectionTypeLayout_getBindingRangeLeafTypeLayout
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeCount
// spReflection_getGlobalConstantBufferBinding
// spReflection_getEntryPointByIndex
// spAddPreprocessorDefine
// spReflectionType_GetFieldCount
// spGetEntryPointHostCallable
// spReflectionTypeLayout_getDescriptorSetCount
// spReflection_GetParameterByIndex
// spSetCompileFlags
// spReflectionType_getSpecializedTypeArgCount
// spReflectionTypeParameter_GetIndex
// spReflectionType_GetColumnCount
// spReflectionVariableLayout_getPendingDataLayout
// spReflectionTypeLayout_getFieldBindingRangeOffset
// spAddTranslationUnit
// spEnableReproCapture
// spFindCapability
// spSetTypeNameForGlobalExistentialTypeParam
// spReflectionType_GetRowCount
// spGetEntryPointCode
// spAddCodeGenTarget
// spReflectionParameter_GetBindingSpace
// spAddLibraryReference
// spReflectionEntryPoint_usesAnySampleRateInput
// spReflectionEntryPoint_getResultVarLayout
// spReflection_specializeType
// spSetTargetFloatingPointMode
// spAddTranslationUnitSourceStringSpan
// spReflection_GetTypeParameterByIndex
// spCompileRequest_getProgramWithEntryPoints
// spSessionCheckCompileTargetSupport
// spReflectionType_GetResourceShape
// spGetCompileRequestCode
// spSetOptimizationLevel
// spReflectionUserAttribute_GetArgumentValueString
// spReflectionVariable_GetUserAttribute
// spReflectionTypeLayout_GetExplicitCounter
// spCompileRequest_getModule
// spReflectionTypeLayout_isBindingRangeSpecializable
// spReflectionVariable_FindUserAttributeByName
// spReflection_GetTypeLayout
// spReflection_FindTypeParameter
// spGetCompileFlags
// spSetTargetFlags
// spSetDiagnosticCallback
// spReflectionVariable_GetUserAttributeCount
// spGetTargetCodeBlob
