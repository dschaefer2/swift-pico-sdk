set -ex

export TOOLCHAINS=org.swift.62202509071a
swift -version

src_dir=$(pwd)
build_dir=${src_dir}/build
rm -fr ${build_dir}

cflags_armv8m="-mcpu=cortex-m33 -mfloat-abi=softfp -march=armv8m.main+fp+dsp"

arches="armv8m.main"

for arch in ${arches}; do
    arch_dir=${build_dir}/${arch}
    sysroot=${arch_dir}/sysroot
    res_dir=${sysroot}/lib/clang/17

    triple=${arch}-unknown-none-eabi
    proc=${arch%.*}
    cflagsv=cflags_${proc}
    cflags=${!cflagsv}

    mkdir -p ${arch_dir}

    cat > ${arch_dir}/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR ${arch})
set(CMAKE_ASM_COMPILER_TARGET ${triple})
set(CMAKE_ASM_FLAGS "${cflags}")
set(CMAKE_C_COMPILER_TARGET ${triple})
set(CMAKE_C_FLAGS "${cflags}")
set(CMAKE_CXX_COMPILER_TARGET ${triple})
set(CMAKE_CXX_FLAGS "${cflags}")
set(CMAKE_SYSROOT ${sysroot})

set(CMAKE_CROSSCOMPILING=YES)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_ASM_COMPILER $(xcrun -f clang) -resource-dir ${res_dir})
set(CMAKE_C_COMPILER $(xcrun -f clang) -resource-dir ${res_dir})
set(CMAKE_CXX_COMPILER $(xcrun -f clang++) -resource-dir ${res_dir})
set(CMAKE_FIND_ROOT_PATH ${sysroot})

set(CMAKE_OBJCOPY $(xcrun -f llvm-objcopy))
set(CMAKE_SIZE $(xcrun -f size))

EOF

    cat > ${arch_dir}/toolchain.meson <<EOF
[binaries]
c = ['$(xcrun -f clang)', '--target=armv8m.main-unknown-none-eabi', '-mcpu=cortex-m33', '-mfloat-abi=softfp', '-march=armv8m.main+fp+dsp', '-nostdlib']
ar = '$(xcrun -f llvm-ar)'
strip = '$(xcrun -f strip)'
ranlib = '$(xcrun -f llvm-ranlib)'
ld = ['$(xcrun -f ld.lld)', '--target=armv8m.main-unknown-none-eabi', '-nostdlib']

[host_machine]
system = 'none'
cpu_family = 'arm'
cpu = 'cortex-m33'
endian = 'little'

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
EOF

    mkdir -p ${sysroot}/lib/clang/17
    cp -R $(dirname $(xcrun -f clang))/../lib/clang/17/include ${sysroot}/lib/clang/17

    ### compiler-rt - llvm
    cmake -S ${src_dir}/llvm-project/compiler-rt \
          -B ${arch_dir}/compiler-rt \
          -G Ninja \
	      --install-prefix ${res_dir} \
	      --toolchain ${arch_dir}/toolchain.cmake \
          -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
          -DCOMPILER_RT_BAREMETAL_BUILD=ON \
	      -DCOMPILER_RT_BUILD_BUILTINS=ON \
          -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
          -DCOMPILER_RT_BUILD_XRAY=OFF \
          -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
          -DCOMPILER_RT_BUILD_PROFILE=OFF \
	      -DCOMPILER_RT_BUILD_MEMPROF=OFF \
	      -DCOMPILER_RT_BUILD_ORC=OFF \
	      -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
          -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON

    cmake --build ${arch_dir}/compiler-rt
    cmake --build ${arch_dir}/compiler-rt -- install

    # clang expects the built-ins to be here
    mkdir -p ${res_dir}/lib/armv8m.main-unknown-none-eabi
    ln -s ${res_dir}/lib/generic/libclang_rt.builtins-${arch}.a ${res_dir}/lib/armv8m.main-unknown-none-eabi/libclang_rt.builtins.a

    ### libc - picolibc
    meson setup \
	  --cross-file ${arch_dir}/toolchain.meson \
	  --prefix=${sysroot} \
	  ${arch_dir}/picolibc ${src_dir}/picolibc

    meson compile -C ${arch_dir}/picolibc
    meson install -C ${arch_dir}/picolibc

    ### libcxx - llvm
    cmake -S ${src_dir}/llvm-project/runtimes \
	      -B ${arch_dir}/runtimes \
	      -G Ninja \
	      --install-prefix ${sysroot} \
	      --toolchain ${arch_dir}/toolchain.cmake \
          -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
          -DLLVM_PARALLEL_LINK_JOBS=1 \
          -DLIBUNWIND_ENABLE_SHARED=NO \
          -DLIBUNWIND_ENABLE_STATIC=YES \
          -DLIBUNWIND_ENABLE_THREADS=OFF \
	      -DLIBUNWIND_IS_BAREMETAL=ON \
          -DLIBCXXABI_ENABLE_SHARED=NO \
          -DLIBCXXABI_ENABLE_STATIC=YES \
          -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
          -DLIBCXXABI_USE_COMPILER_RT=YES \
	      -DLIBCXXABI_ENABLE_THREADS=OFF \
	      -DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
	      -DLIBCXX_ENABLE_FILESYSTEM=OFF \
          -DLIBCXX_ENABLE_SHARED=OFF \
          -DLIBCXX_ENABLE_STATIC=ON \
          -DLIBCXX_USE_COMPILER_RT=YES \
          -DLIBCXX_ENABLE_THREADS=OFF \
          -DLIBCXX_INCLUDE_BENCHMARKS=NO \
          -DLIBCXX_CXX_ABI=libcxxabi

    cmake --build ${arch_dir}/runtimes
	cmake --build ${arch_dir}/runtimes -- install

    ### Swift stdlib
    stdlib_dir=${arch_dir}/stdlib
    mkdir -p ${stdlib_dir}

    function gyb {
        ${src_dir}/swift/utils/gyb \
              -DunicodeGraphemeBreakPropertyFile=${src_dir}/swift/utils/UnicodeData/GraphemeBreakProperty.txt \
              -DunicodeGraphemeBreakTestFile=${src_dir}/swift/utils/UnicodeData/GraphemeBreakTest.txt \
              -DCMAKE_SIZEOF_VOID_P=4 \
              -o ${stdlib_dir}/$2.swift \
              ${src_dir}/swift/stdlib/public/$1/$2.swift.gyb
    }

    # Swift.swiftmodule
    gyb core FloatingPointParsing
    gyb core FloatingPointTypes
    gyb core IntegerTypes
    gyb core LegacyInt128
    gyb core SIMDFloatConcreteOperations
    gyb core SIMDIntegerConcreteOperations
    gyb core SIMDMaskConcreteOperations
    gyb core SIMDVectorTypes
    gyb core Tuple
    gyb core UnsafeBufferPointer
    gyb core UnsafeRawBufferPointer

    $(xcrun -f swiftc) \
        -target ${triple} \
        -Xcc -mcpu=cortex-m33 -Xcc -mfloat-abi=softfp -Xcc -march=armv8m.main+fp+dsp \
        -resource-dir ${res_dir} \
        -emit-module \
        -o ${stdlib_dir}/Swift.swiftmodule/${triple}.swiftmodule \
        -avoid-emit-module-source-info \
        -O -g \
        -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY \
        -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED \
        -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING \
        -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING \
        -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION \
        -DSWIFT_ENABLE_SYNCHRONIZATION \
        -DSWIFT_ENABLE_VOLATILE \
        -DSWIFT_RUNTIME_OS_VERSIONING \
        -DSWIFT_STDLIB_ENABLE_UNICODE_DATA \
        -DSWIFT_STDLIB_HAS_COMMANDLINE \
        -DSWIFT_STDLIB_HAS_STDIN \
        -DSWIFT_STDLIB_HAS_ENVIRON \
        -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
        -DSWIFT_CONCURRENCY_USES_DISPATCH \
        -DSWIFT_STDLIB_OVERRIDABLE_RETAIN_RELEASE \
        -DSWIFT_THREADING_ \
        -module-cache-path ${stdlib_dir}/module-cache \
        -no-link-objc-runtime \
        -Xfrontend -enforce-exclusivity=unchecked \
        -nostdimport \
        -parse-stdlib \
        -module-name Swift \
        -Xfrontend -group-info-path -Xfrontend ${src_dir}/swift/stdlib/public/core/GroupInfo.json \
        -swift-version 5 \
        -Xfrontend -empty-abi-descriptor \
        -runtime-compatibility-version none \
        -disable-autolinking-runtime-compatibility-dynamic-replacements \
        -Xfrontend -disable-autolinking-runtime-compatibility-concurrency \
        -Xfrontend -disable-objc-interop \
        -enable-experimental-feature NoncopyableGenerics2 \
        -enable-experimental-feature SuppressedAssociatedTypes \
        -enable-experimental-feature SE427NoInferenceOnExtension \
        -enable-experimental-feature NonescapableTypes \
        -enable-experimental-feature LifetimeDependence \
        -enable-experimental-feature InoutLifetimeDependence \
        -enable-experimental-feature LifetimeDependenceMutableAccessors \
        -enable-upcoming-feature MemberImportVisibility \
        -Xllvm -sil-inline-generics \
        -Xllvm -sil-partial-specialization \
        -Xfrontend -enable-experimental-concise-pound-file \
        -enable-experimental-feature Macros \
        -enable-experimental-feature FreestandingMacros \
        -enable-experimental-feature Extern \
        -enable-experimental-feature BitwiseCopyable \
        -enable-experimental-feature ValueGenerics \
        -enable-experimental-feature AddressableParameters \
        -enable-experimental-feature AddressableTypes \
        -enable-experimental-feature AllowUnsafeAttribute \
        -strict-memory-safety \
        -Xfrontend -previous-module-installname-map-file -Xfrontend ${src_dir}/swift/stdlib/public/core/PreviousModuleInstallName.json \
        -Xcc -ffreestanding \
        -enable-experimental-feature Embedded \
        -Xfrontend -enable-ossa-modules \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 9999:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.0:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.0:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.2:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.2:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.3:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.3:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.4:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.4:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.5:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.5:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.6:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.6:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.7:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.7:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.8:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.8:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.9:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.9:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.10:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.10:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.0:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.0:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.1:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.1:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.2:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.3:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.3:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 5.0:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 6.2:macOS 10.9, iOS 7.0, watchOS 2.0, tvOS 9.0, visionOS 1.0" \
        -Xfrontend -target-min-inlining-version -Xfrontend min \
        -module-link-name swiftCore \
        -whole-module-optimization \
        -color-diagnostics \
        -parse-as-library \
        -I/Users/dschaefer2/swift/src/build/buildbot_osx/swift-macosx-arm64/lib/swift \
        -I${stdlib_dir} \
        @${src_dir}/Swift.txt

    # Synchronization.swiftmodule
    gyb Synchronization/Atomics AtomicIntegers
    gyb Synchronization/Atomics AtomicStorage

    $(xcrun -f swiftc) \
        -target ${triple} \
        -Xcc -mcpu=cortex-m33 -Xcc -mfloat-abi=softfp -Xcc -march=armv8m.main+fp+dsp \
        -resource-dir ${res_dir} \
        -emit-module \
        -o ${stdlib_dir}/Synchronization.swiftmodule/${triple}.swiftmodule \
        -avoid-emit-module-source-info \
        -O -g \
        -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY \
        -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED \
        -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING \
        -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING \
        -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION \
        -DSWIFT_ENABLE_SYNCHRONIZATION \
        -DSWIFT_ENABLE_VOLATILE \
        -DSWIFT_RUNTIME_OS_VERSIONING \
        -DSWIFT_STDLIB_ENABLE_UNICODE_DATA \
        -DSWIFT_STDLIB_HAS_COMMANDLINE \
        -DSWIFT_STDLIB_HAS_STDIN \
        -DSWIFT_STDLIB_HAS_ENVIRON \
        -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
        -DSWIFT_CONCURRENCY_USES_DISPATCH \
        -DSWIFT_STDLIB_OVERRIDABLE_RETAIN_RELEASE \
        -DSWIFT_THREADING_ \
        -module-cache-path ${stdlib_dir}/module-cache \
        -no-link-objc-runtime \
        -module-name Synchronization \
        -Xfrontend -disable-objc-interop \
        -enable-experimental-feature NoncopyableGenerics2 \
        -enable-experimental-feature SuppressedAssociatedTypes \
        -enable-experimental-feature SE427NoInferenceOnExtension \
        -enable-experimental-feature NonescapableTypes \
        -enable-experimental-feature LifetimeDependence \
        -enable-experimental-feature InoutLifetimeDependence \
        -enable-experimental-feature LifetimeDependenceMutableAccessors \
        -enable-upcoming-feature MemberImportVisibility \
        -enable-builtin-module \
        -enable-experimental-feature RawLayout \
        -enable-experimental-feature StaticExclusiveOnly \
        -enable-experimental-feature Extern \
        -strict-memory-safety \
        -Xcc -ffreestanding \
        -enable-experimental-feature Embedded \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 6.2:macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0" \
        -Xfrontend -target-min-inlining-version -Xfrontend min \
        -module-link-name swiftSynchronization \
        -whole-module-optimization \
        -color-diagnostics \
        -parse-as-library \
        -I/Users/dschaefer2/swift/src/build/buildbot_osx/swift-macosx-arm64/lib/swift \
        -I${stdlib_dir} \
        -Xfrontend -experimental-skip-non-inlinable-function-bodies \
        @${src_dir}/Synchronization.txt

    # _Volatile.swiftmodule
    $(xcrun -f swiftc) \
        -target ${triple} \
        -Xcc -mcpu=cortex-m33 -Xcc -mfloat-abi=softfp -Xcc -march=armv8m.main+fp+dsp \
        -resource-dir ${res_dir} \
        -emit-module \
        -o ${stdlib_dir}/_Volatile.swiftmodule/${triple}.swiftmodule \
        -avoid-emit-module-source-info \
        -O -g \
        -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY \
        -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED \
        -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING \
        -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING \
        -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION \
        -DSWIFT_ENABLE_SYNCHRONIZATION \
        -DSWIFT_ENABLE_VOLATILE \
        -DSWIFT_RUNTIME_OS_VERSIONING \
        -DSWIFT_STDLIB_ENABLE_UNICODE_DATA \
        -DSWIFT_STDLIB_ENABLE_VECTOR_TYPES \
        -DSWIFT_STDLIB_HAS_COMMANDLINE \
        -DSWIFT_STDLIB_HAS_STDIN \
        -DSWIFT_STDLIB_HAS_ENVIRON \
        -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
        -DSWIFT_CONCURRENCY_USES_DISPATCH \
        -DSWIFT_STDLIB_OVERRIDABLE_RETAIN_RELEASE \
        -DSWIFT_THREADING_ \
        -module-cache-path ${stdlib_dir}/module-cache \
        -no-link-objc-runtime \
        -DSWIFT_ENABLE_REFLECTION \
        -module-name _Volatile \
        -swift-version 5 \
        -autolink-force-load \
        -runtime-compatibility-version none \
        -disable-autolinking-runtime-compatibility-dynamic-replacements \
        -Xfrontend -disable-autolinking-runtime-compatibility-concurrency \
        -enable-experimental-feature NoncopyableGenerics2 \
        -enable-experimental-feature SuppressedAssociatedTypes \
        -enable-experimental-feature SE427NoInferenceOnExtension \
        -enable-experimental-feature NonescapableTypes \
        -enable-experimental-feature LifetimeDependence \
        -enable-experimental-feature InoutLifetimeDependence \
        -enable-experimental-feature LifetimeDependenceMutableAccessors \
        -enable-upcoming-feature MemberImportVisibility \
        -Xcc -ffreestanding \
        -enable-experimental-feature Embedded \
        -parse-stdlib \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 6.2:macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0" \
        -Xfrontend -target-min-inlining-version -Xfrontend min \
        -module-link-name swift_Volatile \
        -whole-module-optimization \
        -color-diagnostics \
        -parse-as-library \
        -I/Users/dschaefer2/swift/src/build/buildbot_osx/swift-macosx-arm64/lib/swift \
        -I${stdlib_dir} \
        -Xfrontend -experimental-skip-non-inlinable-function-bodies \
        @_Volatile.txt

    # _Builtin_float.swiftmodule
    gyb ClangOverlays float 

    $(xcrun -f swiftc) \
        -target ${triple} \
        -Xcc -mcpu=cortex-m33 -Xcc -mfloat-abi=softfp -Xcc -march=armv8m.main+fp+dsp \
        -resource-dir ${res_dir} \
        -emit-module \
        -o ${stdlib_dir}/_Builtin_float.swiftmodule/${triple}.swiftmodule \
        -avoid-emit-module-source-info \
        -O -g \
        -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY \
        -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED \
        -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING \
        -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING \
        -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION \
        -DSWIFT_ENABLE_SYNCHRONIZATION \
        -DSWIFT_ENABLE_VOLATILE \
        -DSWIFT_RUNTIME_OS_VERSIONING \
        -DSWIFT_STDLIB_ENABLE_UNICODE_DATA \
        -DSWIFT_STDLIB_HAS_COMMANDLINE \
        -DSWIFT_STDLIB_HAS_STDIN \
        -DSWIFT_STDLIB_HAS_ENVIRON \
        -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
        -DSWIFT_CONCURRENCY_USES_DISPATCH \
        -DSWIFT_STDLIB_OVERRIDABLE_RETAIN_RELEASE \
        -DSWIFT_THREADING_ \
        -module-cache-path ${stdlib_dir}/module-cache \
        -no-link-objc-runtime \
        -module-name _Builtin_float \
        -Xfrontend -disable-objc-interop \
        -enable-experimental-feature NoncopyableGenerics2 \
        -enable-experimental-feature SuppressedAssociatedTypes \
        -enable-experimental-feature SE427NoInferenceOnExtension \
        -enable-experimental-feature NonescapableTypes \
        -enable-experimental-feature LifetimeDependence \
        -enable-experimental-feature InoutLifetimeDependence \
        -enable-experimental-feature LifetimeDependenceMutableAccessors \
        -enable-upcoming-feature MemberImportVisibility \
        -Xfrontend -module-abi-name -Xfrontend Darwin \
        -Xcc -ffreestanding \
        -enable-experimental-feature Embedded \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 6.2:macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0" \
        -Xfrontend -target-min-inlining-version -Xfrontend min \
        -module-link-name swift_Builtin_float \
        -whole-module-optimization \
        -color-diagnostics \
        -parse-as-library \
        -I/Users/dschaefer2/swift/src/build/buildbot_osx/swift-macosx-arm64/lib/swift \
        -I${stdlib_dir} \
        @${src_dir}/_Builtin_float.txt

    # _Concurrency.swiftmodule
    gyb Concurrency Task+init
    gyb Concurrency TaskGroup+addTask
    gyb Concurrency Task+immediate

    $(xcrun -f swiftc) \
        -target ${triple} \
        -Xcc -mcpu=cortex-m33 -Xcc -mfloat-abi=softfp -Xcc -march=armv8m.main+fp+dsp \
        -resource-dir ${res_dir} \
        -emit-module \
        -o ${stdlib_dir}/_Concurrency.swiftmodule/${triple}.swiftmodule \
        -avoid-emit-module-source-info \
        -O -g \
        -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY \
        -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED \
        -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING \
        -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING \
        -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION \
        -DSWIFT_ENABLE_SYNCHRONIZATION \
        -DSWIFT_ENABLE_VOLATILE \
        -DSWIFT_RUNTIME_OS_VERSIONING \
        -DSWIFT_STDLIB_ENABLE_UNICODE_DATA \
        -DSWIFT_STDLIB_ENABLE_VECTOR_TYPES \
        -DSWIFT_STDLIB_HAS_COMMANDLINE \
        -DSWIFT_STDLIB_HAS_STDIN \
        -DSWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY \
        -DSWIFT_STDLIB_OVERRIDABLE_RETAIN_RELEASE \
        -DSWIFT_THREADING_NONE \
        -static \
        -module-cache-path ${stdlib_dir}/module-cache \
        -no-link-objc-runtime \
        -Xfrontend -assume-single-threaded \
        -Xfrontend -enforce-exclusivity=unchecked \
        -module-name _Concurrency \
        -swift-version 5 \
        -Xfrontend -empty-abi-descriptor \
        -runtime-compatibility-version none \
        -disable-autolinking-runtime-compatibility-dynamic-replacements \
        -Xfrontend -disable-autolinking-runtime-compatibility-concurrency \
        -Xfrontend -disable-objc-interop \
        -enable-experimental-feature NoncopyableGenerics2 \
        -enable-experimental-feature SuppressedAssociatedTypes \
        -enable-experimental-feature SE427NoInferenceOnExtension \
        -enable-experimental-feature NonescapableTypes \
        -enable-experimental-feature LifetimeDependence \
        -enable-experimental-feature InoutLifetimeDependence \
        -enable-experimental-feature LifetimeDependenceMutableAccessors \
        -enable-upcoming-feature MemberImportVisibility \
        -enable-experimental-feature Embedded \
        -parse-stdlib \
        -DSWIFT_CONCURRENCY_EMBEDDED \
        -Xfrontend -emit-empty-object-file \
        -I${src_dir}/swift/stdlib/public/Concurrency/InternalShims \
        -Xfrontend -swift-async-frame-pointer=always \
        -enable-experimental-feature IsolatedAny \
        -strict-memory-safety \
        -enable-experimental-feature AllowUnsafeAttribute \
        -enable-experimental-feature Extern \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 9999:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.2:macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.3:macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.4:macOS 11.3, iOS 14.5, watchOS 7.4, tvOS 14.5" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.5:macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.6:macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.8:macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.9:macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 5.10:macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.1:macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.2:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftStdlib 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "StdlibDeploymentTarget 6.3:macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 5.0:macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0" \
        -Xfrontend -define-availability -Xfrontend "SwiftCompatibilitySpan 6.2:macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0" \
        -Xfrontend -target-min-inlining-version -Xfrontend min \
        -module-link-name swift_Concurrency \
        -whole-module-optimization \
        -color-diagnostics \
        -parse-as-library \
        -I/Users/dschaefer2/swift/src/build/buildbot_osx/swift-macosx-arm64/lib/swift \
        -I${stdlib_dir} \
        -Xfrontend -experimental-skip-non-inlinable-function-bodies \
        @_Concurrency.txt
done
