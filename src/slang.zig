const c = @import("c.zig");
const SlangUInt32 = c_uint;

pub const SlangStage = enum(SlangUInt32) {
    SLANG_STAGE_NONE,
    SLANG_STAGE_VERTEX,
    SLANG_STAGE_HULL,
    SLANG_STAGE_DOMAIN,
    SLANG_STAGE_GEOMETRY,
    SLANG_STAGE_FRAGMENT,
    SLANG_STAGE_COMPUTE,
    SLANG_STAGE_RAY_GENERATION,
    SLANG_STAGE_INTERSECTION,
    SLANG_STAGE_ANY_HIT,
    SLANG_STAGE_CLOSEST_HIT,
    SLANG_STAGE_MISS,
    SLANG_STAGE_CALLABLE,
    SLANG_STAGE_MESH,
    SLANG_STAGE_AMPLIFICATION,

    // alias:
    // SLANG_STAGE_PIXEL = @intFromEnum(enum_or_tagged_union: anytype).SLANG_STAGE_FRAGMENT,
};

// extern fn spGetReflection(request: *SlangCompileRequest) *SlangReflection;
// extern fn spReflection_GetParameterCount(reflection: *SlangReflection) c_int;

const std = @import("std");

pub extern fn compile_slang(filepath_ptr: [*c]const u8, entrypoint_ptr: [*c]const u8, in_source_str_ptr: [*c]const u8, stage: SlangStage, out_data_len: *usize, out_result: *c_int) ?*anyopaque;

pub fn compileToSpv(
    allocator: std.mem.Allocator,
    filepath: [:0]const u8,
    entrypoint: [:0]const u8,
    stage: SlangStage,
) ![]u8 {
    const source = try std.fs.cwd().readFileAlloc(allocator, filepath, std.math.maxInt(usize));
    const str = try std.fmt.allocPrintZ(allocator, "{s}", .{source});

    // var spirv: [*c]u8 = undefined;
    var spirv_len: usize = 0;
    var result: c_int = 0;
    const spirv_ptr = compile_slang(filepath.ptr, entrypoint.ptr, str.ptr, stage, &spirv_len, &result);

    if (result != 0) {
        return error.FailedToCompileShader;
    }

    const array: [*]u8 = @ptrCast(spirv_ptr);
    return array[0..spirv_len];
    // const session = spCreateSession();
    // defer spDestroySession(session);

    // const req = spCreateCompileRequest(session);
    // defer spDestroyCompileRequest(req);
    // const profile_id = spFindProfile(session, "spirv_1_5".ptr);

    // const index = spAddCodeGenTarget(req, .SLANG_SPIRV);
    // spSetTargetProfile(req, index, profile_id);
    // spSetTargetFlags(req, index, .SLANG_TARGET_FLAG_GENERATE_SPIRV_DIRECTLY);
    // spSetTargetForceGLSLScalarBufferLayout(req, index, true);

    // const translation_index = spAddTranslationUnit(req, .SLANG_SOURCE_LANGUAGE_SLANG, "".ptr);
    // spAddTranslationUnitSourceFile(req, translation_index, filepath.ptr);

    // const entry_point_index = spAddEntryPoint(req, translation_index, entrypoint, stage);

    // const res = spCompile(req);
    // if (res.hasFailed()) {
    //     return error.FailedToCompileShader;
    // }

    // var size_out: usize = undefined;
    // const ptr = spGetEntryPointCode(req, entry_point_index, &size_out);
    // const bytes: [*]u8 = @ptrCast(ptr);

    // if (size_out == 0) {
    //     return error.FailedToCompileShader;
    // }

    // return try allocator.dupe(u8, bytes[0..size_out]);
}

// spComputeStringHash
// spSetTargetProfile
// spSetDumpIntermediates
// spProcessCommandLineArguments
// spSetWriter
// spSessionCheckPassThroughSupport
// spSetGlobalGenericArgs
// spGetWriter
// spAddBuiltins
// spIsParameterLocationUsed
// spAddEntryPointEx
// spGetDiagnosticOutput
// spGetCompileTimeProfile
// spExtractRepro
// spAddEntryPoint
// spSetDumpIntermediatePrefix
// spLoadReproAsFileSystem
// spDestroySession
// spFindProfile
// spSessionSetSharedLibraryLoader
// spGetTranslationUnitSource
// spSetDebugInfoLevel
// spGetReflection
// spSetTargetForceGLSLScalarBufferLayout
// spGetContainerCode
// spSetDefaultModuleName
// spSetTypeNameForEntryPointExistentialTypeParam
// spSetDebugInfoFormat
// spSaveRepro
// spSetTargetMatrixLayoutMode
// spCompileRequest_getEntryPoint
// spGetTargetHostCallable
// spSetOutputContainerFormat
// spCompileRequest_getSession
// spGetBuildTagString
// spSetLineDirectiveMode
// spCreateSession
// spGetDiagnosticOutputBlob
// spSetTargetUseMinimumSlangOptimization
// spGetEntryPointCodeBlob
// spGetEntryPointSource
// spLoadRepro
// spSetDiagnosticFlags
// spCreateCompileRequest
// spCompile
// spAddTargetCapability
// spSetPassThrough
// spAddTranslationUnitSourceFile
// spGetDependencyFilePath
// spGetDependencyFileCount
// spSetCodeGenTarget
// spOverrideDiagnosticSeverity
// spGetTranslationUnitCount
// spAddTranslationUnitSourceString
// spSetMatrixLayoutMode
// spAddSearchPath
// spTranslationUnit_addPreprocessorDefine
// spSetFileSystem
// spSetTargetLineDirectiveMode
// spCompileRequest_getProgram
// spSetIgnoreCapabilityCheck
// spSessionGetSharedLibraryLoader
// spDestroyCompileRequest
// spGetDiagnosticFlags
// spAddTranslationUnitSourceBlob
// spAddPreprocessorDefine
// spGetEntryPointHostCallable
// spSetCompileFlags
// spAddTranslationUnit
// spEnableReproCapture
// spFindCapability
// spSetTypeNameForGlobalExistentialTypeParam
// spGetEntryPointCode
// spAddCodeGenTarget
// spAddLibraryReference
// spSetTargetFloatingPointMode
// spAddTranslationUnitSourceStringSpan
// spCompileRequest_getProgramWithEntryPoints
// spSessionCheckCompileTargetSupport
// spGetCompileRequestCode
// spSetOptimizationLevel
// spCompileRequest_getModule
// spGetCompileFlags
// spSetTargetFlags
// spSetDiagnosticCallback
// spGetTargetCodeBlob

// spReflectionTypeLayout_GetMatrixLayoutMode
// spReflectionUserAttribute_GetArgumentCount
// spReflectionTypeLayout_GetSize
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeType
// spReflection_getHashedString
// spReflectionEntryPoint_getVarLayout
// spReflectionVariableLayout_getStage
// spReflectionEntryPoint_getNameOverride
// spReflectionTypeParameter_GetConstraintCount
// spReflectionTypeLayout_getSubObjectRangeSpaceOffset
// spReflectionType_GetFieldByIndex
// spReflectionEntryPoint_getComputeWaveSize
// spReflectionTypeLayout_getBindingRangeBindingCount
// spReflection_GetParameterCount
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeDescriptorCount
// spReflectionEntryPoint_getName
// spReflectionType_GetResourceAccess
// spReflectionTypeLayout_GetFieldCount
// spReflection_getGlobalParamsTypeLayout
// spReflectionVariableLayout_GetSemanticName
// spReflectionTypeLayout_GetElementTypeLayout
// spReflectionTypeLayout_findFieldIndexByName
// spReflectionTypeLayout_GetElementStride
// spReflectionVariable_GetType
// spReflectionVariableLayout_GetSemanticIndex
// spReflectionTypeLayout_getBindingRangeLeafVariable
// spReflectionTypeLayout_GetCategoryCount
// spReflectionTypeParameter_GetName
// spReflectionType_getSpecializedTypeArgType
// spReflectionType_GetName
// spReflectionTypeLayout_getSubObjectRangeOffset
// spReflectionTypeLayout_getBindingRangeType
// spReflectionTypeLayout_getSubObjectRangeBindingRangeIndex
// spReflectionVariable_FindModifier
// spReflectionEntryPoint_hasDefaultConstantBuffer
// spReflection_getGlobalConstantBufferSize
// spReflectionType_GetScalarType
// spReflectionVariableLayout_GetVariable
// spReflectionTypeLayout_GetParameterCategory
// spReflectionParameter_GetBindingIndex
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeIndexOffset
// spReflection_getEntryPointCount
// spReflectionTypeLayout_getKind
// spReflectionVariableLayout_GetOffset
// spReflectionEntryPoint_getStage
// spReflectionType_GetUserAttribute
// spReflectionTypeLayout_getBindingRangeDescriptorSetIndex
// spReflectionVariableLayout_GetTypeLayout
// spReflection_FindTypeByName
// spReflectionTypeLayout_getBindingRangeCount
// spReflectionUserAttribute_GetArgumentValueInt
// spReflectionTypeLayout_getExplicitCounterBindingRangeOffset
// spReflectionType_GetElementCount
// spReflectionTypeLayout_getDescriptorSetSpaceOffset
// spReflectionEntryPoint_getParameterCount
// spReflectionTypeLayout_getBindingRangeDescriptorRangeCount
// spReflectionTypeLayout_getContainerVarLayout
// spReflectionType_GetKind
// spReflectionType_GetUserAttributeCount
// spReflectionTypeParameter_GetConstraintByIndex
// spReflectionTypeLayout_GetStride
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeCategory
// spReflection_getHashedStringCount
// spReflectionTypeLayout_GetCategoryByIndex
// spReflectionVariable_GetName
// spReflectionVariableLayout_GetSpace
// spReflectionTypeLayout_getSubObjectRangeCount
// spReflectionUserAttribute_GetArgumentValueFloat
// spReflectionType_GetElementType
// spReflectionUserAttribute_GetArgumentType
// spReflectionTypeLayout_getGenericParamIndex
// spReflectionTypeLayout_getAlignment
// spReflectionTypeLayout_getBindingRangeFirstDescriptorRangeIndex
// spReflectionUserAttribute_GetName
// spReflectionType_GetResourceResultType
// spReflection_getGlobalParamsVarLayout
// spReflectionTypeLayout_GetType
// spReflectionTypeLayout_getSpecializedTypePendingDataVarLayout
// spReflectionTypeLayout_GetElementVarLayout
// spReflectionEntryPoint_getParameterByIndex
// spReflectionTypeLayout_getPendingDataTypeLayout
// spReflectionType_FindUserAttributeByName
// spReflection_findEntryPointByName
// spReflectionEntryPoint_getComputeThreadGroupSize
// spReflection_GetTypeParameterCount
// spReflectionTypeLayout_GetFieldByIndex
// spReflectionTypeLayout_getBindingRangeLeafTypeLayout
// spReflectionTypeLayout_getDescriptorSetDescriptorRangeCount
// spReflection_getGlobalConstantBufferBinding
// spReflection_getEntryPointByIndex
// spReflectionType_GetFieldCount
// spReflectionTypeLayout_getDescriptorSetCount
// spReflection_GetParameterByIndex
// spReflectionType_getSpecializedTypeArgCount
// spReflectionTypeParameter_GetIndex
// spReflectionType_GetColumnCount
// spReflectionVariableLayout_getPendingDataLayout
// spReflectionTypeLayout_getFieldBindingRangeOffset
// spReflectionType_GetRowCount
// spReflectionParameter_GetBindingSpace
// spReflectionEntryPoint_usesAnySampleRateInput
// spReflectionEntryPoint_getResultVarLayout
// spReflection_specializeType
// spReflection_GetTypeParameterByIndex
// spReflectionType_GetResourceShape
// spReflectionUserAttribute_GetArgumentValueString
// spReflectionVariable_GetUserAttribute
// spReflectionTypeLayout_GetExplicitCounter
// spReflectionTypeLayout_isBindingRangeSpecializable
// spReflectionVariable_FindUserAttributeByName
// spReflection_GetTypeLayout
// spReflection_FindTypeParameter
// spReflectionVariable_GetUserAttributeCount
